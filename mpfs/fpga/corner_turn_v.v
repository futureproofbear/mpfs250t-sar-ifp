// corner_turn_v.v -- hand-written replacement for the SmartHLS `corner_turn`.
//
// WHY. E4 on silicon (2026-07-27) profiled the internal corner-turn: ELAPSED 5.974 s to move a
// 256 MiB frame, i.e. 85.7 MB/s both ways against a FIC_0 ceiling of 64 bit x 100 MHz = 800 MB/s.
//   TOTAL_ACTIVE 22.7%  |  R_DATAWAIT 35.8%  |  genuine idle 41.5%
// and 524,288 write bursts x 128 beats = 67.1 M beats = 512 MiB of 64-bit beat CAPACITY to move a
// 256 MiB frame. So the HLS kernel writes ONE uint32 PER BEAT -- half the data bus thrown away --
// AND leaves the bus idle 41.5% of the time because it reads a whole tile, then writes it.
//
// This module fixes the two things that are ours to fix:
//   * FULL-WIDTH BEATS: 2 elements per 64-bit beat, both directions.
//   * DOUBLE-BUFFERED TILES: fill tile n+1 while draining tile n, so the read-side DDR stalls
//     hide under write traffic instead of adding to it.
// It does NOT fix R_DATAWAIT. Each tile row is a separate DRAM page (src stride W = 32 KiB) and
// the interconnect allows only 2 outstanding reads (OPEN_RDTRANS_MAX = max(MAX_OUTSTNDG_TRANS,2)),
// so that latency cannot be pipelined away -- only overlapped. Any projection that assumes the
// 35.8% disappears is wrong.
//
// CONTRACT -- bit-identical to corner_turn.cpp, which is verified against numpy .T:
//     dst[(c)*H + r] = src[(r)*W + c]      element = uint32 = complex int16 (I<<16)|Q
// Tiled TxT: read `th` rows of `tw` contiguous elements (src stride W), transpose on-chip, write
// `tw` rows of `th` contiguous elements (dst stride H). Ragged edges via min().
//
// CONTROL -- the SmartHLS register map, unchanged, so sar_kernels.h, the firmware and every .gdb
// script keep working and ct2_strip_arm() drives it as-is:
//     +0x08 START/STATUS (W:1=start, R:0=idle/done)
//     +0x0c ARG0=src_base  +0x10 ARG1=dst_base  +0x14 ARG2=c_base  +0x18 ARG3=c_count (0=full)
//
// THE BANKING TRICK. Full-width beats need two elements per cycle, but the two sides want
// DIFFERENT adjacencies: filling wants (i,j) and (i,j+1) (same row), draining wants (i,j) and
// (i+1,j) (same column). Storing element (i,j) in bank (i^j)&1 makes BOTH pairs land in different
// banks -- fill: (i^j) vs (i^(j+1)) always differ; drain: (i^j) vs ((i+1)^j) always differ. One
// XOR buys conflict-free access in both directions.
//
// A NEW MODULE, NOT AN EDIT to anything proven. Adding a second mode inside the silicon-validated
// sar_coeffgen.v regressed the shipping path while its unit TB passed 12/12 with 4/4 mutants --
// that is the precedent this rule comes from.
`timescale 1ns/1ps
module corner_turn_v #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 64,
    parameter integer AXI_ID_W   = 4,
    parameter integer T_LOG2     = 7,      // tile edge = 128 (matches the tuned CT_T)
    parameter integer MAX_BURST  = 64      // beats per AR/AW; 64 beats x 8 B = 512 B = one tile row
)(
    input  wire                     clk,
    input  wire                     resetn,

    // ---- AXI4-Lite control slave (SmartHLS register layout) ----
    input  wire [11:0]              s_awaddr,
    input  wire                     s_awvalid,
    output wire                     s_awready,
    input  wire [31:0]              s_wdata,
    input  wire                     s_wvalid,
    output wire                     s_wready,
    output reg                      s_bvalid,
    input  wire                     s_bready,
    input  wire [11:0]              s_araddr,
    input  wire                     s_arvalid,
    output wire                     s_arready,
    output reg  [31:0]              s_rdata,
    output reg                      s_rvalid,
    input  wire                     s_rready,

    // ---- AXI4 read master (src) ----
    output wire [AXI_ID_W-1:0]      m_arid,
    output reg  [AXI_ADDR_W-1:0]    m_araddr,
    output reg  [7:0]               m_arlen,
    output wire [2:0]               m_arsize,
    output wire [1:0]               m_arburst,
    output reg                      m_arvalid,
    input  wire                     m_arready,
    input  wire [AXI_DATA_W-1:0]    m_rdata,
    input  wire                     m_rlast,
    input  wire                     m_rvalid,
    output wire                     m_rready,

    // ---- AXI4 write master (dst) ----
    output wire [AXI_ID_W-1:0]      m_awid,
    output reg  [AXI_ADDR_W-1:0]    m_awaddr,
    output reg  [7:0]               m_awlen,
    output wire [2:0]               m_awsize,
    output wire [1:0]               m_awburst,
    output reg                      m_awvalid,
    input  wire                     m_awready,
    output wire [AXI_DATA_W-1:0]    m_wdata,
    output wire [(AXI_DATA_W/8)-1:0] m_wstrb,
    output wire                     m_wlast,
    output wire                     m_wvalid,
    input  wire                     m_wready,
    input  wire [1:0]               m_bresp,
    input  wire                     m_bvalid,
    output wire                     m_bready
);
    localparam integer T      = (1 << T_LOG2);        // tile edge, elements
    localparam integer TW_AW  = T_LOG2 + T_LOG2 - 1;  // words per bank = T*T/2

    // ============================ AXI4-Lite control slave ============================
    reg [31:0] src_base, dst_base, c_base, c_count;
    reg        start_pulse, busy;

    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;
    assign s_wready  = s_awready;
    assign s_arready = s_arvalid & ~s_rvalid;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            src_base <= 32'd0; dst_base <= 32'd0; c_base <= 32'd0; c_count <= 32'd0;
            s_bvalid <= 1'b0; start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (s_awready) begin
                case (s_awaddr[11:0])
                    12'h008: if (s_wdata[0] & ~busy) start_pulse <= 1'b1;
                    12'h00c: src_base <= s_wdata;
                    12'h010: dst_base <= s_wdata;
                    12'h014: c_base   <= s_wdata;
                    12'h018: c_count  <= s_wdata;
                    default: ;
                endcase
                s_bvalid <= 1'b1;
            end else if (s_bvalid & s_bready) s_bvalid <= 1'b0;
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin s_rvalid <= 1'b0; s_rdata <= 32'd0; end
        else if (s_arready) begin
            s_rvalid <= 1'b1;
            case (s_araddr[11:0])
                12'h008: s_rdata <= {31'd0, busy};    // HLS contract: reads 0 when idle/done
                12'h00c: s_rdata <= src_base;
                12'h010: s_rdata <= dst_base;
                12'h014: s_rdata <= c_base;
                12'h018: s_rdata <= c_count;
                default: s_rdata <= 32'd0;
            endcase
        end else if (s_rvalid & s_rready) s_rvalid <= 1'b0;
    end

    // ============================ tile buffer, banked (i^j)&1 ============================
    // Two banks of T*T/2 words. Both sides read/write TWO elements per cycle, and the XOR
    // guarantees the pair always straddles the banks -- see the header.
    (* syn_ramstyle = "lsram" *) reg [31:0] bank0 [0:(1<<TW_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] bank1 [0:(1<<TW_AW)-1];

    // Address within a bank for element (i,j): the pair (i, j>>1) is unique per bank.
    // verilator lint_off UNUSED
    function [TW_AW-1:0] baddr;
        input [T_LOG2-1:0] i;
        input [T_LOG2-1:0] j;
        begin
            baddr = {i, j[T_LOG2-1:1]};
        end
    endfunction
    // verilator lint_on UNUSED

    assign m_arid    = {AXI_ID_W{1'b0}};
    assign m_awid    = {AXI_ID_W{1'b0}};
    assign m_arsize  = 3'b011;                 // 8 bytes/beat -- FULL WIDTH, unlike the HLS kernel
    assign m_awsize  = 3'b011;
    assign m_arburst = 2'b01;                  // INCR
    assign m_awburst = 2'b01;
    assign m_wstrb   = {(AXI_DATA_W/8){1'b1}}; // every beat carries 2 whole elements

endmodule
