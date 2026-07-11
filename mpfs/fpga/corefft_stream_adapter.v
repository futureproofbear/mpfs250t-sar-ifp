// corefft_stream_adapter.v -- glue between an AXI4-Stream pair (from/to the
// CoreAXI4DMAController) and the Microchip CoreFFT in-place handshake. CoreFFT is
// NOT AXI4-Stream: it loads when DATAI_VALID & BUF_READY, and emits results with
// DATAO_VALID while OUTP_READY, paced by READ_OUTP. This is a thin, combinational
// bridge (valid/ready map cleanly, no FSM needed); 32-bit stream beat = one complex
// sample {I[31:16], Q[15:0]} = WIDTH 16. For a 64-bit DMA stream, add a 64<->32
// gearbox ahead of s_axis / after m_axis (1 beat = 2 samples).
//
// Verified with the real CoreFFT in QuestaSim (see sim/run_stream_adapter.do).

`timescale 1ns/1ps
module corefft_stream_adapter #(parameter integer W = 16) (
    // DDR -> CoreFFT input  (this is the AXI4-Stream *slave*, sunk from the DMA master)
    input  wire [2*W-1:0] s_axis_tdata,
    input  wire           s_axis_tvalid,
    output wire           s_axis_tready,
    // -> CoreFFT input port
    output wire [W-1:0]   datai_re,
    output wire [W-1:0]   datai_im,
    output wire           datai_valid,
    input  wire           buf_ready,
    // CoreFFT output port ->
    input  wire [W-1:0]   datao_re,
    input  wire [W-1:0]   datao_im,
    input  wire           datao_valid,
    input  wire           outp_ready,
    output wire           read_outp,
    // CoreFFT -> DDR output (this is the AXI4-Stream *master*, sourced to the DMA slave)
    output wire [2*W-1:0] m_axis_tdata,
    output wire           m_axis_tvalid,
    input  wire           m_axis_tready
);
    // ---- feed: stream -> CoreFFT input (load when valid & BUF_READY) ----
    assign datai_re      = s_axis_tdata[2*W-1:W];
    assign datai_im      = s_axis_tdata[W-1:0];
    assign datai_valid   = s_axis_tvalid;
    assign s_axis_tready = buf_ready;

    // ---- drain: CoreFFT output -> stream (read while results ready & downstream ready) ----
    assign m_axis_tdata  = {datao_re, datao_im};
    assign m_axis_tvalid = datao_valid;
    assign read_outp     = outp_ready & m_axis_tready;
endmodule
