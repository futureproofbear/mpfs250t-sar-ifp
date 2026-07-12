// resample.cpp -- SmartHLS polar->Cartesian resample APPLICATION (per line).
// Per the CPU/fabric partition: the CPU precomputes, per output sample, the
// source index idx[] and linear-interp weight wq[] (Q15); the fabric just
// gathers and lerps. So this kernel is data-movement + 2 MACs, no division.
//   out[i] = in[idx[i]]*(1-w) + in[idx[i]+1]*w,  w = wq[i]/32768
// Edge samples (idx<0) zero-fill, matching np.interp(left=0,right=0).
//   shls sw / cosim
#include <stdint.h>
#include <stdio.h>
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

void resample(uint32_t *in, int32_t *idx, int16_t *wq, uint32_t *out) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(in)  type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_IN)  max_burst_len(64)
#pragma HLS interface argument(idx) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_OUT) max_burst_len(64)
#pragma HLS interface argument(wq)  type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_OUT) max_burst_len(64)
#pragma HLS interface argument(out) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(RS_OUT) max_burst_len(64)
    /* PERF (silicon-measured root cause): the gather loop was ~21 fabric-cyc/output on hardware
     * (~10x past its scheduled II=2), NOT source-read-bound. Cause: idx[i]/wq[i] were read from DDR
     * *per output*, sharing the one m_axi port with the out write -> arbitration + real DDR latency.
     * FIX: burst-stage idx/wq into on-chip RAM up front (like `in` already is), so the gather loop
     * touches DDR only for the sequential (burstable) out write. buf[j]/buf[j+1] read in one cycle via
     * PolarFire's native two-port LSRAM (HW report schedules the gather at II=1). Numeric contract
     * unchanged (same gather + lerp + zero-fill). MUST value-verify on silicon -- SmartHLS scheduling
     * has repeatedly diverged from silicon on this design. */
    static uint32_t buf[RS_IN];
    static int32_t  idxb[RS_OUT];
    static int16_t  wqb[RS_OUT];
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_IN;  i++) buf[i]  = in[i];    // source line -> LSRAM (burst)
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_OUT; i++) idxb[i] = idx[i];   // gather indices -> LSRAM (burst)
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_OUT; i++) wqb[i]  = wq[i];    // Q15 weights   -> LSRAM (burst)
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < RS_OUT; i++) {
        int32_t j = idxb[i];
        uint32_t o;
        if (j < 0 || j >= RS_IN - 1) {
            o = 0;                                   // zero-fill out-of-range
        } else {
            uint32_t a = buf[j], b = buf[j + 1];     // adjacent pair, different cyclic banks -> 1 cycle
            int16_t w = wqb[i];
            o = pk(lerp(hi16(a), hi16(b), w), lerp(lo16(a), lo16(b), w));
        }
        out[i] = o;                                  // only DDR access in this loop; sequential -> bursts
    }
}

int main() {
    static uint32_t in[RS_IN], out[RS_OUT]; static int32_t idx[RS_OUT]; static int16_t wq[RS_OUT];
    for (int i = 0; i < RS_IN;  i++) in[i] = pk((int16_t)(i*11-3000), (int16_t)(-i*4+800));
    for (int i = 0; i < RS_OUT; i++) { idx[i] = (i * 1000) / RS_OUT; wq[i] = (int16_t)((i * 31) & 0x7FFF); }
    resample(in, idx, wq, out);
    int err = 0;
    for (int i = 0; i < RS_OUT; i++) {
        int32_t j = idx[i]; uint32_t exp;
        if (j < 0 || j >= RS_IN - 1) exp = 0;
        else exp = pk(lerp(hi16(in[j]), hi16(in[j+1]), wq[i]), lerp(lo16(in[j]), lo16(in[j+1]), wq[i]));
        if (out[i] != exp) err++;
    }
    printf("resample OUT=%d IN=%d: %s (%d errors)\n", RS_OUT, RS_IN, err ? "FAIL" : "PASS", err);
    return err ? 1 : 0;
}
