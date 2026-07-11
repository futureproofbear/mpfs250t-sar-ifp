// fft_kernel.cpp -- SmartHLS 8192-point fixed-point FFT kernel (CoreFFT drop-in
// contingency). Wraps hls::dsp::fft_in_place<8192> from the SmartHLS DSP library
// as a plain AXI kernel, mirroring the other 5 HLS kernels (axi_target control +
// axi_initiator src/dst masters over 64-bit DDR).
//
// FFT dynamic range: SINGLE-PASS GLOBAL BFP. An L1 pre-scan of the pass (max row
// sum|re|+|im|) yields ONE shared block exponent; each row runs a full-precision
// (wide-datapath) FFT via hls::dsp::fft_in_place_bfp and its output is normalized
// by that shared exponent to int16. This replaces the old unconditional >>1/stage
// (fixed 1/8192) scaling, which truncated a distributed scene to all-zero uint16.
// Lossless vs float (corr 1.00000, validated in src/fixedpoint.py). The block
// exponent (exp_range + exp_azimuth) is the BFP_SHIFT for the host's dB scale; the
// mantissa image is already structurally correct (one exponent per pass).
//
// DATA FORMAT (verified vs corefft_stream64_adapter.v input gearbox):
//   64-bit beat = TWO complex int16 samples.
//     beat[31:0]  = sample0, beat[63:32] = sample1
//     a 32-bit sample = { int16 re [31:16], int16 im [15:0] }
//   One FFT row = 8192 complex samples = 4096 beats.
//
// hls_fft.hpp / common.hpp / twiddle.h are LOCAL COPIES in this dir. twiddle.h is
// regenerated for SIZE=8192 by gen_twiddle.py (the shipped library twiddle.h is
// 256-pt). hls_fft.hpp/common.hpp are copied so the library's quoted
// #include "twiddle.h" resolves to the local 8192-pt table (a quoted include
// searches the including header's own directory first, so -I cannot override it).
//
// INTERFACE CAVEATS for later fabric integration:
//  - Scaling is fixed 1/8192 (unconditional), unlike CoreFFT's conditional BFP.
//  - fft_in_place is decimation-in-time: it bit-reverses the INPUT internally
//    (new_index()) and emits OUTPUT in natural frequency order. So feed samples
//    in natural time order; results come out in natural order (no external
//    bit-reversal needed) -- same ordering contract as CoreFFT forward FFT.
//  - Sample packing matches the gearbox exactly ({re<<16}|im, sample0 in low 32b).
#include <stdint.h>
#include "hls/streaming.hpp"
#include "hls_fft.hpp"

using hls::dsp::fft_data_t;

#define FFT_N        8192u
#define BEATS_PER_ROW (FFT_N / 2u)                 // 4096 beats/row (2 samples/beat)
// worst case: 8192 rows -> 8192*4096 = 33554432 beats for src/dst sizing
#define MAX_BEATS    (8192u * BEATS_PER_ROW)

static inline int16_t s_re(uint32_t s) { return (int16_t)(s >> 16); }
static inline int16_t s_im(uint32_t s) { return (int16_t)(s & 0xFFFFu); }
static inline uint32_t s_pk(int16_t re, int16_t im) {
    return (((uint32_t)(uint16_t)re) << 16) | (uint16_t)im;
}

void fft_kernel(const uint64_t *src, uint64_t *dst, uint32_t nrows) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(src) type(axi_initiator)                        \
    ptr_addr_interface(axi_target) num_elements(MAX_BEATS)                     \
    max_burst_len(64) max_outstanding_reads(8)
