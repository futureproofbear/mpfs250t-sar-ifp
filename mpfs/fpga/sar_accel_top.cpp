// sar_accel_top.cpp -- SAR focuser top-level dataflow (HLS TEMPLATE, UNVERIFIED).
//
// STATUS: architectural skeleton for Microchip SmartHLS. NOT synthesized or
// simulated. It shows the on-fabric datapath and the DDR/DMA boundary that the
// host (host/sar_pipeline.py + accel.py FpgaBackend) drives via the registers
// in ../regmap.md. The control args below mirror that register map.
//
// Datapath (the work offloaded from the U54 CPUs):
//
//   signal[M,N] --DMA--> [range resample (KR)] -> [window x] -> [1-D FFT] ----+
//                                                                             |
//                                                            corner-turn (BRAM tiles)
//                                                                             |
//   detected[M,N] <--DMA-- [detect |.|] <- [1-D FFT] <- [azimuth resample (KC)]+
//
// What stays on the CPU (NOT here): CPHD/metadata parse, KR/KC/window/geometry
// table prep, ECEF->UTM geocode, GeoTIFF encode, storage I/O.

#include <hls_stream.h>
#include "fft1d.cpp"

// AXI master to coherent DDR for each buffer; AXI4-Lite for control regs.
#pragma SDS data zero_copy(signal, kr, kc, tanphi, win, out)

extern void fft1d(hls::stream<cplx>&, hls::stream<cplx>&, int&);

// Linear-interpolation resampler: emit OUT samples on a uniform grid `grid`
// from input samples whose source coordinates are `src` (monotonic). One line.
static void resample_line(const cplx *inln, const float *src, const float *grid,
                          int n_in, int n_out, hls::stream<cplx> &out) {
    int j = 0;
RESAMP:
    for (int i = 0; i < n_out; i++) {
#pragma HLS pipeline II=1
        float g = grid[i];
        while (j < n_in - 2 && src[j + 1] < g) j++;
        float t = (g - src[j]) / (src[j + 1] - src[j] + 1e-12f);
        cplx a = inln[j], b = inln[j + 1], o;
        o.re = a.re + (data_t)t * (b.re - a.re);
        o.im = a.im + (data_t)t * (b.im - a.im);
        out.write((g < src[0] || g > src[n_in - 1]) ? cplx{0, 0} : o);   // zero-fill edges
    }
}

// Corner-turn tile size: TxT cplx tile in BRAM/URAM. T=64 -> 16 KB/tile; raise to
// 128 (64 KB) for longer DDR bursts if write bandwidth dominates. See
// corner_turn.cpp (verified model) and M2_integration.md (burst analysis).
#ifndef CT_TILE
#define CT_TILE 64
#endif

// Tiled DDR->DDR transpose of a complex frame: src is H x W range-major, dst is
// W x H azimuth-major. Same algorithm as corner_turn.cpp, on cplx via AXI masters.
static void corner_turn_cplx(const cplx *src, cplx *dst, int H, int W) {
    static cplx tile[CT_TILE][CT_TILE];
#pragma HLS bind_storage variable=tile type=ram_t2p impl=bram
    for (int r0 = 0; r0 < H; r0 += CT_TILE) {
        for (int c0 = 0; c0 < W; c0 += CT_TILE) {
            int th = (H - r0 < CT_TILE) ? (H - r0) : CT_TILE;
            int tw = (W - c0 < CT_TILE) ? (W - c0) : CT_TILE;
        CT_RD:
            for (int i = 0; i < th; i++)
#pragma HLS pipeline II=1
                for (int j = 0; j < tw; j++) tile[i][j] = src[(r0 + i) * W + (c0 + j)];
        CT_WR:
            for (int j = 0; j < tw; j++)
#pragma HLS pipeline II=1
                for (int i = 0; i < th; i++) dst[(c0 + j) * H + (r0 + i)] = tile[i][j];
        }
    }
}

