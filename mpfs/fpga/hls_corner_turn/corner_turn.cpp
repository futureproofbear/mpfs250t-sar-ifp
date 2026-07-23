// corner_turn.cpp -- SmartHLS SAR corner-turn (DDR->DDR tiled transpose).
// src is H x W range-major; dst is W x H azimuth-major: dst[c*H+r] = src[r*W+c].
// Element = complex int16 packed uint32 (I<<16)|Q. Tiled through on-chip BRAM.
// FUNCTIONALLY VERIFIED: shls sw + cosim PASS (matches ../corner_turn.cpp model).
//
// THROUGHPUT: this kernel DOES generate AXI bursts -- the generated RTL has
// ar_len/aw_len = computed (up to max_burst_len), confirmed in hls_output/rtl.
// (An earlier note here wrongly said ar_len=0/no-burst: that was the LLVM-IR
// SCHEDULING report, not the RTL.) The SmartHLS cosim cycle count (~148k @128x128)
// reflects the generic AXI memory-model BFM latency, NOT real LPDDR4 throughput,
// so it is not a reliable hardware-throughput predictor. By bandwidth: the
// corner-turn moves ~2*256 MB = 512 MB/frame; at FIC ~1.6-3.2 GB/s that is
// ~0.16-0.32 s, within the ~1 s/frame budget. Real throughput = measure on the
// board (or a DDR-controller-accurate sim). Raise max_burst_len / widen AXI to
// improve. A CoreAXI4DMAController transpose remains an alternative but is NOT
// required.

#include <stdint.h>
#include <stdio.h>
#ifndef CT_H
#define CT_H 8192
#endif
#ifndef CT_W
#define CT_W 8192
#endif
#ifndef CT_T
#define CT_T 128           // tile size (CT_H, CT_W multiples of CT_T). 32->128: 128B->512B AXI
                           // bursts to amortize the DDR row-activation cost (corner-turn was
                           // ~67 MB/s / row-activation bound; see SAR_PIPELINE_STATUS priority 1).
#endif

void corner_turn(uint32_t *src, uint32_t *dst) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(src) type(axi_initiator)                        \
    ptr_addr_interface(axi_target) num_elements(CT_H *CT_W)                    \
    max_burst_len(CT_T) max_outstanding_reads(8)
#pragma HLS interface argument(dst) type(axi_initiator)                        \
    ptr_addr_interface(axi_target) num_elements(CT_W *CT_H)                    \
    max_burst_len(CT_T) max_outstanding_writes(8)

    uint32_t tile[CT_T][CT_T];

    for (int r0 = 0; r0 < CT_H; r0 += CT_T) {
        for (int c0 = 0; c0 < CT_W; c0 += CT_T) {
            for (int i = 0; i < CT_T; i++) {
                uint32_t *rp = &src[(r0 + i) * CT_W + c0];
#pragma HLS loop pipeline II(1)
                for (int j = 0; j < CT_T; j++) {
                    tile[i][j] = rp[j];
                }
            }
            for (int j = 0; j < CT_T; j++) {
                uint32_t *wp = &dst[(c0 + j) * CT_H + r0];
#pragma HLS loop pipeline II(1)
                for (int i = 0; i < CT_T; i++) {
                    wp[i] = tile[i][j];
                }
            }
        }
    }
}

int main() {
    static uint32_t src[CT_H * CT_W];
    static uint32_t dst[CT_W * CT_H];
    for (int i = 0; i < CT_H * CT_W; i++) src[i] = (uint32_t)(i * 2654435761u);
    corner_turn(src, dst);
    int errors = 0;
    for (int r = 0; r < CT_H; r++)
        for (int c = 0; c < CT_W; c++)
            if (dst[c * CT_H + r] != src[r * CT_W + c]) errors++;
    printf("corner_turn %dx%d tile %d: %s (%d errors)\n",
           CT_H, CT_W, CT_T, errors ? "FAIL" : "PASS", errors);
    return errors ? 1 : 0;
}
