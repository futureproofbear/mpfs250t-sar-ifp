// resample.cpp -- SmartHLS polar->Cartesian resample APPLICATION (per line).
// Per the CPU/fabric partition: the CPU precomputes, per output sample, the
// source index idx[] and linear-interp weight wq[] (Q15); the fabric just
// gathers and lerps. So this kernel is data-movement + 2 MACs, no division.
//   out[i] = in[idx[i]]*(1-w) + in[idx[i]+1]*w,  w = wq[i]/32768
// Edge samples (idx<0) zero-fill, matching np.interp(left=0,right=0).
//
// This is the REDESIGNED II=1 kernel (silicon-validated, corr 0.9923, ~2.3x resample): idx/wq are
// burst-staged into on-chip LSRAM up front (like `in`) so the gather loop does ZERO per-output DDR
// reads -- it touches DDR only for the sequential (burstable) `out` write. buf[j]/buf[j+1] read in
// one cycle via PolarFire's two-port LSRAM -> gather loop II=1 (was II=2 + shared-m_axi-port
// serialization in the pre-redesign version, which read idx[i]/wq[i] from DDR per output).
//
// NOTE (2026-07-21): idx/wq are fetched as PACKED 64-bit AXI beats. The FIC_0 initiator bus is 64
// bits wide, but a uint32_t*/int16_t* argument makes SmartHLS drive ar_size=3'd2/3'd1 (4/2 bytes per
// beat), so most of the bus was idle. idx64/wq64 are uint64_t* -> ar_size=3'd3 (8 bytes/beat); the
// unpack loops split each word back into the SAME idxb[]/wqb[] LSRAM arrays, so the gather loop and
// every output value are bit-identical. This is purely how the bytes are carried across AXI.
//   Beats per line: 8193 + 8192 + 8192 + 8192 = 32769  ->  8193 + 4096 + 2048 + 8192 = 22529.
// `in` and `out` are DELIBERATELY NOT packed -- do not "optimise" them without re-checking these:
//   * in : pass 1 reads BUF_SIG + i*N*4 with N=4319, so for ODD i the base address is only 4-byte
//          aligned and an 8-byte beat requires 8-byte alignment. (Pass 2 alone would be fine, but
//          one kernel binary serves both passes, so it must handle the worst case.)
//   * out: two outputs per cycle would need 4 LSRAM reads per cycle from `buf`
//          (buf[j0],buf[j0+1],buf[j1],buf[j1+1]); the 2-port LSRAM cannot, forcing II>1 and
//          cancelling the gain.
// idx/wq alignment is safe: they live at SAR_COEF_IDX(b)/SAR_COEF_WQ(b) = 0xB0148000 + b*0x20000
// (+0x10000), b in 0..3 -- every one is 8-byte aligned.
//
// NOTE (2026-07-13): the 2-D Hamming window is a SEPARATE K_WINDOW pass (SCRATCH->SCRATCH) after
// resample pass 2 -- NOT fused here. A fused always-window variant was tried and REVERTED: it hit
// TWO SmartHLS sim-passes/silicon-fails miscompiles (an apply_win runtime branch that synthesized
// dead; then an always-multiply/int32-cw path that zeroed the gather). Value-level iso-tests caught
// both. The fusion was a ~1-2% optimization; the separate window is the known-good path.
//   shls sw / cosim
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#ifndef RS_OUT
#define RS_OUT 8192            // output samples (uniform grid)
#endif
#ifndef RS_IN
#define RS_IN  8193            // source samples (need idx+1)
#endif
static inline int16_t hi16(uint32_t x){ return (int16_t)(x >> 16); }
static inline int16_t lo16(uint32_t x){ return (int16_t)(x & 0xFFFF); }
static inline uint32_t pk(int16_t re, int16_t im){
    return (((uint32_t)(uint16_t)re) << 16) | (uint16_t)im; }
static inline int16_t lerp(int16_t a, int16_t b, int16_t w) {   // a + (b-a)*w, w in Q15
    return (int16_t)(a + (((int32_t)(b - a) * w) >> 15));
}

void resample(uint32_t *in, const uint64_t *idx64, const uint64_t *wq64, uint32_t *out) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
// max_outstanding_* added 2026-07-20. SmartHLS's own optimization recipe
// (SmartHLS/examples/user_guide_examples/axi_initiator_optimization) is four steps: pipeline the
// loop to infer bursts, set max_burst_len, set max_outstanding, pick the CPU-side alloc region.
// This kernel did 1 and 2 but never 3, while measuring ~3.1x off its ideal schedule at only
// ~39 MB/s -- i.e. DDR LATENCY-bound, not bandwidth-bound, which is exactly what outstanding
// transactions hide. Values are the vendor's: reads(8) per axi_initiator_max_outstanding,
// writes(2) per both that example and axi_initiator_optimization.
// Numerically INERT: this changes only how many AXI transactions are in flight, never any value.
#pragma HLS interface argument(in)  type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_IN)  max_burst_len(256) max_outstanding_reads(8)
// idx64/wq64: same BYTE range as before, half/quarter the ELEMENT count because each element is now
// a packed 64-bit beat (2 int32 / 4 int16). Argument order and byte addresses are unchanged.
#pragma HLS interface argument(idx64) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_OUT/2) max_burst_len(256) max_outstanding_reads(8)
#pragma HLS interface argument(wq64)  type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_OUT/4) max_burst_len(256) max_outstanding_reads(8)
#pragma HLS interface argument(out) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_OUT) max_burst_len(256) max_outstanding_writes(2)
    static uint32_t buf[RS_IN];