#pragma HLS interface argument(dst) type(axi_initiator)                        \
    ptr_addr_interface(axi_target) num_elements(MAX_BEATS)                     \
    max_burst_len(64) max_outstanding_writes(8)

    // ---- PASS 0: L1 pre-scan -> ONE shared block exponent for the whole pass ----
    // Each row's FFT output magnitude is bounded by that row's L1 norm (sum|re|+|im|);
    // the global max over rows gives a single exponent so every row is scaled the SAME
    // (required for a correct 2-D image -- per-row exponents corrupt the azimuth pass).
    // Data-independent of the FFT: just a cheap sum+max sweep of the input, no transform,
    // no wide temp buffer. Losslessly recovers dynamic range (validated in fixedpoint.py:
    // corr 1.00000 vs float), replacing the underflowing unconditional 1/N scaling.
    uint64_t gmax = 0;
    for (uint32_t r = 0; r < nrows; r++) {
        uint64_t base = (uint64_t)r * BEATS_PER_ROW;
        uint64_t rowsum = 0;
#pragma HLS loop pipeline II(1)
        for (uint32_t b = 0; b < BEATS_PER_ROW; b++) {
            uint64_t beat = src[base + b];
            int32_t r0 = s_re((uint32_t)beat),         i0 = s_im((uint32_t)beat);
            int32_t r1 = s_re((uint32_t)(beat >> 32)), i1 = s_im((uint32_t)(beat >> 32));
            r0 = r0 < 0 ? -r0 : r0;  i0 = i0 < 0 ? -i0 : i0;
            r1 = r1 < 0 ? -r1 : r1;  i1 = i1 < 0 ? -i1 : i1;
            rowsum += (uint64_t)(r0 + i0 + r1 + i1);
        }
        if (rowsum > gmax) gmax = rowsum;
    }
    // block exponent = shifts to bring gmax <= 32767 (fits signed int16). Fixed 40-iter
    // loop with a constant >>1 -> no variable-position shift (SmartHLS-analyzer safe).
    unsigned out_shift = 0;
    {
        uint64_t g = gmax;
        for (int it = 0; it < 40; it++) {
            if (g > 32767u) { g >>= 1; out_shift++; }
        }
    }

    // ---- PASS 1: full-precision FFT per row, output normalized by the shared exponent ----
    for (uint32_t r = 0; r < nrows; r++) {
        hls::FIFO<fft_data_t> in(FFT_N);
        hls::FIFO<fft_data_t> out(FFT_N);
        uint64_t base = (uint64_t)r * BEATS_PER_ROW;

        // load: 4096 beats -> 8192 complex samples into the input FIFO
#pragma HLS loop pipeline II(1)
        for (uint32_t b = 0; b < BEATS_PER_ROW; b++) {
            uint64_t beat = src[base + b];
            uint32_t s0 = (uint32_t)(beat & 0xFFFFFFFFu);        // sample0 (low)
            uint32_t s1 = (uint32_t)(beat >> 32);                // sample1 (high)
            fft_data_t d0; d0.re = s_re(s0); d0.im = s_im(s0);
            fft_data_t d1; d1.re = s_re(s1); d1.im = s_im(s1);
            in.write(d0);
            in.write(d1);
        }

        hls::dsp::fft_in_place_bfp<FFT_N>(in, out, out_shift);

        // store: 8192 complex samples -> 4096 beats
#pragma HLS loop pipeline II(1)
        for (uint32_t b = 0; b < BEATS_PER_ROW; b++) {
            fft_data_t d0 = out.read();
            fft_data_t d1 = out.read();
            uint32_t s0 = s_pk(d0.re, d0.im);
            uint32_t s1 = s_pk(d1.re, d1.im);
            dst[base + b] = ((uint64_t)s1 << 32) | (uint64_t)s0;
        }
    }
}

#ifndef __SYNTHESIS__
// Software-only testbench (bit-accurate ap_fixpt/ap_int sim via `shls sw`).
// Reads tb_in.hex (4096 lines, one 16-hex-digit uint64 beat/line) from the
// current working dir, runs one 8192-point FFT row, writes tb_out.hex.
#include <stdio.h>
int main() {
    static uint64_t src[BEATS_PER_ROW];
    static uint64_t dst[BEATS_PER_ROW];

    FILE *fin = fopen("tb_in.hex", "r");
    if (!fin) { fprintf(stderr, "ERROR: cannot open tb_in.hex\n"); return 1; }
    for (uint32_t b = 0; b < BEATS_PER_ROW; b++) {
        unsigned long long v = 0;
        if (fscanf(fin, "%llx", &v) != 1) {
            fprintf(stderr, "ERROR: tb_in.hex short read at line %u\n", b);
            fclose(fin);
            return 1;
        }
        src[b] = (uint64_t)v;
    }
    fclose(fin);

    fft_kernel(src, dst, 1);

    FILE *fout = fopen("tb_out.hex", "w");
    if (!fout) { fprintf(stderr, "ERROR: cannot open tb_out.hex\n"); return 1; }
    for (uint32_t b = 0; b < BEATS_PER_ROW; b++) {
        fprintf(fout, "%016llx\n", (unsigned long long)dst[b]);
    }
    fclose(fout);
    printf("fft_kernel tb: wrote %u beats to tb_out.hex\n", BEATS_PER_ROW);
    return 0;
}
#endif
