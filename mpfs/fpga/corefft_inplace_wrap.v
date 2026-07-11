// corefft_inplace_wrap.v
// Clean in-place CoreFFT wrapper for the SAR range/azimuth FFT (POINTS=8192).
//
// WHY THIS EXISTS (differences vs the prior failed CoreFFT integration):
//  1. Elastic output FIFO drains CoreFFT UNCONDITIONALLY.  The prior wedge
//     (TIMEOUT_FFT1) was downstream backpressure reaching the core's READ_OUTP and
//     PAUSING the in-place core mid-unload.  Here READ_OUTP only ever deasserts if the
//     FIFO is genuinely full; sized to one full frame, drained during the next
//     load/compute, that never happens on transient DDR-burst hiccups.  The FIFO
//     backpressures the UNLOADER (dn_*), NEVER the core.
//  2. SCALE_EXP passthrough.  The old corefft_stream64_adapter dropped the per-frame
//     block-floating-point exponent; without it the host cannot reconstruct true
//     magnitude and the image collapses toward DC.  We latch it per frame and expose it.
//  3. LSRAM show-ahead (FWFT) output FIFO.  An 8192-deep FIFO must map to LSRAM, whose
//     read is REGISTERED (1-cycle latency).  A naive combinational-read FIFO (fine at
//     depth 64 in the old adapter) is a silicon-only bug at this depth, so the read side
//     is a proper show-ahead FIFO with a 1-entry prefetch register.
//
// Core config (already generated, archive/fpga_scripts/gen_corefft.tcl):
//   in-place, POINTS=8192, WIDTH=16, SCALE=0 (conditional BFP), SCALE_EXP_ON=1
//   -> DATAO is WIDTH-bit block-scaled; true value = DATAO * 2^SCALE_EXP.
//
// Data packing (matches mpfs/host/fft_golden.py hex: (uint16(I)<<16)|uint16(Q)):
//   tdata[2W-1:W] = Re, tdata[W-1:0] = Im, both two's complement.
//
// `COREFFT` resolves to corefft_behav.v (sim) or corefft_shim.v -> the real
// COREFFT_C0 (synth), exactly as corefft_fft_tb.v already does.
`timescale 1ns/1ps
module corefft_inplace_wrap #(
    parameter integer W      = 16,
    parameter integer POINTS = 8192,
    parameter integer AW     = 13,        // log2(POINTS)
    parameter integer EW     = 4          // SCALE_EXP width: ceil(log2(POINTS))+1 = 4 @ 8192
)(
    input  wire            clk,
    input  wire            slowclk,       // twiddle-LUT init clock (>= clk/8); pass-through
    input  wire            resetn,        // active-low; drives core NGRST

    // ---- upstream sample feed (AXI4-Stream-like; tolerant of bubbles) ----
    input  wire [2*W-1:0]  up_tdata,      // [2W-1:W]=Re, [W-1:0]=Im
    input  wire            up_tvalid,
    output wire            up_tready,

    // ---- downstream transformed stream to the DDR unloader (elastic) ----
    output wire [2*W-1:0]  dn_tdata,
    output wire            dn_tvalid,
    input  wire            dn_tready,
    output wire            dn_tlast,       // last bin of the frame
    output wire [EW-1:0]   dn_scale_exp,   // this frame's BFP exponent (stable across frame)
    output wire            dn_scale_valid  // high while dn_tdata/dn_scale_exp are valid
);
    // ===================== CoreFFT in-place instance =====================
    wire signed [W-1:0] datai_re = up_tdata[2*W-1:W];
    wire signed [W-1:0] datai_im = up_tdata[W-1:0];
    wire                datai_valid;
    wire                buf_ready;
    wire signed [W-1:0] datao_re, datao_im;
    wire                datao_valid;
    wire                outp_ready;
    wire [EW-1:0]       scale_exp;         // behav drives [4:0]; MSB harmless (shift<=14)
    wire                read_outp;

    COREFFT #(.WIDTH(W), .POINTS(POINTS), .SCALE(0), .SCALE_EXP_ON(1)) u_fft (
        .CLK(clk), .SLOWCLK(slowclk), .NGRST(resetn),
        .DATAI_RE(datai_re), .DATAI_IM(datai_im), .DATAI_VALID(datai_valid),
        .READ_OUTP(read_outp),
        .DATAO_RE(datao_re), .DATAO_IM(datao_im), .DATAO_VALID(datao_valid),
        .BUF_READY(buf_ready), .OUTP_READY(outp_ready), .SCALE_EXP(scale_exp)
    );

    // ---- input: in-place loads to RAM, so bubbles are harmless; gate on BUF_READY ----
    assign datai_valid = up_tvalid & buf_ready;
    assign up_tready   = buf_ready;

    // ===================== elastic output FIFO (LSRAM, show-ahead) =====================
    localparam integer DW = 2*W;
    (* syn_ramstyle = "lsram" *)
    reg  [DW-1:0] mem [0:POINTS-1];
    reg  [AW:0]   wptr, rptr;              // extra MSB distinguishes full/empty
    wire [AW:0]   cnt  = wptr - rptr;      // beats resident in RAM (not counting prefetch reg)
    wire fifo_full  = (cnt == POINTS[AW:0]);

    // Drain the core whenever it has output; only ever stall if the RAM is truly full.
    assign read_outp = outp_ready & ~fifo_full;
    wire   push      = outp_ready & read_outp & datao_valid;

    always @(posedge clk) if (push) mem[wptr[AW-1:0]] <= {datao_re, datao_im};
    always @(posedge clk or negedge resetn)
        if (!resetn)   wptr <= 0;
        else if (push) wptr <= wptr + 1'b1;

    // Show-ahead read: a 1-entry prefetch register in front of the registered LSRAM read
    // gives first-word-fall-through so dn_tvalid/dn_tdata present the head combinationally.
    reg  [DW-1:0] rdata;
    reg           rdata_valid;
    wire          ram_has  = (wptr != rptr);
    wire          consume  = rdata_valid & dn_tready;
    wire          refill   = (~rdata_valid | consume) & ram_has;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rptr <= 0; rdata_valid <= 1'b0;
        end else begin
            if (consume) rdata_valid <= 1'b0;        // head taken this cycle
            if (refill) begin                        // ...override: load next head from RAM
                rdata       <= mem[rptr[AW-1:0]];
                rptr        <= rptr + 1'b1;
                rdata_valid <= 1'b1;
            end
        end
    end

    assign dn_tdata       = rdata;
    assign dn_tvalid      = rdata_valid;
    assign dn_scale_valid = rdata_valid;

    // ---- output beat counter -> TLAST (one frame = POINTS beats) ----
    reg [AW:0] obeat;
    wire last_obeat = (obeat == POINTS-1);
    assign dn_tlast = dn_tvalid & last_obeat;
    always @(posedge clk or negedge resetn)
        if (!resetn)               obeat <= 0;
        else if (consume)          obeat <= last_obeat ? 0 : obeat + 1'b1;

    // ===================== per-frame SCALE_EXP passthrough =====================
    // The exponent must travel WITH its frame: if the unloader is slower than the core,
    // the next frame can compute (updating the core's SCALE_EXP) while this frame's tail
    // is still draining. So capture each frame's exponent as its FIRST beat enters the
    // data FIFO and pop it as its LAST beat leaves -- a 2-deep FIFO covers the <=2 frames
    // that can be simultaneously resident (one frame in RAM + one being prefetched/drained).
    reg [AW:0] ibeat;                         // push-side (input to FIFO) frame position
    wire ibeat_last = (ibeat == POINTS-1);
    always @(posedge clk or negedge resetn)
        if (!resetn)     ibeat <= 0;
        else if (push)   ibeat <= ibeat_last ? 0 : ibeat + 1'b1;

    reg [EW-1:0] exp_mem [0:1];
    reg          ewp, erp;                    // 1-bit -> mod-2 addressing
    wire exp_push = push    & (ibeat == 0);   // first beat of a frame enters the FIFO
    wire exp_pop  = consume & last_obeat;     // last beat of a frame leaves the FIFO
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin ewp <= 1'b0; erp <= 1'b0; end
        else begin
            if (exp_push) begin exp_mem[ewp] <= scale_exp; ewp <= ~ewp; end
            if (exp_pop)  erp <= ~erp;
        end
    end
    assign dn_scale_exp = exp_mem[erp];
endmodule