// The unpack loops write 2 (idx) / 4 (wq) LSRAM words per iteration, which needs that many write
// ports to hold II=1. Cyclic banking puts consecutive elements in different banks, so element 2i+k
// (resp. 4i+k) is always bank k -- the per-iteration writes never collide. The gather loop reads
// idxb[i]/wqb[i] once per iteration, one bank per cycle, so banking does not cost it anything.
// NOTE: this pragma MUST sit immediately before the DECLARATION it partitions. Placed anywhere else
// SmartHLS drops it with "ignored: expected a variable after the pragma" -- a warning, not an error,
// so the build still "succeeds" and only the II report reveals the loss.
#pragma HLS memory partition variable(idxb) type(cyclic) factor(2) dim(1)
    static int32_t  idxb[RS_OUT];
#pragma HLS memory partition variable(wqb)  type(cyclic) factor(4) dim(1)
    static int16_t  wqb[RS_OUT];
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_IN;  i++) buf[i]  = in[i];    // source line -> LSRAM (burst)
// LITTLE-ENDIAN unpack (RISC-V + AXI): element 0 is in the LOW bits. Narrow through the unsigned
// type first so the only sign step is the final reinterpretation -- no implementation-defined
// sign-extension for SmartHLS to get wrong.
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_OUT / 2; i++) {               // 2 x int32 per 64-bit beat
        uint64_t v = idx64[i];
        idxb[2 * i]     = (int32_t)(uint32_t)(v);
        idxb[2 * i + 1] = (int32_t)(uint32_t)(v >> 32);
    }
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_OUT / 4; i++) {               // 4 x int16 per 64-bit beat
        uint64_t v = wq64[i];
        wqb[4 * i]     = (int16_t)(uint16_t)(v);
        wqb[4 * i + 1] = (int16_t)(uint16_t)(v >> 16);
        wqb[4 * i + 2] = (int16_t)(uint16_t)(v >> 32);
        wqb[4 * i + 3] = (int16_t)(uint16_t)(v >> 48);
    }
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_OUT; i++) {
        int32_t j = idxb[i];
        uint32_t o;
        if (j < 0 || j >= RS_IN - 1) {
            o = 0;                                   // zero-fill out-of-range
        } else {
            uint32_t a = buf[j], b = buf[j + 1];     // adjacent pair, two-port LSRAM -> 1 cycle
            int16_t w = wqb[i];
            o = pk(lerp(hi16(a), hi16(b), w), lerp(lo16(a), lo16(b), w));
        }
        out[i] = o;                                  // only DDR access in this loop; sequential -> bursts
    }
}

int main() {
    static uint32_t in[RS_IN], out[RS_OUT]; static int32_t idx[RS_OUT]; static int16_t wq[RS_OUT];
    static uint64_t idx64[RS_OUT/2], wq64[RS_OUT/4];
    for (int i = 0; i < RS_IN;  i++) in[i] = pk((int16_t)(i*11-3000), (int16_t)(-i*4+800));
    for (int i = 0; i < RS_OUT; i++) { idx[i] = (i * 1000) / RS_OUT; wq[i] = (int16_t)((i * 31) & 0x7FFF); }
    // Pack exactly as the kernel unpacks: element 0 in the LOW bits (little-endian).
    for (int i = 0; i < RS_OUT/2; i++)
        idx64[i] = ((uint64_t)(uint32_t)idx[2*i+1] << 32) | (uint64_t)(uint32_t)idx[2*i];
    for (int i = 0; i < RS_OUT/4; i++)
        wq64[i] = ((uint64_t)(uint16_t)wq[4*i+3] << 48) | ((uint64_t)(uint16_t)wq[4*i+2] << 32)
                | ((uint64_t)(uint16_t)wq[4*i+1] << 16) | (uint64_t)(uint16_t)wq[4*i];
    // ENDIANNESS PROOF: firmware writes plain int32/int16 arrays and the kernel now reads the same
    // bytes as 64-bit beats, so the packed buffer MUST be byte-identical to the plain array. On a
    // little-endian host (x86 test, RISC-V target) this holds; it would fail big-endian.
    int endian_err = (memcmp(idx64, idx, sizeof(idx)) != 0) || (memcmp(wq64, wq, sizeof(wq)) != 0);
    printf("endianness (packed bytes == plain array bytes): %s\n", endian_err ? "FAIL" : "PASS");
    resample(in, idx64, wq64, out);
    int err = endian_err;
    for (int i = 0; i < RS_OUT; i++) {
        int32_t j = idx[i]; uint32_t exp;
        if (j < 0 || j >= RS_IN - 1) exp = 0;
        else exp = pk(lerp(hi16(in[j]), hi16(in[j+1]), wq[i]), lerp(lo16(in[j]), lo16(in[j+1]), wq[i]));
        if (out[i] != exp) err++;
    }
    printf("resample OUT=%d IN=%d: %s (%d errors)\n", RS_OUT, RS_IN, err ? "FAIL" : "PASS", err);
    return err ? 1 : 0;
}
