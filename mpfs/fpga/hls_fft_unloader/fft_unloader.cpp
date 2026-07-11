// fft_unloader.cpp -- stream->memory unloader for the CoreFFT WRITE-back path.
//
// Replaces the CoreAXI4DMAController AXI4-Stream S2MM target, which deadlocks on the
// 2nd back-to-back stream transaction (SmartDebug-confirmed: shared AXI-initiator FSM
// stalls, AWVALID stuck low). This kernel is the exact MIRROR of fft_feeder: instead of
// reading DDR and emitting a stream, it CONSUMES the gearbox output stream (64-bit beats,
// two complex int16 samples each) and writes them to DDR through a plain AXI4 WRITE
// master -- the same proven pattern the 5 working HLS kernels use on this silicon.
//
// Full write-back path:  CoreFFT.datao --> gearbox --> gearbox.m_axis (64b stream)
//                        --(fft_unloader.in AXI4-Stream slave)--> DDR (axi_initiator write)
//
// One continuous run drains the WHOLE frame (nbeats = 8192*4096) with no per-transform
// re-arm, no descriptors, no TLAST -- so there is only ever ONE long S2MM operation.
// SmartHLS maps: a top-level hls::FIFO<T> argument the function READS -> AXI4-Stream
// SLAVE (TREADY backpressure to the gearbox); a non-const pointer with axi_initiator +
// max_outstanding_writes -> AXI4 write master (bursts of max_burst_len).

#include <stdint.h>
#include "hls/streaming.hpp"

// 8192-point FFT, 2 complex samples per 64-bit beat -> 4096 beats/transform; worst-case
// one call drains the whole frame (8192 transforms). Driver sets nbeats at runtime.
#define UNLOAD_MAX_BEATS (8192u * 4096u)

void fft_unloader(hls::FIFO<uint64_t> &in, uint64_t *dst, uint32_t nbeats) {
#pragma HLS function top
// CPU-driven control (start/finish + dst base + nbeats) lands in an AXI4-Lite register
// map (axi_target); bulk data is written over a separate axi_initiator master to DDR.
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(dst) type(axi_initiator)                         \
    ptr_addr_interface(axi_target) num_elements(UNLOAD_MAX_BEATS)               \
    max_burst_len(64) max_outstanding_writes(8)
// keep the FIFO input as a streaming interface -> AXI4-Stream SLAVE (override the
// axi_target default, which would make it a RAM-backed memory interface)
#pragma HLS interface argument(in) type(simple)
#pragma HLS loop pipeline II(1)
    for (uint32_t i = 0; i < nbeats; i++) {
        dst[i] = in.read();
    }
}
