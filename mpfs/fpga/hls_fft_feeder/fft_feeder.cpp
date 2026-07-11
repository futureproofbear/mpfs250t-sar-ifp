// fft_feeder.cpp -- memory->stream feeder for the CoreFFT read path.
//
// The CoreAXI4DMAController's AXI4-Stream interface is TARGET-only (stream->memory):
// it can write CoreFFT results back to DDR (S2MM) but cannot SOURCE the DDR->CoreFFT
// feed. This kernel fills that gap: an AXI4 read master pulls 64-bit beats (two
// complex int16 samples each, {I,Q}=32b per sample, matching the gearbox/fft_golden
// layout) from DDR and emits them on an AXI4-Stream master. The corefft_stream64
// gearbox then de-interleaves each beat into CoreFFT's native 1-sample/cycle input.
//
// Full read path:  DDR --(feeder axi_initiator)--> AXI4-Stream --> gearbox.s_axis
//                  --> CoreFFT.datai
// SmartHLS maps a top-level hls::FIFO<T> output argument to an AXI4-Stream master
// (TDATA width = 8*sizeof(T) = 64), with TREADY backpressure -- so the feed is
// rate-matched to CoreFFT's consumption through the gearbox automatically.

#include <stdint.h>
#include "hls/streaming.hpp"

// 8192-point FFT, 2 complex samples per 64-bit beat -> 4096 beats per transform.
// The worst-case single call streams the whole frame (8192 transforms); the driver
// sets the actual beat count at runtime via the nbeats control register.
#define FEED_MAX_BEATS (8192u * 4096u)

void fft_feeder(const uint64_t *src, hls::FIFO<uint64_t> &out, uint32_t nbeats) {
#pragma HLS function top
// CPU-driven control: start/finish + scalar args (nbeats) + the src base address
// land in an AXI4-Lite register map (axi_target) the CPU writes/polls. The bulk
// data still streams over a separate axi_initiator master to DDR.
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(src) type(axi_initiator)                         \
    ptr_addr_interface(axi_target) num_elements(FEED_MAX_BEATS)                 \
    max_burst_len(64) max_outstanding_reads(8)
// keep the FIFO output as a streaming interface -> AXI4-Stream master (override the
// axi_target default, which would otherwise make it a RAM-backed memory interface)
#pragma HLS interface argument(out) type(simple)
#pragma HLS loop pipeline II(1)
    for (uint32_t i = 0; i < nbeats; i++) {
        out.write(src[i]);
    }
}