// Top level: the host sets dims + buffer addresses, then CTRL.START.
// Buffers (regmap.md): signal = SIG (input, reused as azimuth-major k-space after
// the corner-turn), scratch = SCRATCH (range-major k-space), out = OUT. This
// ping-pong keeps the working set at SIG(256MB)+SCRATCH(256MB)+OUT(128MB); the
// 256 MB frame is ~100x on-chip SRAM, so both passes stream from DDR.
void sar_accel_top(cplx *signal, cplx *scratch, const float *kr, const float *kc,
                   const float *tanphi, const float *win, unsigned char *out,
                   int M, int N, int FFT_LEN_R, int FFT_LEN_A, int &bfp_shift) {

    // --- PASS 1: per pulse -> range resample -> window -> range FFT ---------
    // Output streamed to SCRATCH range-major: scratch[pulse * FFT_LEN_R + bin].
    // Rows p >= M are zero-padded so the azimuth FFT sees a full FFT_LEN_A column.
PASS1:
    for (int p = 0; p < FFT_LEN_A; p++) {
        if (p < M) {
            hls::stream<cplx> s_rs, s_win, s_fft;
#pragma HLS stream variable=s_rs depth=64
#pragma HLS stream variable=s_win depth=64
#pragma HLS stream variable=s_fft depth=64
            // resample this pulse onto the N-point uniform range grid (matches the
            // reference KR length N), then zero-pad to FFT_LEN_R for the FFT.
            resample_line(&signal[p * N], &kr[p * N], /*grid*/ kr, N, N, s_rs);
            for (int i = 0; i < FFT_LEN_R; i++) {
#pragma HLS pipeline II=1
                cplx v;
                if (i < N) {                          // range taper = win[0:N] = hamming(N)
                    v = s_rs.read();
                    v.re *= (data_t)win[i]; v.im *= (data_t)win[i];
                } else {
                    v = cplx{0, 0};                   // zero-pad to FFT_LEN_R
                }
                s_win.write(v);
            }
            int sh;
            fft1d(s_win, s_fft, sh);
            for (int i = 0; i < FFT_LEN_R; i++) scratch[p * FFT_LEN_R + i] = s_fft.read();
        } else {
            for (int i = 0; i < FFT_LEN_R; i++) scratch[p * FFT_LEN_R + i] = cplx{0, 0};
        }
    }

    // --- CORNER-TURN: range-major (FFT_LEN_A x FFT_LEN_R) -> azimuth-major ---
    // Transpose into the SIG buffer (free now that PASS1 consumed it).
    corner_turn_cplx(scratch, signal, FFT_LEN_A, FFT_LEN_R);

    // --- PASS 2: per range bin -> azimuth resample -> azimuth FFT -> detect --
    // signal is now azimuth-major: row b = range bin b, FFT_LEN_A pulses contiguous.
PASS2:
    for (int b = 0; b < FFT_LEN_R; b++) {
        hls::stream<cplx> s_rs, s_win, s_fft;
#pragma HLS stream variable=s_rs depth=64
#pragma HLS stream variable=s_win depth=64
#pragma HLS stream variable=s_fft depth=64
        // azimuth source coords for this bin: KC scaled by tan(phi) per pulse.
        // Resample over the M pulses, apply the azimuth taper, zero-pad to FFT_LEN_A.
        resample_line(&signal[b * FFT_LEN_A], /*src*/ tanphi, kc, M, M, s_rs);
        for (int i = 0; i < FFT_LEN_A; i++) {
#pragma HLS pipeline II=1
            cplx v;
            if (i < M) {                              // azimuth taper = win[N:N+M] = hamming(M)
                v = s_rs.read();
                v.re *= (data_t)win[N + i]; v.im *= (data_t)win[N + i];
            } else {
                v = cplx{0, 0};                       // zero-pad to FFT_LEN_A
            }
            s_win.write(v);
        }
        int sh;
        fft1d(s_win, s_fft, sh);
        bfp_shift = sh;
        for (int i = 0; i < FFT_LEN_A; i++) {
#pragma HLS pipeline II=1
            cplx v = s_fft.read();
            // detect: magnitude -> uint16 (host/CPU applies the dB/percentile AGC;
            // see M2 risk on AGC scaling). out is azimuth-major OUT buffer.
            unsigned mag = (unsigned)hls::sqrtf((float)(v.re * v.re + v.im * v.im));
            ((unsigned short *)out)[b * FFT_LEN_A + i] =
                (mag > 0xFFFFu) ? 0xFFFFu : (unsigned short)mag;
        }
    }
}
