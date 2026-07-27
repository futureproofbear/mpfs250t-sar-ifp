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
    parameter integer MAX_BURST  = 64,     // beats per AR/AW; 64 beats x 8 B = 512 B = one tile row
    parameter integer GRID       = 8192    // frame edge; overridden small in the TB so a run is seconds
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

    // ============================ geometry ============================
    // H and W are the frame edge. The SmartHLS register map carries no dims -- ct2_strip_arm()
    // passes only src/dst/c_base/c_count -- so the grid is fixed, exactly as the HLS kernel had it.
    localparam integer EL_B   = 4;                       // element = uint32
    localparam integer EPB    = AXI_DATA_W / (EL_B*8);   // elements per beat = 2
    localparam integer ROWBTS = (T / EPB);               // beats per tile row = 64

    // Tile origin. c0 walks the strip [c_base, c_base+c_count), r0 walks the full height.
    reg [15:0] r0, c0;
    wire [15:0] c_end   = (c_count == 32'd0) ? GRID[15:0] : (c_base[15:0] + c_count[15:0]);
    wire [15:0] c_first = (c_count == 32'd0) ? 16'd0      : c_base[15:0];
    // Ragged edges: the last tile in each direction may be short (min() in corner_turn.cpp).
    wire [15:0] th = ((GRID   - r0) < T) ? (GRID[15:0]   - r0) : T[15:0];
    wire [15:0] tw = ((c_end  - c0) < T) ? (c_end        - c0) : T[15:0];

    // ============================ FILL: src -> tile buffer ============================
    // One AR per tile row: tw elements, contiguous, = tw/EPB beats. Bursts never cross 4 KB
    // because a tile row is 512 B and every row base is 4-byte aligned within a 32 KiB row.
    localparam F_IDLE=2'd0, F_AR=2'd1, F_DATA=2'd2, F_DONE=2'd3;
    reg [1:0]  fst;
    reg [15:0] fi;                       // which row of the tile
    reg [8:0]  frem;                     // beats still expected in this burst
    reg [T_LOG2-2:0] fcol;               // element-PAIR index within the row (one bit narrower)

    wire [31:0] src_row_off = (({16'd0, r0} + {16'd0, fi}) * GRID + {16'd0, c0}) * EL_B;
    wire [8:0]  f_beats     = tw[T_LOG2:1];            // tw/2, tw is even for T=128 tiles

    // ============================ DRAIN: tile buffer -> dst ============================
    localparam D_IDLE=2'd0, D_AW=2'd1, D_DATA=2'd2, D_DONE=2'd3;
    reg [1:0]  dst_st;
    reg [15:0] dj;                       // which column of the tile == which dst row
    reg [8:0]  drem;
    reg [T_LOG2-2:0] drow;               // element-PAIR index down the column (one bit narrower)

    wire [31:0] dst_row_off = (({16'd0, c0} + {16'd0, dj}) * GRID + {16'd0, r0}) * EL_B;
    wire [8:0]  d_beats     = th[T_LOG2:1];            // th/2

    // ---- bank access ---------------------------------------------------------------------
    // FILL beat k of row i carries elements (i,2k) and (i,2k+1): banks i&1 and ~(i&1), SAME
    // address {i,k}.  DRAIN beat k of column j carries (2k,j) and (2k+1,j): banks j&1 and
    // ~(j&1) at addresses {2k, j>>1} and {2k+1, j>>1}.  Both pairs straddle the banks -- that
    // is the whole point of bank = (i^j)&1.
    wire        f_lo_bank = fi[0];
    wire [TW_AW-1:0] f_addr = {fi[T_LOG2-1:0], fcol};
    wire        d_lo_bank = dj[0];
    /* The bank read is REGISTERED, so d_q0/d_q1 lag their address by a cycle. Addressing on `drow`
     * therefore presents beat k-1's data as beat k -- the TB caught exactly that (dst[2] carried
     * dst[0]'s value). Address on the NEXT drow instead, so the registered output lands in step
     * with the beat being presented. */
    wire [T_LOG2-2:0] drow_nxt = ((dst_st == D_DATA) && m_wready) ? (drow + 1'b1) : drow;
    wire [T_LOG2-1:0] d_row_lo = {drow_nxt, 1'b0};   // element row 2*drow
    wire [T_LOG2-1:0] d_row_hi = {drow_nxt, 1'b1};   // element row 2*drow+1
    wire [TW_AW-1:0] d_addr_lo = {d_row_lo, dj[T_LOG2-1:1]};
    wire [TW_AW-1:0] d_addr_hi = {d_row_hi, dj[T_LOG2-1:1]};

    reg [31:0] d_q0, d_q1;
    always @(posedge clk) begin
        if (fst == F_DATA && m_rvalid && m_rready) begin
            if (f_lo_bank) begin
                bank1[f_addr] <= m_rdata[31:0];
                bank0[f_addr] <= m_rdata[63:32];
            end else begin
                bank0[f_addr] <= m_rdata[31:0];
                bank1[f_addr] <= m_rdata[63:32];
            end
        end
        d_q0 <= d_lo_bank ? bank1[d_addr_lo] : bank0[d_addr_lo];
        d_q1 <= d_lo_bank ? bank0[d_addr_hi] : bank1[d_addr_hi];
    end

    assign m_arid    = {AXI_ID_W{1'b0}};
    assign m_awid    = {AXI_ID_W{1'b0}};
    assign m_arsize  = 3'b011;                 // 8 bytes/beat -- FULL WIDTH, unlike the HLS kernel
    assign m_awsize  = 3'b011;
    assign m_arburst = 2'b01;                  // INCR
    assign m_awburst = 2'b01;
    assign m_wstrb   = {(AXI_DATA_W/8){1'b1}}; // every beat carries 2 whole elements

    // ============================ FILL / DRAIN sequencer ============================
    // SINGLE-BUFFERED for now: fill a tile, then drain it. That already wins the ~2x from
    // full-width beats. Double buffering (fill n+1 while draining n) is the follow-on that
    // attacks the 41.5% idle, and it is deliberately NOT bundled here -- the TB lands first so
    // the overlap cannot silently change the data.
    assign m_rready = (fst == F_DATA);
    assign m_wvalid = (dst_st == D_DATA);
    assign m_wdata  = {d_q1, d_q0};
    assign m_wlast  = (drem == 9'd1);
    assign m_bready = 1'b1;

    reg last_tile;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            fst <= F_IDLE; dst_st <= D_IDLE; busy <= 1'b0;
            r0 <= 16'd0; c0 <= 16'd0; fi <= 16'd0; dj <= 16'd0;
            fcol <= {(T_LOG2-1){1'b0}}; drow <= {(T_LOG2-1){1'b0}};
            frem <= 9'd0; drem <= 9'd0;
            m_arvalid <= 1'b0; m_awvalid <= 1'b0;
            m_araddr <= {AXI_ADDR_W{1'b0}}; m_awaddr <= {AXI_ADDR_W{1'b0}};
            m_arlen <= 8'd0; m_awlen <= 8'd0; last_tile <= 1'b0;
        end else begin
            if (start_pulse && !busy) begin
                busy <= 1'b1; last_tile <= 1'b0;
                r0 <= 16'd0; c0 <= c_first;
                fi <= 16'd0; fcol <= {(T_LOG2-1){1'b0}};
                fst <= F_AR;
            end

            // ---- FILL: one AR per tile row, tw/2 beats each ----
            case (fst)
            F_AR: begin
                if (!m_arvalid) begin
                    m_araddr  <= src_base + src_row_off;
                    m_arlen   <= f_beats[7:0] - 8'd1;
                    m_arvalid <= 1'b1;
                    frem      <= f_beats;
                    fcol      <= {(T_LOG2-1){1'b0}};
                end else if (m_arready) begin
                    m_arvalid <= 1'b0;
                    fst       <= F_DATA;
                end
            end
            F_DATA: if (m_rvalid) begin
                fcol <= fcol + 1'b1;
                frem <= frem - 1'b1;
                if (frem == 9'd1) begin
                    if (fi + 16'd1 >= th) begin fst <= F_DONE; end
                    else begin fi <= fi + 16'd1; fst <= F_AR; end
                end
            end
            F_DONE: begin
                // hand the tile to the drain side
                dj     <= 16'd0;
                drow   <= {(T_LOG2-1){1'b0}};
                dst_st <= D_AW;
                fst    <= F_IDLE;
            end
            default: ;
            endcase

            // ---- DRAIN: one AW per tile column, th/2 beats each ----
            case (dst_st)
            D_AW: begin
                if (!m_awvalid) begin
                    m_awaddr  <= dst_base + dst_row_off;
                    m_awlen   <= d_beats[7:0] - 8'd1;
                    m_awvalid <= 1'b1;
                    drem      <= d_beats;
                    drow      <= {(T_LOG2-1){1'b0}};
                end else if (m_awready) begin
                    m_awvalid <= 1'b0;
                    dst_st    <= D_DATA;
                end
            end
            D_DATA: if (m_wready) begin
                drow <= drow + 1'b1;
                drem <= drem - 1'b1;
                if (drem == 9'd1) begin
                    if (dj + 16'd1 >= tw) dst_st <= D_DONE;
                    else begin dj <= dj + 16'd1; dst_st <= D_AW; end
                end
            end
            D_DONE: begin
                // advance to the next tile: c0 across the strip, then r0 down the frame
                if (c0 + T[15:0] >= c_end) begin
                    c0 <= c_first;
                    if (r0 + T[15:0] >= GRID[15:0]) begin
                        busy   <= 1'b0;       // whole frame (or strip) done
                        dst_st <= D_IDLE;
                    end else begin
                        r0 <= r0 + T[15:0];
                        fi <= 16'd0; fst <= F_AR; dst_st <= D_IDLE;
                    end
                end else begin
                    c0 <= c0 + T[15:0];
                    fi <= 16'd0; fst <= F_AR; dst_st <= D_IDLE;
                end
            end
            default: ;
            endcase
        end
    end

endmodule
