// fft_feeder_top.v -- drop-in Verilog replacement for the SmartHLS fft_feeder_top.
// Exposes the SAME bus interfaces as the HLS core (reuse component/.../fft_feeder_top.xml),
// wrapping the sim-validated hand-written `fft_feeder_v`:
//   axi4initiator  : AXI4 READ master (ar_/r_ only)     -> DIC:AXI4minitiator4 -> DDR
//   axi4target     : AXI4 slave (64-bit, control regs)  <- CIC:AXI4mtarget4 (CPU @0x60004000)
//   out_var{,_valid,_ready} : AXI4-Stream               -> GBX:s_axis
//   clk, reset (ACTIVE-HIGH, unlike fft_feeder_v's resetn)
//
// DRAFT for Phase B reconstruction (runbook §8). Compile-checked; ID widths (IDW) and the
// axi4target addr width must be re-verified against the CIC target4 during the rebuild.
// The read master's AXI ID must match the DIC initiator port (DIC 8-bit -> ID_FIX -> 4-bit FIC).
`timescale 1ns/1ps
module fft_feeder_top #(parameter integer IDW = 4) (
    input  wire        clk,
    input  wire        reset,                 // active-HIGH (SmartHLS convention)

    // ---- axi4initiator: AXI4 read master to DDR ----
    output wire [31:0] axi4initiator_ar_addr,
    output wire [1:0]  axi4initiator_ar_burst,
    output wire [7:0]  axi4initiator_ar_len,
    output wire [2:0]  axi4initiator_ar_size,
    output wire        axi4initiator_ar_valid,
    input  wire        axi4initiator_ar_ready,
    input  wire [63:0] axi4initiator_r_data,
    input  wire        axi4initiator_r_last,
    input  wire [1:0]  axi4initiator_r_resp,
    input  wire        axi4initiator_r_valid,
    output wire        axi4initiator_r_ready,

    // ---- axi4target: AXI4 slave, control regs (64-bit data, 6-bit addr, ID) ----
    // Addr widened 5->6 bits to reach the fused-gather registers 0x20..0x2c (GATHER_CTRL,
    // IDX_BASE, WQ_BASE, GATHER_DIMS). The CIC AXI4mtarget4 must present araddr/awaddr[5:0].
    input  wire [5:0]  axi4target_awaddr,
    input  wire [IDW-1:0] axi4target_awid,
    input  wire [7:0]  axi4target_awlen,
    input  wire [2:0]  axi4target_awsize,
    input  wire [1:0]  axi4target_awburst,
    input  wire        axi4target_awvalid,
    output wire        axi4target_awready,
    input  wire [63:0] axi4target_wdata,
    input  wire [7:0]  axi4target_wstrb,
    input  wire        axi4target_wlast,
    input  wire        axi4target_wvalid,
    output wire        axi4target_wready,
    output wire [IDW-1:0] axi4target_bid,
    output wire [1:0]  axi4target_bresp,
    output wire        axi4target_bvalid,
    input  wire        axi4target_bready,
    input  wire [5:0]  axi4target_araddr,
    input  wire [IDW-1:0] axi4target_arid,
    input  wire [7:0]  axi4target_arlen,
    input  wire [2:0]  axi4target_arsize,
    input  wire [1:0]  axi4target_arburst,
    input  wire        axi4target_arvalid,
    output wire        axi4target_arready,
    output wire [63:0] axi4target_rdata,
    output wire [IDW-1:0] axi4target_rid,
    output wire [1:0]  axi4target_rresp,
    output wire        axi4target_rlast,
    output wire        axi4target_rvalid,
    input  wire        axi4target_rready,

    // ---- AXI4-Stream output to the gearbox ----
    output wire [63:0] out_var,
    output wire        out_var_valid,
    input  wire        out_var_ready,

    // ---- CoreFFT block-floating-point exponent capture (routed from FFT:SCALE_EXP and
    // FFT:OUTP_READY). Latched per frame, read back at control reg 0x14 for the pipeline's
    // global-block-exponent renormalize (sar_sequencer.c). ----
    input  wire [3:0]  scale_exp_in,
    input  wire        outp_ready_in
);
    wire resetn = ~reset;                      // fft_feeder_v is active-low

    // ---- axi4target (full AXI4, 64-bit) -> fft_feeder_v AXI4-Lite (32-bit) bridge ----
    // The 32-bit regs (0x08/0x0c/0x10) sit in a 64-bit word; addr bit[2] picks the lane.
    wire        li_awready, li_wready, li_bvalid, li_arready, li_rvalid;
    wire [31:0] li_rdata;
    // AW/W: single-beat register write. s_wdata = the addressed 32-bit lane.
    wire [31:0] wlane = axi4target_awaddr[2] ? axi4target_wdata[63:32] : axi4target_wdata[31:0];
    // B: echo id, OKAY. Register the AW id for the B response.
    reg  [IDW-1:0] bid_r, rid_r;
    always @(posedge clk) begin
        if (axi4target_awvalid && axi4target_awready) bid_r <= axi4target_awid;
        if (axi4target_arvalid && axi4target_arready) rid_r <= axi4target_arid;
    end
    assign axi4target_awready = li_awready;
    assign axi4target_wready  = li_wready;
    assign axi4target_bvalid  = li_bvalid;
    assign axi4target_bid     = bid_r;
    assign axi4target_bresp   = 2'b00;
    assign axi4target_arready = li_arready;
    assign axi4target_rvalid  = li_rvalid;
    assign axi4target_rid     = rid_r;
    assign axi4target_rresp   = 2'b00;
    assign axi4target_rlast   = 1'b1;          // single-beat
    // place the 32-bit readback into the addressed lane (mirror both halves is simplest)
    reg araddr2_r;
    always @(posedge clk) if (axi4target_arvalid && axi4target_arready) araddr2_r <= axi4target_araddr[2];
    assign axi4target_rdata = {li_rdata, li_rdata};   // consumer takes the correct half

    fft_feeder_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(IDW)) u_feeder (
        .clk(clk), .resetn(resetn),
        // control (AXI4-Lite view): map addr to {7'd0, 5-bit byte offset}
        .s_awaddr({6'd0, axi4target_awaddr}), .s_awvalid(axi4target_awvalid), .s_awready(li_awready),
        .s_wdata(wlane), .s_wvalid(axi4target_wvalid), .s_wready(li_wready),
        .s_bvalid(li_bvalid), .s_bready(axi4target_bready),
        .s_araddr({6'd0, axi4target_araddr}), .s_arvalid(axi4target_arvalid), .s_arready(li_arready),
        .s_rdata(li_rdata), .s_rvalid(li_rvalid), .s_rready(axi4target_rready),
        // read master -> axi4initiator
        .m_arid(),                                       // ID assigned by the interconnect side
        .m_araddr(axi4initiator_ar_addr), .m_arlen(axi4initiator_ar_len),
        .m_arsize(axi4initiator_ar_size), .m_arburst(axi4initiator_ar_burst),
        .m_arvalid(axi4initiator_ar_valid), .m_arready(axi4initiator_ar_ready),
        .m_rid({IDW{1'b0}}), .m_rdata(axi4initiator_r_data), .m_rlast(axi4initiator_r_last),
        .m_rvalid(axi4initiator_r_valid), .m_rready(axi4initiator_r_ready),
        // stream out
        .m_axis_tdata(out_var), .m_axis_tvalid(out_var_valid), .m_axis_tready(out_var_ready),
        // CoreFFT block-exponent capture
        .scale_exp_in(scale_exp_in), .outp_ready_in(outp_ready_in)
    );
endmodule
