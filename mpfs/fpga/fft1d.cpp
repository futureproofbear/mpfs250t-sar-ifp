// fft1d.cpp -- streaming 1-D FFT kernel (HLS TEMPLATE, UNVERIFIED).
//
// STATUS: starting template for Microchip SmartHLS (C++ -> RTL). It has NOT
// been synthesized, simulated, or timing-closed. For production, prefer the
// Microchip *CoreFFT* IP (configured via Libero / IP catalog) which is
// verified and area/timing-characterized; keep this only if you need a custom
// radix/precision the IP doesn't cover.
//
// Block-floating-point, fixed-point datapath (matches the 18x18 DSP blocks).
// One instance does a length-NFFT complex FFT; the top level (sar_accel_top)
// instantiates several in parallel and feeds them line-by-line.

#include <hls_stream.h>
#include <ap_int.h>
#include <ap_fixed.h>
#include <cmath>

// 18-bit fixed point -> one value per DSP multiplier input.
typedef ap_fixed<18, 2> coef_t;       // twiddles in [-2,2)
typedef ap_fixed<24, 12> data_t;      // datapath with headroom (BFP rescales)

struct cplx { data_t re, im; };

#ifndef NFFT
#define NFFT 8192
#endif
#define LOGN 13               // log2(NFFT); keep in sync with NFFT

// Precomputed twiddles (W_N^k). Generate at build time; ROM in BRAM.
static const int HALF = NFFT / 2;
extern const coef_t TW_RE[HALF];
extern const coef_t TW_IN[HALF];

static inline unsigned bitrev(unsigned x) {
#pragma HLS inline
    unsigned r = 0;
    for (int i = 0; i < LOGN; i++) { r = (r << 1) | (x & 1); x >>= 1; }
    return r;
}

// Iterative radix-2 DIT FFT over an on-chip buffer (one line at a time).
// Block-floating-point: rescale per stage to hold dynamic range in fixed point.
void fft1d(hls::stream<cplx> &in, hls::stream<cplx> &out, int &bfp_shift) {
#pragma HLS pipeline off
    static cplx buf[NFFT];
#pragma HLS bind_storage variable=buf type=ram_2p impl=bram

    // load with bit-reversed addressing
LOAD:
    for (int i = 0; i < NFFT; i++) {
#pragma HLS pipeline II=1
        buf[bitrev(i)] = in.read();
    }

    int shift = 0;
STAGES:
    for (int s = 1; s <= LOGN; s++) {
        int m = 1 << s, mh = m >> 1, step = NFFT / m;
    GROUP:
        for (int k = 0; k < NFFT; k += m) {
        BFLY:
            for (int j = 0; j < mh; j++) {
#pragma HLS pipeline II=1
                coef_t wr = TW_RE[j * step], wi = TW_IN[j * step];
                cplx a = buf[k + j], b = buf[k + j + mh];
                data_t tr = (data_t)(wr * b.re - wi * b.im);
                data_t ti = (data_t)(wr * b.im + wi * b.re);
                buf[k + j].re = a.re + tr;  buf[k + j].im = a.im + ti;
                buf[k + j + mh].re = a.re - tr;  buf[k + j + mh].im = a.im - ti;
            }
        }
        shift += 1;   // block-floating-point: 1-bit downscale guard per stage
    }
    bfp_shift = shift;

STORE:
    for (int i = 0; i < NFFT; i++) {
#pragma HLS pipeline II=1
        out.write(buf[i]);
    }
}
