// window.cpp -- SmartHLS 2-D Hamming-window multiply (pre-FFT datapath stage).
// Complex int16 sample packed uint32 (I<<16)|Q. The 2-D taper is the outer
// product of two 1-D Hamming tapers (Q15): for row j (range) and col k (cross),
//   win = (hamr[j] * hamc[k]) >> 15  (Q15),   out[i] = in[i] * win >> 15.
// Forming the product on the fly avoids storing the full W*H taper (128 MB at
// 8192^2). hamr/hamc span the data extent and are zero in the FFT zero-pad
// region (host emulate_fabric.py verifies this matches the float golden).
//
// THROUGHPUT: the tapers hamr[H_ROWS]/hamc[W_WIDTH] are cached into on-chip
// arrays up front (one burst read each), then indexed locally so the 67M
// per-pixel DDR taper reads (esp. hamc[i%W] cycling 0..W-1 every row) are gone.
// The flat index+modulo is replaced by nested (j,k) loops: hamr[j] is loop-
// invariant per row, hamc[k] comes from the on-chip cache, and in[]/out[] stay
// row-major sequential (i = j*W_WIDTH + k) so they burst. Inner k loop is II=1.
//   shls sw   # functional check vs inline golden below
#include <stdint.h>
#include <stdio.h>
#ifndef W_WIDTH
#define W_WIDTH 8192            // cross (Mp) row width; k over 0..W_WIDTH-1
#endif
#ifndef H_ROWS
#define H_ROWS  8192            // range (Np) rows; j over 0..H_ROWS-1
#endif
#define WN ((uint64_t)W_WIDTH * H_ROWS)

static inline int16_t hi16(uint32_t x){ return (int16_t)(x >> 16); }
static inline int16_t lo16(uint32_t x){ return (int16_t)(x & 0xFFFF); }
static inline uint32_t pk(int16_t re, int16_t im){
    return (((uint32_t)(uint16_t)re) << 16) | (uint16_t)im; }

void window(uint32_t *in, int16_t *hamr, int16_t *hamc, uint32_t *out) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(in)   type(axi_initiator) ptr_addr_interface(axi_target) num_elements(WN)      max_burst_len(64)
#pragma HLS interface argument(hamr) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(H_ROWS)  max_burst_len(64)
#pragma HLS interface argument(hamc) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(W_WIDTH) max_burst_len(64)
#pragma HLS interface argument(out)  type(axi_initiator) ptr_addr_interface(axi_target) num_elements(WN)      max_burst_len(64)

    // On-chip taper caches: read each DDR taper once (burst-friendly), then
    // index locally in the pixel loops. Simple RAM (read latency 1) is enough.
    static int16_t hamr_c[H_ROWS];
    static int16_t hamc_c[W_WIDTH];

#pragma HLS loop pipeline
    for (int j = 0; j < H_ROWS; j++) {
        hamr_c[j] = hamr[j];
    }
#pragma HLS loop pipeline
    for (int k = 0; k < W_WIDTH; k++) {
        hamc_c[k] = hamc[k];
    }

    // Per-row combined taper, HOISTED off the pixel path. hamr[j]*hamc[k] is DATA-INDEPENDENT and
    // hamr[j] is loop-invariant across the row, so compute cw[k]=(hamr[j]*hamc[k])>>15 once per row.
    // This breaks the chained multiply (hamr*hamc -> *I) that was the ~14 ns critical path (WIN):
    // the pixel loop is now a SINGLE multiply (I*cw, Q*cw). Bit-identical (cw is the same Q15 taper).
    static int16_t cw[W_WIDTH];
    for (int j = 0; j < H_ROWS; j++) {
        int16_t hr = hamr_c[j];
        uint64_t base = (uint64_t)j * W_WIDTH;  // i = base + k, stays sequential
#pragma HLS loop pipeline II(1)
        for (int k = 0; k < W_WIDTH; k++)
            cw[k] = (int16_t)(((int32_t)hr * hamc_c[k]) >> 15);   // Q15 2-D taper, once per row
#pragma HLS loop pipeline II(1)
        for (int k = 0; k < W_WIDTH; k++) {
            uint32_t x = in[base + k];
            int16_t re = (int16_t)(((int32_t)hi16(x) * cw[k]) >> 15);   // single multiply, no chain
            int16_t im = (int16_t)(((int32_t)lo16(x) * cw[k]) >> 15);
            out[base + k] = pk(re, im);
        }
    }
}

#ifndef __SYNTHESIS__
int main() {
    // Small test frame (override W_WIDTH/H_ROWS via -D for sw). Prove the
    // optimized kernel is BIT-IDENTICAL to the original flat-index formula.
    const int W = W_WIDTH, H = H_ROWS, N = W * H;
    static uint32_t in[WN], out[WN], ref[WN];
    static int16_t hamr[H_ROWS], hamc[W_WIDTH];
    for (int j = 0; j < H; j++) hamr[j] = (int16_t)(8000 + j * 137);
    for (int k = 0; k < W; k++) hamc[k] = (int16_t)(4000 + k * 53);
    for (int i = 0; i < N; i++) in[i] = pk((int16_t)(i * 7 - 100), (int16_t)(-i * 3 + 50));

    // Inline reference: the ORIGINAL flat-index+modulo formula.
    for (int i = 0; i < N; i++) {
        int16_t w = (int16_t)(((int32_t)hamr[i / W] * hamc[i % W]) >> 15);
        int16_t re = (int16_t)(((int32_t)hi16(in[i]) * w) >> 15);
        int16_t im = (int16_t)(((int32_t)lo16(in[i]) * w) >> 15);
        ref[i] = pk(re, im);
    }

    window(in, hamr, hamc, out);

    int err = 0;
    for (int i = 0; i < N; i++) if (out[i] != ref[i]) err++;
    printf("window self-check W=%d H=%d N=%d: %s (%d errors)\n",
           W, H, N, err ? "FAIL" : "PASS", err);
    return err ? 1 : 0;
}
#endif
