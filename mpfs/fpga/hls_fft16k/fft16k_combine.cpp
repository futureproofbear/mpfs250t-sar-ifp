// fft16k_combine.cpp -- butterfly-combine stage of the 16384-pt FFT (2x 8192 decomposition).
//
// The hardware CoreFFT maxes at 8192-pt in-place. A 16384-pt FFT is assembled (radix-2 DIT) from
// two 8192-pt CoreFFTs of the even/odd samples, then THIS kernel combines them:
//     X[k]      = E[k] + T[k]*O[k]
//     X[k+8192] = E[k] - T[k]*O[k]      (k = 0..8191),  T[k] = exp(-j2*pi*k/16384) in Q15
// where E = FFT_8192(x[0::2]), O = FFT_8192(x[1::2]). Validated in host/fft16384.py (float ==
// direct FFT; BFP corr 0.999999 vs float).
//
// mem->mem HLS (reads E,O + twiddle LUT from DDR, writes X to DDR) -- NOT mem->stream, so it is
// HLS-safe on this toolchain (unlike a kernel that streams into CoreFFT, which dead-RTLs).
//
// BFP: E and O carry their own CoreFFT block exponents; the caller passes (eE,eO) and this kernel
// aligns them to the common exponent max(eE,eO) (truncating down-shift = fabric), does the Q15
// twiddle multiply (>>15 truncate), the E +/- TO butterfly, and a final >>1 so E+/-TO cannot
// overflow int16. Net right-shift folded into the block exponent by firmware (returns via SCRATCH).
//   shls sw
#include <stdint.h>
#include <stdio.h>
#ifndef CB_NHALF
#define CB_NHALF 8192            // half length (each sub-FFT); full = 2*NHALF = 16384
#endif

static inline int16_t hi16(uint32_t x){ return (int16_t)(x >> 16); }
static inline int16_t lo16(uint32_t x){ return (int16_t)(x & 0xFFFF); }
static inline uint32_t pk(int16_t re, int16_t im){
    return (((uint32_t)(uint16_t)re) << 16) | (uint16_t)im; }
static inline int16_t sat16(int32_t v){ return v > 32767 ? 32767 : (v < -32768 ? -32768 : (int16_t)v); }

// E,O: 8192 complex int16 packed (hi=Re, lo=Im). twRe/twIm: Q15 twiddle (NHALF entries).
// X: 16384 output. eE,eO: block exponents of E,O (>=0). Output block exp = max(eE,eO)+1 (the >>1).
void fft16k_combine(uint32_t *E, uint32_t *O, int16_t *twRe, int16_t *twIm,
                    uint32_t *X, int eE, int eO) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(E)    type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CB_NHALF)   max_burst_len(256)
#pragma HLS interface argument(O)    type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CB_NHALF)   max_burst_len(256)
#pragma HLS interface argument(twRe) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CB_NHALF)   max_burst_len(256)
#pragma HLS interface argument(twIm) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CB_NHALF)   max_burst_len(256)
#pragma HLS interface argument(X)    type(axi_initiator) ptr_addr_interface(axi_target) num_elements(2*CB_NHALF) max_burst_len(256)

    int e   = eE > eO ? eE : eO;             // common block exponent
    int shE = e - eE, shO = e - eO;          // truncating down-shifts to align E,O

#pragma HLS loop pipeline II(1)
    for (int k = 0; k < CB_NHALF; k++) {
        uint32_t ev = E[k], ov = O[k];
        int32_t er = (int32_t)hi16(ev) >> shE, ei = (int32_t)lo16(ev) >> shE;   // aligned E
        int32_t orr = (int32_t)hi16(ov) >> shO, oi = (int32_t)lo16(ov) >> shO;  // aligned O
        int32_t wr = twRe[k], wi = twIm[k];
        // T*O complex multiply, Q15 -> >>15 (truncate, fabric-style)
        int32_t tor = ((int32_t)wr * orr - (int32_t)wi * oi) >> 15;
        int32_t toi = ((int32_t)wr * oi + (int32_t)wi * orr) >> 15;
        // butterfly + >>1 headroom so E +/- TO fits int16
        int16_t lo_re = sat16((er + tor) >> 1), lo_im = sat16((ei + toi) >> 1);
        int16_t hi_re = sat16((er - tor) >> 1), hi_im = sat16((ei - toi) >> 1);
        X[k]           = pk(lo_re, lo_im);
        X[k + CB_NHALF] = pk(hi_re, hi_im);
    }
}

#ifndef __SYNTHESIS__
#include <math.h>
int main() {
    const int N = CB_NHALF;
    static uint32_t E[CB_NHALF], O[CB_NHALF], X[2 * CB_NHALF], Xr[2 * CB_NHALF];
    static int16_t twRe[CB_NHALF], twIm[CB_NHALF];
    const int eE = 3, eO = 2;                              // exercise the align (different exps)
    for (int k = 0; k < N; k++) {
        E[k] = pk((int16_t)(k * 5 - 4000), (int16_t)(-k * 3 + 1500));
        O[k] = pk((int16_t)(k * 7 - 9000), (int16_t)(k * 2 - 800));
        twRe[k] = (int16_t)lround(cos(-2.0 * M_PI * k / (2.0 * N)) * 32767.0);
        twIm[k] = (int16_t)lround(sin(-2.0 * M_PI * k / (2.0 * N)) * 32767.0);
    }
    fft16k_combine(E, O, twRe, twIm, X, eE, eO);

    // scalar reference: same fixed-point arithmetic
    int e = eE > eO ? eE : eO, shE = e - eE, shO = e - eO, err = 0;
    for (int k = 0; k < N; k++) {
        int32_t er = (int32_t)hi16(E[k]) >> shE, ei = (int32_t)lo16(E[k]) >> shE;
        int32_t orr = (int32_t)hi16(O[k]) >> shO, oi = (int32_t)lo16(O[k]) >> shO;
        int32_t tor = ((int32_t)twRe[k] * orr - (int32_t)twIm[k] * oi) >> 15;
        int32_t toi = ((int32_t)twRe[k] * oi + (int32_t)twIm[k] * orr) >> 15;
        Xr[k]     = pk(sat16((er + tor) >> 1), sat16((ei + toi) >> 1));
        Xr[k + N] = pk(sat16((er - tor) >> 1), sat16((ei - toi) >> 1));
        if (X[k] != Xr[k] || X[k + N] != Xr[k + N]) err++;
    }
    printf("fft16k_combine N=%d full=%d: %s (%d errors)\n", N, 2 * N, err ? "FAIL" : "PASS", err);
    return err ? 1 : 0;
}
#endif
