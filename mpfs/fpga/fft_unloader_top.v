// fft_unloader_top.v -- drop-in Verilog replacement for the SmartHLS fft_unloader_top.
// Exposes the SAME bus interfaces as the HLS core, wrapping fft_unloader_v (which adds the
// fused magnitude-detect stage):
//   axi4initiator  : AXI4 WRITE master (aw_/w_/b_ only)  -> DIC:AXI4minitiator5 -> DDR
//   axi4target     : AXI4 slave (64-bit, control regs)   <- CIC:AXI4mtarget5 (CPU @0x60005000)
//   in_var{,_valid,_ready} : AXI4-Stream slave           <- GBX:m_axis
//   clk, reset (ACTIVE-HIGH, unlike fft_unloader_v's resetn)
//
// This mirrors fft_feeder_top.v, which is the silicon-validated precedent for replacing an HLS
// core with hand-written Verilog behind the same interfaces. The initiator pin names are taken
// from a REAL SmartHLS-generated core in this repo (hls_coeffgen/hls_output reports list
// axi4initiator_aw_addr/aw_burst/aw_len/aw_size/w_data/w_last/w_strb/b_resp) rather than
// guessed -- the project rule is to quote an AXI signal name from a file, never invent one.
//
// WHY the unloader is hand-written at all: it now computes |z| = sqrt(I^2+Q^2) inline, and the
// HLS detect kernel was abandoned precisely because SmartHLS mis-synthesized the signed
// narrowing (int16_t)(x>>16) as UNSIGNED, saturating ~50% of the image while passing cosim AND
// a correlation check. See fft_unloader_v.v and tb/tb_fft_unloader_det.v, whose mutation test
// (strip the `signed` qualifiers -> 2035/2048 mismatches) reproduces that exact failure.
`timescale 1ns/1ps
module fft_unloader_top #(parameter integer IDW = 4) (
    input  wire        clk,
    input  wire        reset,                 // active-HIGH (SmartHLS convention)

    // ---- axi4initiator: AXI4 write master to DDR ----
    output wire [31:0] axi4initiator_aw_addr,
    output wire [1:0]  axi4initiator_aw_burst,
    output wire [7:0]  axi4initiator_aw_len,
    output wire [2:0]  axi4initiator_aw_size,
    output wire        axi4initiator_aw_valid,
    input  wire        axi4initiator_aw_ready,
    output wire [63:0] axi4initiator_w_data,
    output wire        axi4initiator_w_last,
    output wire [7:0]  axi4initiator_w_strb,
    output wire        axi4initiator_w_valid,
    input  wire        axi4initiator_w_ready,
    input  wire [1:0]  axi4initiator_b_resp,
    input  wire        axi4initiator_b_valid,
    output wire        axi4initiator_b_ready,

    // ---- axi4target: AXI4 slave, control regs (64-bit data, 5-bit addr, ID) ----
    input  wire [5:0]  axi4target_awaddr,      // 6 bits: the map reaches 0x30 (TAB_DATA-style)
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

    // ---- AXI4-Stream input from the gearbox ----
    input  wire [63:0] in_var,
    input  wire        in_var_valid,
    output wire        in_var_ready
);
    wire resetn = ~reset;                      // fft_unloader_v is active-low

    // ---- axi4target (full AXI4, 64-bit) -> fft_unloader_v AXI4-Lite (32-bit) bridge ----
    // The 32-bit regs sit in 64-bit words; addr bit[2] picks the lane. Same structure as
    // fft_feeder_top.v, which is proven on silicon.
    wire        li_awready, li_wready, li_bvalid, li_arready, li_rvalid;
    wire [31:0] li_rdata;
    wire [31:0] wlane = axi4target_awaddr[2] ? axi4target_wdata[63:32] : axi4target_wdata[31:0];
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
    assign axi4target_rdata   = {li_rdata, li_rdata};   // consumer takes the correct half

    fft_unloader_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(IDW)) u_unl (
        .clk(clk), .resetn(resetn),
        // control (AXI4-Lite view): map addr to {6'd0, 6-bit byte offset}
        .s_awaddr({6'd0, axi4target_awaddr}), .s_awvalid(axi4target_awvalid), .s_awready(li_awready),
        .s_wdata(wlane), .s_wvalid(axi4target_wvalid), .s_wready(li_wready),
        .s_bvalid(li_bvalid), .s_bready(axi4target_bready),
        .s_araddr({6'd0, axi4target_araddr}), .s_arvalid(axi4target_arvalid), .s_arready(li_arready),
        .s_rdata(li_rdata), .s_rvalid(li_rvalid), .s_rready(axi4target_rready),
        // stream in <- gearbox
        .s_axis_tdata(in_var), .s_axis_tvalid(in_var_valid), .s_axis_tready(in_var_ready),
        // write master -> axi4initiator
        .m_awid(),                                       // ID assigned by the interconnect side
        .m_awaddr(axi4initiator_aw_addr), .m_awlen(axi4initiator_aw_len),
        .m_awsize(axi4initiator_aw_size), .m_awburst(axi4initiator_aw_burst),
        .m_awvalid(axi4initiator_aw_valid), .m_awready(axi4initiator_aw_ready),
        .m_wdata(axi4initiator_w_data), .m_wstrb(axi4initiator_w_strb),
        .m_wlast(axi4initiator_w_last), .m_wvalid(axi4initiator_w_valid),
        .m_wready(axi4initiator_w_ready),
        .m_bid({IDW{1'b0}}), .m_bresp(axi4initiator_b_resp),
        .m_bvalid(axi4initiator_b_valid), .m_bready(axi4initiator_b_ready)
    );
endmodule
