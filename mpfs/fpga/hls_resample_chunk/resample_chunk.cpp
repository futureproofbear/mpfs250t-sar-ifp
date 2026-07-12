// resample_chunk.cpp -- SmartHLS polar->Cartesian resample, SELF-SEQUENCING.
//
// Step B of the resample-latency work (see docs/fpga/SAR_PIPELINE_STATUS.md).
// The per-line kernel (hls_resample/resample.cpp) is armed once per line, so the
// MSS pays a CPU<->fabric arm/poll round-trip AND (before Step A) a whole-L2
// flush every line. This kernel loops over `nlines` INTERNALLY: the MSS arms it
// ONCE per chunk and the fabric streams the lines back-to-back.
//
// Numeric contract is identical to the per-line kernel (bit-for-bit):
//   out[l][i] = in[l][idx] + (in[l][idx+1]-in[l][idx]) * wq/32768,  w = wq/32768
//   idx in the source's natural order; idx<0 or idx>=nin-1 -> zero fill.
//
// Per-line addressing (all bases are word/element pointers, one arm covers the chunk):
//   source line l : in  + l*in_stride     (contiguous, burst-read into on-chip buf)
//   coeffs  line l: idx + l*nout, wq + l*nout   (contiguous per-line slots)
//   dest    line l: out + out_off[l]       (out_off handles the pass-1 invord permutation;
//                                           pass 2 sets out_off[l] = l*out_stride)
//   shls sw / cosim
#include <stdint.h>
#include <stdio.h>

#ifndef RC_MAX_IN
#define RC_MAX_IN   8193      // max source samples per line (need idx+1); sizes the on-chip buffer
#endif
#ifndef RC_MAX_OUT
#define RC_MAX_OUT  8192      // max output samples per line
#endif
#ifndef RC_MAX_LINES
#define RC_MAX_LINES 8192     // max lines per arm (bounds the AXI address counters)
#endif

static inline int16_t hi16(uint32_t x){ return (int16_t)(x >> 16); }
static inline int16_t lo16(uint32_t x){ return (int16_t)(x & 0xFFFF); }
static inline uint32_t pk(int16_t re, int16_t im){
    return (((uint32_t)(uint16_t)re) << 16) | (uint16_t)im; }
static inline int16_t lerp(int16_t a, int16_t b, int16_t w) {   // a + (b-a)*w, w in Q15
    return (int16_t)(a + (((int32_t)(b - a) * w) >> 15));
}

void resample_chunk(uint32_t *in, int32_t *idx, int16_t *wq, uint32_t *out,
                    int32_t *out_off, int nlines, int nin, int nout, int in_stride) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(in)      type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RC_MAX_LINES*RC_MAX_IN)  max_burst_len(64)
#pragma HLS interface argument(idx)     type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RC_MAX_LINES*RC_MAX_OUT) max_burst_len(64)
#pragma HLS interface argument(wq)      type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RC_MAX_LINES*RC_MAX_OUT) max_burst_len(64)
#pragma HLS interface argument(out)     type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RC_MAX_LINES*RC_MAX_OUT) max_burst_len(64)
#pragma HLS interface argument(out_off) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RC_MAX_LINES)             max_burst_len(64)
    static uint32_t buf[RC_MAX_IN];    // on-chip LSRAM, reloaded per line (bursts in, random gather local)

    for (int l = 0; l < nlines; l++) {
        uint32_t *in_l  = in  + (uint64_t)l * in_stride;   // source line (contiguous, burstable)
        int32_t  *idx_l = idx + (uint64_t)l * nout;
        int16_t  *wq_l  = wq  + (uint64_t)l * nout;
        uint32_t *out_l = out + out_off[l];                // permuted dest (pass 1) / contiguous (pass 2)

        /* burst the whole source line into on-chip RAM with one sequential read */
#pragma HLS loop pipeline II(1)
        for (int i = 0; i < nin; i++) buf[i] = in_l[i];

        /* gather + lerp from on-chip RAM, burst-write the output line */
#pragma HLS loop pipeline II(1)
        for (int i = 0; i < nout; i++) {
            int32_t j = idx_l[i];
            uint32_t o;
            if (j < 0 || j >= nin - 1) {
                o = 0;                                   // zero-fill out-of-range
            } else {
                uint32_t a = buf[j], b = buf[j + 1];
                int16_t w = wq_l[i];
                o = pk(lerp(hi16(a), hi16(b), w), lerp(lo16(a), lo16(b), w));
            }
            out_l[i] = o;
        }
    }
}

/* ---- cosim self-test: a small chunk must equal the per-line reference ----- */
int main() {
    enum { L = 5, NIN = 300, NOUT = 256 };
    static uint32_t in[L * NIN], out[L * NOUT];
    static int32_t  idx[L * NOUT], out_off[L];
    static int16_t  wq[L * NOUT];

    /* deterministic inputs; permuted dest offsets to exercise out_off (pass-1 style) */
    const int perm[L] = {2, 0, 4, 1, 3};
    for (int l = 0; l < L; l++) {
        out_off[l] = perm[l] * NOUT;
        for (int i = 0; i < NIN;  i++) in[l*NIN + i] = pk((int16_t)(i*7 - 900 + l*13), (int16_t)(-i*3 + 200 - l*5));
        for (int i = 0; i < NOUT; i++) {
            int32_t j = (i * (NIN - 2)) / NOUT;            // in [0, NIN-2]
            if ((i & 31) == 0 && l == 2) j = -1;           // sprinkle a zero-fill edge
            idx[l*NOUT + i] = j;
            wq[l*NOUT + i]  = (int16_t)((i * 37 + l * 101) & 0x7FFF);
        }
    }

    resample_chunk(in, idx, wq, out, out_off, L, NIN, NOUT, NIN);

    /* scalar reference: same math, one line at a time */
    int err = 0;
    for (int l = 0; l < L; l++) {
        uint32_t *out_l = out + out_off[l];
        for (int i = 0; i < NOUT; i++) {
            int32_t j = idx[l*NOUT + i]; uint32_t exp;
            if (j < 0 || j >= NIN - 1) exp = 0;
            else {
                uint32_t a = in[l*NIN + j], b = in[l*NIN + j + 1]; int16_t w = wq[l*NOUT + i];
                exp = pk(lerp(hi16(a), hi16(b), w), lerp(lo16(a), lo16(b), w));
            }
            if (out_l[i] != exp) err++;
        }
    }
    printf("resample_chunk L=%d NIN=%d NOUT=%d: %s (%d errors)\n", L, NIN, NOUT, err ? "FAIL" : "PASS", err);
    return err ? 1 : 0;
}
