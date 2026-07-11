// corefft_stream64_adapter.v -- gearbox with an ELASTIC OUTPUT FIFO (skid/decoupling
// buffer) between CoreFFT and the fft_unloader. Same module name + ports as the original
// corefft_stream64_adapter (drop-in), input side unchanged.
//
// WHY: the original output side has only a 1-beat register, so downstream backpressure
// (m_axis_tready low while the unloader forms a DDR burst / arbitrates) propagates straight
// into read_outp and PAUSES CoreFFT mid-unload. The in-place CoreFFT cannot pause its
// sequential RAM unload cleanly -> silicon wedge (feeder + unloader both stuck; range-FFT
// TIMEOUT_FFT1). Confirmed vs the 2x TB (m_tready=1) passing and the pipeline stalling.
//
// FIX: drain CoreFFT UNCONDITIONALLY into a FIFO (read_outp only blocks if the FIFO is truly
// full, which -- with a one-transform-deep FIFO drained during the next compute -- never happens
// in normal operation). The FIFO backpressures the UNLOADER, never CoreFFT. This matches the
// CoreFFT "buffered read" recommendation and the reviewer's skid-buffer guidance.
`timescale 1ns/1ps
module corefft_stream64_adapter #(parameter integer W = 16, parameter integer POINTS = 8192) (
    input  wire clk,
    input  wire resetn,
    input  wire [4*W-1:0] s_axis_tdata,
    input  wire           s_axis_tvalid,
    output wire           s_axis_tready,
    output wire [W-1:0]   datai_re,
    output wire [W-1:0]   datai_im,
    output wire           datai_valid,
    input  wire           buf_ready,
    input  wire [W-1:0]   datao_re,
    input  wire [W-1:0]   datao_im,
    input  wire           datao_valid,
    input  wire           outp_ready,
    output wire           read_outp,
    output wire [4*W-1:0] m_axis_tdata,
    output wire           m_axis_tvalid,
    output wire           m_axis_tlast,
    output wire [1:0]     m_axis_tdest,
    input  wire           m_axis_tready
);
    // ---- input gearbox (UNCHANGED): 64-bit beat -> two 1-sample loads ----
    reg in_phase;
    wire [2*W-1:0] cur = in_phase ? s_axis_tdata[4*W-1:2*W] : s_axis_tdata[2*W-1:0];
    assign datai_re    = cur[2*W-1:W];
    assign datai_im    = cur[W-1:0];
    assign datai_valid = s_axis_tvalid & buf_ready;        // (the input-side fix; keep)
    assign s_axis_tready = in_phase & buf_ready;
    always @(posedge clk or negedge resetn)
        if (!resetn)                        in_phase <= 1'b0;
        else if (s_axis_tvalid & buf_ready) in_phase <= ~in_phase;

    // ---- output: pack two CoreFFT samples into a 64-bit beat, push into an elastic FIFO ----
    // Skid/decoupling buffer. During unload the feeder is backpressured (buf_ready=0) so the
    // interconnect is free and the unloader (<=1 beat/cyc) OUTPACES CoreFFT (0.5 beat/cyc); the
    // FIFO only has to absorb TRANSIENT hiccups (DDR-burst boundaries / arbitration), so a small
    // distributed-RAM depth suffices and CoreFFT never sees backpressure. read_outp only deasserts
    // if the FIFO is genuinely full (does not happen with the unloader keeping up).
    // Depth 64 gives ~20x margin over the observed peak occupancy (3 beats in sim). syn_ramstyle=
    // registers forces an FF+mux (distributed logic), NOT an LSRAM -- an LSRAM's registered read
    // would add a cycle of latency and break this combinational-read handshake (silicon-only bug).
    localparam integer FDEPTH = 64;                        // beats
    localparam integer FAW    = 6;                         // log2(64)
    localparam integer LAT_MARGIN = 8;                     // beats reserved for CoreFFT DATAO in-flight
    (* syn_ramstyle = "registers" *)
    reg  [4*W-1:0] fifo [0:FDEPTH-1];
    reg  [FAW:0]   wptr, rptr;                             // MSB distinguishes full vs empty
    wire [FAW:0]   fcount = wptr - rptr;
    wire fifo_empty = (fcount == 0);

    reg          have_lo;
    reg [2*W-1:0] lo;
    // De-assert read_outp LAT_MARGIN beats BEFORE the FIFO is full, reserving room for the
    // DATAO_VALID beats already in the CoreFFT output pipeline. CoreFFT's DATAO_VALID trails
    // READ_OUTP by ~4 cycles (fftSm.v:595-603), so ~2 beats keep arriving AFTER read_outp
    // de-asserts. Those in-flight beats MUST still be captured (see the capture block below:
    // gated on datao_valid, NOT read_outp) -- gating capture on read_outp drops them, losing
    // samples and flipping the re/im pairing (have_lo) for the rest of the frame. That is the
    // silicon range-FFT starvation bug: the fft_unloader never receives its full 4096 beats
    // and hangs (busy=1, SCRATCH=0). Reproduced + fixed in corefft_stream64_lossck_tb.v.
    wire fifo_almost_full = (fcount >= (FDEPTH - LAT_MARGIN));
    assign read_outp = outp_ready & ~fifo_almost_full;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin have_lo <= 1'b0; wptr <= 0; end
        else if (outp_ready & datao_valid) begin                  // capture EVERY emitted sample
            if (!have_lo) begin                                   // (in-flight beats too -- NOT gated on read_outp)
                lo <= {datao_re, datao_im}; have_lo <= 1'b1;      // hold lower sample
            end else begin
                fifo[wptr[FAW-1:0]] <= {datao_re, datao_im, lo};  // form + push beat
                have_lo <= 1'b0; wptr <= wptr + 1'b1;
            end
        end
    end

    // ---- FIFO read side -> AXI4-Stream master to the unloader ----
    assign m_axis_tdata  = fifo[rptr[FAW-1:0]];
    assign m_axis_tvalid = ~fifo_empty;
    always @(posedge clk or negedge resetn)
        if (!resetn)                          rptr <= 0;
        else if (~fifo_empty & m_axis_tready) rptr <= rptr + 1'b1;

    // ---- TLAST/TDEST retained for port compatibility (unused by the unloader path) ----
    localparam integer BEATS_PER_XFRM = POINTS/2;
    reg [15:0] obeat;
    wire last_obeat = (obeat == BEATS_PER_XFRM-1);
    assign m_axis_tlast = m_axis_tvalid & last_obeat;
    always @(posedge clk or negedge resetn)
        if (!resetn)                            obeat <= 16'd0;
        else if (m_axis_tvalid & m_axis_tready) obeat <= last_obeat ? 16'd0 : (obeat + 16'd1);
    reg tdest_r;
    assign m_axis_tdest = {1'b0, tdest_r};
    always @(posedge clk or negedge resetn)
        if (!resetn)                                        tdest_r <= 1'b0;
        else if (m_axis_tvalid & m_axis_tready & last_obeat) tdest_r <= ~tdest_r;
endmodule
