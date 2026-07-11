// corner_turn.cpp -- tiled DDR->DDR transpose ("corner turn") model + self-test.
//
// THE problem M2 must solve: between the two FFT passes the k-space frame must go
// from range-major to azimuth-major. The frame (8192x8192 complex int16 = 256 MB)
// is ~100x larger than on-chip SRAM, so the transpose streams through DDR. A naive
// column-stride transpose forces one DRAM row-activate per element and wrecks
// LPDDR4 efficiency -- so we move TILES: read a TxT tile (contiguous runs along the
// fast axis), transpose it in on-chip BRAM/URAM, write it back to the destination
// in contiguous runs. This file is the functionally-exact model (verified equal to
// numpy .T for square/ragged/degenerate shapes) and the spec for the HLS kernel.
//
// Element = one complex int16 sample packed as uint32 (I<<16)|Q, matching the
// k-space buffer layout. Logic is element-agnostic, so uint32 is sufficient.
//
// HOST SELF-TEST (no FPGA tools):
//   g++ -O2 -std=c++14 corner_turn.cpp -o corner_turn && ./corner_turn
//
// HARDWARE (HLS): src/dst are AXI masters to the DDR k-space and SCRATCH buffers;
// `buf` is a BRAM/URAM tile; the i/j loops become pipelined burst DMAs. See
// M2_integration.md for tile-size vs burst-length tuning and the DMA wiring.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

// Transpose src (H rows x W cols, row-major) into dst (W rows x H cols, row-major)
// using TxT tiles. dst[(c)*H + r] = src[(r)*W + c]. Ragged edges handled by min().
void corner_turn(const uint32_t *src, uint32_t *dst, int H, int W, int T)
{
    std::vector<uint32_t> buf((size_t)T * T);
    for (int r0 = 0; r0 < H; r0 += T) {
        for (int c0 = 0; c0 < W; c0 += T) {
            int th = (H - r0 < T) ? (H - r0) : T;
            int tw = (W - c0 < T) ? (W - c0) : T;

            // READ tile: th rows, each a contiguous run of tw elems (DDR stride W).
            for (int i = 0; i < th; i++) {
                const uint32_t *s = &src[(size_t)(r0 + i) * W + c0];
                for (int j = 0; j < tw; j++) buf[(size_t)i * T + j] = s[j];
            }
            // WRITE transposed: tw rows in dst, each a contiguous run of th elems
            // (DDR stride H). This is where tiling buys burst-friendly writes.
            for (int j = 0; j < tw; j++) {
                uint32_t *d = &dst[(size_t)(c0 + j) * H + r0];
                for (int i = 0; i < th; i++) d[i] = buf[(size_t)i * T + j];
            }
        }
    }
}

#ifdef CORNER_TURN_SELFTEST
static int check(int H, int W, int T)
{
    std::vector<uint32_t> a((size_t)H * W), t((size_t)W * H), tt((size_t)H * W);
    for (size_t i = 0; i < a.size(); i++) a[i] = (uint32_t)(i * 2654435761u);  // mixed pattern

    corner_turn(a.data(), t.data(), H, W, T);
    for (int r = 0; r < H; r++)
        for (int c = 0; c < W; c++)
            if (t[(size_t)c * H + r] != a[(size_t)r * W + c]) {
                std::printf("  FAIL transpose H=%d W=%d T=%d at (%d,%d)\n", H, W, T, r, c);
                return 1;
            }
    corner_turn(t.data(), tt.data(), W, H, T);   // transpose back == identity
    for (size_t i = 0; i < a.size(); i++)
        if (tt[i] != a[i]) { std::printf("  FAIL identity H=%d W=%d T=%d\n", H, W, T); return 1; }

    std::printf("  ok  H=%-5d W=%-5d T=%-4d  buf=%dKB  burst=%dB\n",
                H, W, T, T * T * 4 / 1024, T * 4);
    return 0;
}

int main(void)
{
    int fails = 0;
    fails += check(64, 64, 64);
    fails += check(8192, 8192, 64);
    fails += check(8192, 8192, 128);
    fails += check(100, 70, 16);     // ragged: T divides neither
    fails += check(65, 63, 16);
    fails += check(1, 257, 32);      // degenerate row/col
    fails += check(257, 1, 32);
    std::printf(fails ? "SELFTEST FAILED (%d)\n" : "SELFTEST PASSED\n", fails);
    return fails ? 1 : 0;
}
#endif
