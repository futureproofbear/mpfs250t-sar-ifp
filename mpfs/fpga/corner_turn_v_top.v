// corner_turn_v_top.v -- HDL+ wrapper around corner_turn_v, pin-compatible with the SmartHLS
// `corner_turn_top` it replaces.
//
// Presents exactly the bus interfaces the SmartDesign already connects:
//     axi4target     <- CIC:AXI4mtarget0   (control, 64-bit AXI4, 6-bit addr)
//     axi4initiator  -> DIC:AXI4minitiator0 (DDR, 64-bit AXI4, read AND write)
// so sartop_assembly.tcl needs only the hdl_core_name swapped, and sar_kernels.h, the firmware
// and every .gdb script are untouched.
//
// Same bridge shape as fft_feeder_top.v: the inner module speaks a 32-bit AXI4-Lite register
// interface, and the control port is a 64-bit AXI4 target, so addr bit[2] picks the lane.
//
// The corner-turn is the only kernel here that is BOTH a read and a write initiator, so this
// wrapper carries both halves -- fft_feeder_top has the read half, fft_unloader_top the write.
`timescale 1ns/1ps
module corner_turn_v_top #(parameter integer IDW = 4) (
    input  wire        clk,
    input  wire        reset,                  // ACTIVE-HIGH, like the HLS core it replaces

    // ---- axi4initiator : DDR (read) ----
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

    // ---- axi4initiator : DDR (write) ----
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

    // ---- axi4target : AXI4-Lite control, presented as 64-bit AXI4 ----
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
    input  wire        axi4target_rready
);
    wire resetn = ~reset;                       // corner_turn_v is active-low

    // ---- axi4target (64-bit AXI4) -> corner_turn_v AXI4-Lite (32-bit) ----
    wire        li_awready, li_wready, li_bvalid, li_arready, li_rvalid;
    wire [31:0] li_rdata;
    wire [31:0] wlane = axi4target_awaddr[2] ? axi4target_wdata[63:32] : axi4target_wdata[31:0];

    reg [IDW-1:0] bid_r, rid_r;
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
    assign axi4target_rlast   = 1'b1;           // single-beat
    assign axi4target_rdata   = {li_rdata, li_rdata};   // consumer takes the addressed half

    corner_turn_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(IDW)) u_ct (
        .clk(clk), .resetn(resetn),
        // control
        .s_awaddr({6'd0, axi4target_awaddr}), .s_awvalid(axi4target_awvalid), .s_awready(li_awready),
        .s_wdata(wlane), .s_wvalid(axi4target_wvalid), .s_wready(li_wready),
        .s_bvalid(li_bvalid), .s_bready(axi4target_bready),
        .s_araddr({6'd0, axi4target_araddr}), .s_arvalid(axi4target_arvalid), .s_arready(li_arready),
        .s_rdata(li_rdata), .s_rvalid(li_rvalid), .s_rready(axi4target_rready),
        // read master
        .m_arid(), .m_araddr(axi4initiator_ar_addr), .m_arlen(axi4initiator_ar_len),
        .m_arsize(axi4initiator_ar_size), .m_arburst(axi4initiator_ar_burst),
        .m_arvalid(axi4initiator_ar_valid), .m_arready(axi4initiator_ar_ready),
        .m_rdata(axi4initiator_r_data), .m_rlast(axi4initiator_r_last),
        .m_rvalid(axi4initiator_r_valid), .m_rready(axi4initiator_r_ready),
        // write master
        .m_awid(), .m_awaddr(axi4initiator_aw_addr), .m_awlen(axi4initiator_aw_len),
        .m_awsize(axi4initiator_aw_size), .m_awburst(axi4initiator_aw_burst),
        .m_awvalid(axi4initiator_aw_valid), .m_awready(axi4initiator_aw_ready),
        .m_wdata(axi4initiator_w_data), .m_wstrb(axi4initiator_w_strb),
        .m_wlast(axi4initiator_w_last), .m_wvalid(axi4initiator_w_valid),
        .m_wready(axi4initiator_w_ready),
        .m_bresp(axi4initiator_b_resp), .m_bvalid(axi4initiator_b_valid),
        .m_bready(axi4initiator_b_ready)
    );
endmodule
