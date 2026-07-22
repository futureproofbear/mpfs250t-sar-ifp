// tb_axi4_regslice.v -- self-checking TB for axi4_regslice.v (../axi4_regslice.v).
//
// Proves the 5-channel AXI4 register slice: (1) sustains back-to-back beats with ZERO bubble
// when both sides are always ready, (2) survives independent random per-cycle backpressure on
// every channel with no beat lost or duplicated, (3) holds VALID/DATA stable while asserted and
// not accepted, (4) forwards beats bearing arbitrary/repeated/non-monotonic IDs in EXACT
// arrival order and with EVERY field bit-exact (this module does not correlate AR<->R or AW<->B
// at all -- it is a decoupled pipe per channel -- so "different IDs, out-of-order responses,
// order+content preserved" reduces to "whatever order/content is presented on the M/S-side
// input, the same order/content appears on the far side", which is exactly what the per-beat
// scoreboard checks below verify), and (5) that DEPTH is a real parameter (checked against a
// second DUT instance at DEPTH=3, incl. an exact first-beat-latency check == DEPTH on both
// instances).
//
// METHOD: each channel gets an independent driver process (keeps *VALID asserted with
// backpressure-respecting field-hold, pushes the exact accepted beat into a per-channel
// scoreboard array) and an independent monitor process (checks the far side's beat against the
// scoreboard in strict FIFO order, checks VALID/DATA hold-stable while stalled, and -- during
// the back-to-back subphase only, where a gap would be a genuine defect -- checks for bubbles).
// Random field content AND random per-cycle backpressure are both seeded from ONE logged top
// seed (SEED=...) so a failure is reproducible: rerun with the same seed value substituted for
// $time in the `rseed` initializer below.
//
// RUN:
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib work && $MS/vlog -work work tb_axi4_regslice.v ../axi4_regslice.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_axi4_regslice
// Expected: "==== AXI4 REGSLICE: PASS (0 errors) ====".
//
// MUTATION CHECK (must FAIL): axi4_regslice_skid_stage (in ../axi4_regslice.v) has a compile-time
// mutation switch matching the exact bug class named in the design brief -- "a skid buffer that
// overwrites instead of stalling": with `AXI4_REGSLICE_MUTATE_OVERWRITE defined, s_ready is
// forced to always be 1 (instead of ~skid_valid), so a second beat arriving while the skid
// register is already occupied silently clobbers it -- the master believes both beats were
// accepted (it saw s_ready=1 both times) but only the second is ever delivered. Run:
//   $MS/vlog -work work +define+AXI4_REGSLICE_MUTATE_OVERWRITE tb_axi4_regslice.v ../axi4_regslice.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_axi4_regslice
// Expected: FAIL (scoreboard mismatch / drained-beat-count mismatch reported before the run
// completes, or a timeout waiting for a beat that was silently dropped).
`timescale 1ns/1ps

module tb_axi4_regslice;

    // ================================================================ clock / reset ========
    reg ACLK = 0;
    always #8 ACLK = ~ACLK;
    reg ARESETN = 0;

    integer cyc_cnt;
    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) cyc_cnt <= 0; else cyc_cnt <= cyc_cnt + 1;

    reg [31:0] rseed;

    // ================================================================ sizing ===============
    localparam integer ID_W    = 4;
    localparam integer ADDR_W  = 32;
    localparam integer DATA_W  = 64;
    localparam integer STRB_W  = DATA_W/8;
    localparam integer LP_AW   = ID_W + ADDR_W + 31;   // matches axi4_regslice's AW_W/AR_W
    localparam integer LP_AR   = LP_AW;
    localparam integer LP_W    = DATA_W + STRB_W + 2;
    localparam integer LP_B    = ID_W + 2;
    localparam integer LP_R    = ID_W + DATA_W + 3;

    localparam integer QDEPTH  = 4096;
    localparam integer N_BB    = 1000;   // back-to-back beats per channel
    localparam integer N_BP    = 3000;   // random-backpressure beats per channel
    localparam integer N_DEEP  = 500;    // DEPTH=3 sanity beats (AW channel only)

    integer total_errors;

    // ================================================================ DUT #1 (DEPTH=1) ======
    // ---- AW ----
    reg  [ID_W-1:0]   t_s_awid;   reg [ADDR_W-1:0] t_s_awaddr; reg [7:0] t_s_awlen;
    reg  [2:0]        t_s_awsize; reg [1:0] t_s_awburst; reg [1:0] t_s_awlock;
    reg  [3:0]        t_s_awcache; reg [2:0] t_s_awprot; reg [3:0] t_s_awqos;
    reg  [3:0]        t_s_awregion; reg t_s_awuser; reg t_s_awvalid;
    wire               d_s_awready;
    wire [ID_W-1:0]   d_m_awid;   wire [ADDR_W-1:0] d_m_awaddr; wire [7:0] d_m_awlen;
    wire [2:0]        d_m_awsize; wire [1:0] d_m_awburst; wire [1:0] d_m_awlock;
    wire [3:0]        d_m_awcache; wire [2:0] d_m_awprot; wire [3:0] d_m_awqos;
    wire [3:0]        d_m_awregion; wire d_m_awuser; wire d_m_awvalid;
    reg                t_m_awready;

    // ---- W ----
    reg  [DATA_W-1:0] t_s_wdata; reg [STRB_W-1:0] t_s_wstrb; reg t_s_wlast; reg t_s_wuser;
    reg                t_s_wvalid;
    wire               d_s_wready;
    wire [DATA_W-1:0] d_m_wdata; wire [STRB_W-1:0] d_m_wstrb; wire d_m_wlast; wire d_m_wuser;
    wire               d_m_wvalid;
    reg                t_m_wready;

    // ---- B (TB drives the M side, i.e. models the downstream slave's response) ----
    reg  [ID_W-1:0]   t_m_bid; reg [1:0] t_m_bresp; reg t_m_bvalid;
    wire               d_m_bready;
    wire [ID_W-1:0]   d_s_bid; wire [1:0] d_s_bresp; wire d_s_bvalid;
    reg                t_s_bready;

    // ---- AR ----
    reg  [ID_W-1:0]   t_s_arid;   reg [ADDR_W-1:0] t_s_araddr; reg [7:0] t_s_arlen;
    reg  [2:0]        t_s_arsize; reg [1:0] t_s_arburst; reg [1:0] t_s_arlock;
    reg  [3:0]        t_s_arcache; reg [2:0] t_s_arprot; reg [3:0] t_s_arqos;
    reg  [3:0]        t_s_arregion; reg t_s_aruser; reg t_s_arvalid;
    wire               d_s_arready;
    wire [ID_W-1:0]   d_m_arid;   wire [ADDR_W-1:0] d_m_araddr; wire [7:0] d_m_arlen;
    wire [2:0]        d_m_arsize; wire [1:0] d_m_arburst; wire [1:0] d_m_arlock;
    wire [3:0]        d_m_arcache; wire [2:0] d_m_arprot; wire [3:0] d_m_arqos;
    wire [3:0]        d_m_arregion; wire d_m_aruser; wire d_m_arvalid;
    reg                t_m_arready;

    // ---- R (TB drives the M side) ----
    reg  [ID_W-1:0]   t_m_rid; reg [DATA_W-1:0] t_m_rdata; reg [1:0] t_m_rresp; reg t_m_rlast;
    reg                t_m_rvalid;
    wire               d_m_rready;
    wire [ID_W-1:0]   d_s_rid; wire [DATA_W-1:0] d_s_rdata; wire [1:0] d_s_rresp; wire d_s_rlast;
    wire               d_s_rvalid;
    reg                t_s_rready;

    axi4_regslice #(.ID_WIDTH(ID_W), .ADDR_WIDTH(ADDR_W), .DATA_WIDTH(DATA_W), .DEPTH(1)) dut1 (
        .ACLK(ACLK), .ARESETN(ARESETN),
        .S_AXI_AWID(t_s_awid), .S_AXI_AWADDR(t_s_awaddr), .S_AXI_AWLEN(t_s_awlen),
        .S_AXI_AWSIZE(t_s_awsize), .S_AXI_AWBURST(t_s_awburst), .S_AXI_AWLOCK(t_s_awlock),
        .S_AXI_AWCACHE(t_s_awcache), .S_AXI_AWPROT(t_s_awprot), .S_AXI_AWQOS(t_s_awqos),
        .S_AXI_AWREGION(t_s_awregion), .S_AXI_AWUSER(t_s_awuser),
        .S_AXI_AWVALID(t_s_awvalid), .S_AXI_AWREADY(d_s_awready),
        .S_AXI_WDATA(t_s_wdata), .S_AXI_WSTRB(t_s_wstrb), .S_AXI_WLAST(t_s_wlast),
        .S_AXI_WUSER(t_s_wuser), .S_AXI_WVALID(t_s_wvalid), .S_AXI_WREADY(d_s_wready),
        .S_AXI_BID(d_s_bid), .S_AXI_BRESP(d_s_bresp), .S_AXI_BVALID(d_s_bvalid),
        .S_AXI_BREADY(t_s_bready),
        .S_AXI_ARID(t_s_arid), .S_AXI_ARADDR(t_s_araddr), .S_AXI_ARLEN(t_s_arlen),
        .S_AXI_ARSIZE(t_s_arsize), .S_AXI_ARBURST(t_s_arburst), .S_AXI_ARLOCK(t_s_arlock),
        .S_AXI_ARCACHE(t_s_arcache), .S_AXI_ARPROT(t_s_arprot), .S_AXI_ARQOS(t_s_arqos),
        .S_AXI_ARREGION(t_s_arregion), .S_AXI_ARUSER(t_s_aruser),
        .S_AXI_ARVALID(t_s_arvalid), .S_AXI_ARREADY(d_s_arready),
        .S_AXI_RID(d_s_rid), .S_AXI_RDATA(d_s_rdata), .S_AXI_RRESP(d_s_rresp),
        .S_AXI_RLAST(d_s_rlast), .S_AXI_RVALID(d_s_rvalid), .S_AXI_RREADY(t_s_rready),

        .M_AXI_AWID(d_m_awid), .M_AXI_AWADDR(d_m_awaddr), .M_AXI_AWLEN(d_m_awlen),
        .M_AXI_AWSIZE(d_m_awsize), .M_AXI_AWBURST(d_m_awburst), .M_AXI_AWLOCK(d_m_awlock),
        .M_AXI_AWCACHE(d_m_awcache), .M_AXI_AWPROT(d_m_awprot), .M_AXI_AWQOS(d_m_awqos),
        .M_AXI_AWREGION(d_m_awregion), .M_AXI_AWUSER(d_m_awuser),
        .M_AXI_AWVALID(d_m_awvalid), .M_AXI_AWREADY(t_m_awready),
        .M_AXI_WDATA(d_m_wdata), .M_AXI_WSTRB(d_m_wstrb), .M_AXI_WLAST(d_m_wlast),
        .M_AXI_WUSER(d_m_wuser), .M_AXI_WVALID(d_m_wvalid), .M_AXI_WREADY(t_m_wready),
        .M_AXI_BID(t_m_bid), .M_AXI_BRESP(t_m_bresp), .M_AXI_BVALID(t_m_bvalid),
        .M_AXI_BREADY(d_m_bready),
        .M_AXI_ARID(d_m_arid), .M_AXI_ARADDR(d_m_araddr), .M_AXI_ARLEN(d_m_arlen),
        .M_AXI_ARSIZE(d_m_arsize), .M_AXI_ARBURST(d_m_arburst), .M_AXI_ARLOCK(d_m_arlock),
        .M_AXI_ARCACHE(d_m_arcache), .M_AXI_ARPROT(d_m_arprot), .M_AXI_ARQOS(d_m_arqos),
        .M_AXI_ARREGION(d_m_arregion), .M_AXI_ARUSER(d_m_aruser),
        .M_AXI_ARVALID(d_m_arvalid), .M_AXI_ARREADY(t_m_arready),
        .M_AXI_RID(t_m_rid), .M_AXI_RDATA(t_m_rdata), .M_AXI_RRESP(t_m_rresp),
        .M_AXI_RLAST(t_m_rlast), .M_AXI_RVALID(t_m_rvalid), .M_AXI_RREADY(d_m_rready)
    );

    // ================================================================ scoreboards ==========
    reg [LP_AW-1:0] awq [0:QDEPTH-1];
    reg [LP_W-1:0]  wq  [0:QDEPTH-1];
    reg [LP_B-1:0]  bq  [0:QDEPTH-1];
    reg [LP_AR-1:0] arq [0:QDEPTH-1];
    reg [LP_R-1:0]  rq  [0:QDEPTH-1];

    integer aw_wr, aw_rd, aw_sent, aw_recv, aw_errors, aw_target;
    integer w_wr,  w_rd,  w_sent,  w_recv,  w_errors,  w_target;
    integer b_wr,  b_rd,  b_sent,  b_recv,  b_errors,  b_target;
    integer ar_wr, ar_rd, ar_sent, ar_recv, ar_errors, ar_target;
    integer r_wr,  r_rd,  r_sent,  r_recv,  r_errors,  r_target;

    reg aw_active, w_active, b_active, ar_active, r_active;
    reg aw_bp_en,  w_bp_en,  b_bp_en,  ar_bp_en,  r_bp_en;
    reg aw_scripted, b_scripted, ar_scripted, r_scripted;

    reg [LP_AW-1:0] aw_hold_data; reg aw_hold_active;
    reg [LP_W-1:0]  w_hold_data;  reg w_hold_active;
    reg [LP_B-1:0]  b_hold_data;  reg b_hold_active;
    reg [LP_AR-1:0] ar_hold_data; reg ar_hold_active;
    reg [LP_R-1:0]  r_hold_data;  reg r_hold_active;

    integer aw_first_push_cyc, aw_first_pop_cyc;

    // scripted (deterministic) beat tables -- see header: proves order+content preservation
    // under a hand-chosen, non-monotonic, repeated-ID sequence, on top of the exhaustive random
    // coverage in the bb/bp subphases.
    reg [ID_W-1:0]   aw_scr_id   [0:3]; reg [ADDR_W-1:0] aw_scr_addr [0:3];
    reg [ID_W-1:0]   ar_scr_id   [0:3]; reg [ADDR_W-1:0] ar_scr_addr [0:3];
    reg [ID_W-1:0]   b_scr_id    [0:3]; reg [1:0]        b_scr_resp  [0:3];
    reg [ID_W-1:0]   r_scr_id    [0:3]; reg [DATA_W-1:0] r_scr_data  [0:3];

    reg [31:0] awd_seed, awrp_seed, wd_seed, wrp_seed, bd_seed, brp_seed,
               ard_seed, arrp_seed, rd_seed, rrp_seed;
    reg [31:0] aw_r1, aw_r2, w_r1, w_r2, w_r3, b_r1, ar_r1, ar_r2, r_r1, r_r2, r_r3;

    // ================================================================ AW driver =============
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            t_s_awvalid <= 1'b0; aw_wr <= 0; aw_sent <= 0;
        end else if (aw_active) begin
            if (t_s_awvalid && d_s_awready) begin
                awq[aw_wr] <= {t_s_awid, t_s_awaddr, t_s_awlen, t_s_awsize, t_s_awburst,
                               t_s_awlock, t_s_awcache, t_s_awprot, t_s_awqos, t_s_awregion,
                               t_s_awuser};
                if (aw_wr == 0) aw_first_push_cyc <= cyc_cnt;
                aw_wr <= aw_wr + 1;
                aw_sent <= aw_sent + 1;
                if (aw_sent + 1 < aw_target) begin
                    if (aw_scripted) begin
                        t_s_awid <= aw_scr_id[aw_sent+1]; t_s_awaddr <= aw_scr_addr[aw_sent+1];
                        t_s_awlen <= 8'd0; t_s_awsize <= 3'd3; t_s_awburst <= 2'b01;
                        t_s_awlock <= 2'b0; t_s_awcache <= 4'b0; t_s_awprot <= 3'b0;
                        t_s_awqos <= 4'b0; t_s_awregion <= 4'b0; t_s_awuser <= 1'b0;
                    end else begin
                        aw_r1 = $random(awd_seed); aw_r2 = $random(awd_seed);
                        t_s_awid <= aw_r1[ID_W-1:0]; t_s_awaddr <= aw_r2;
                        t_s_awlen <= aw_r1[15:8]; t_s_awsize <= aw_r1[18:16];
                        t_s_awburst <= aw_r1[20:19]; t_s_awlock <= aw_r1[22:21];
                        t_s_awcache <= aw_r1[26:23]; t_s_awprot <= aw_r1[29:27];
                        t_s_awqos <= ~aw_r1[3:0]; t_s_awregion <= ~aw_r1[7:4];
                        t_s_awuser <= aw_r1[31];
                    end
                    t_s_awvalid <= 1'b1;
                end else begin
                    t_s_awvalid <= 1'b0;
                end
            end else if (!t_s_awvalid && aw_sent < aw_target) begin
                if (aw_scripted) begin
                    t_s_awid <= aw_scr_id[0]; t_s_awaddr <= aw_scr_addr[0];
                    t_s_awlen <= 8'd0; t_s_awsize <= 3'd3; t_s_awburst <= 2'b01;
                    t_s_awlock <= 2'b0; t_s_awcache <= 4'b0; t_s_awprot <= 3'b0;
                    t_s_awqos <= 4'b0; t_s_awregion <= 4'b0; t_s_awuser <= 1'b0;
                end else begin
                    aw_r1 = $random(awd_seed); aw_r2 = $random(awd_seed);
                    t_s_awid <= aw_r1[ID_W-1:0]; t_s_awaddr <= aw_r2;
                    t_s_awlen <= aw_r1[15:8]; t_s_awsize <= aw_r1[18:16];
                    t_s_awburst <= aw_r1[20:19]; t_s_awlock <= aw_r1[22:21];
                    t_s_awcache <= aw_r1[26:23]; t_s_awprot <= aw_r1[29:27];
                    t_s_awqos <= ~aw_r1[3:0]; t_s_awregion <= ~aw_r1[7:4];
                    t_s_awuser <= aw_r1[31];
                end
                t_s_awvalid <= 1'b1;
            end
        end else begin
            t_s_awvalid <= 1'b0;
        end
    end

    // ================================================================ AW monitor ============
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            aw_rd <= 0; aw_recv <= 0; aw_errors <= 0;
            aw_hold_active <= 0; aw_hold_data <= 0;
        end else begin
            if (aw_hold_active) begin
                if (!d_m_awvalid || ({d_m_awid,d_m_awaddr,d_m_awlen,d_m_awsize,d_m_awburst,
                        d_m_awlock,d_m_awcache,d_m_awprot,d_m_awqos,d_m_awregion,d_m_awuser}
                        !== aw_hold_data)) begin
                    aw_errors <= aw_errors + 1;
                    $display("[%0t] AW HOLD-STABLE VIOLATION", $time);
                end
            end
            if (d_m_awvalid && t_m_awready) begin
                if ({d_m_awid,d_m_awaddr,d_m_awlen,d_m_awsize,d_m_awburst,d_m_awlock,d_m_awcache,
                     d_m_awprot,d_m_awqos,d_m_awregion,d_m_awuser} !== awq[aw_rd]) begin
                    aw_errors <= aw_errors + 1;
                    $display("[%0t] AW DATA MISMATCH beat %0d", $time, aw_rd);
                end
                if (aw_rd == 0) aw_first_pop_cyc <= cyc_cnt;
                aw_rd <= aw_rd + 1; aw_recv <= aw_recv + 1;
            end
            if (!aw_bp_en && aw_recv >= 1 && aw_recv < aw_target && !d_m_awvalid) begin
                aw_errors <= aw_errors + 1;
                $display("[%0t] AW BUBBLE at recv=%0d/%0d", $time, aw_recv, aw_target);
            end
            aw_hold_active <= d_m_awvalid && !t_m_awready;
            aw_hold_data <= {d_m_awid,d_m_awaddr,d_m_awlen,d_m_awsize,d_m_awburst,d_m_awlock,
                              d_m_awcache,d_m_awprot,d_m_awqos,d_m_awregion,d_m_awuser};
        end
    end

    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) t_m_awready <= 1'b1;
        else t_m_awready <= aw_bp_en ? $random(awrp_seed) : 1'b1;

    // ================================================================ W driver/monitor ======
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            t_s_wvalid <= 1'b0; w_wr <= 0; w_sent <= 0;
        end else if (w_active) begin
            if (t_s_wvalid && d_s_wready) begin
                wq[w_wr] <= {t_s_wdata, t_s_wstrb, t_s_wlast, t_s_wuser};
                w_wr <= w_wr + 1; w_sent <= w_sent + 1;
                if (w_sent + 1 < w_target) begin
                    w_r1 = $random(wd_seed); w_r2 = $random(wd_seed); w_r3 = $random(wd_seed);
                    t_s_wdata <= {w_r1, w_r2}; t_s_wstrb <= w_r3[STRB_W-1:0];
                    t_s_wlast <= w_r3[8]; t_s_wuser <= w_r3[9];
                    t_s_wvalid <= 1'b1;
                end else begin
                    t_s_wvalid <= 1'b0;
                end
            end else if (!t_s_wvalid && w_sent < w_target) begin
                w_r1 = $random(wd_seed); w_r2 = $random(wd_seed); w_r3 = $random(wd_seed);
                t_s_wdata <= {w_r1, w_r2}; t_s_wstrb <= w_r3[STRB_W-1:0];
                t_s_wlast <= w_r3[8]; t_s_wuser <= w_r3[9];
                t_s_wvalid <= 1'b1;
            end
        end else begin
            t_s_wvalid <= 1'b0;
        end
    end

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            w_rd <= 0; w_recv <= 0; w_errors <= 0; w_hold_active <= 0; w_hold_data <= 0;
        end else begin
            if (w_hold_active) begin
                if (!d_m_wvalid || ({d_m_wdata,d_m_wstrb,d_m_wlast,d_m_wuser} !== w_hold_data)) begin
                    w_errors <= w_errors + 1;
                    $display("[%0t] W HOLD-STABLE VIOLATION", $time);
                end
            end
            if (d_m_wvalid && t_m_wready) begin
                if ({d_m_wdata,d_m_wstrb,d_m_wlast,d_m_wuser} !== wq[w_rd]) begin
                    w_errors <= w_errors + 1;
                    $display("[%0t] W DATA MISMATCH beat %0d", $time, w_rd);
                end
                w_rd <= w_rd + 1; w_recv <= w_recv + 1;
            end
            if (!w_bp_en && w_recv >= 1 && w_recv < w_target && !d_m_wvalid) begin
                w_errors <= w_errors + 1;
                $display("[%0t] W BUBBLE at recv=%0d/%0d", $time, w_recv, w_target);
            end
            w_hold_active <= d_m_wvalid && !t_m_wready;
            w_hold_data <= {d_m_wdata, d_m_wstrb, d_m_wlast, d_m_wuser};
        end
    end

    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) t_m_wready <= 1'b1;
        else t_m_wready <= w_bp_en ? $random(wrp_seed) : 1'b1;

    // ================================================================ B driver (TB = M side, models a slave's response) ====
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            t_m_bvalid <= 1'b0; b_wr <= 0; b_sent <= 0;
        end else if (b_active) begin
            if (t_m_bvalid && d_m_bready) begin
                bq[b_wr] <= {t_m_bid, t_m_bresp};
                b_wr <= b_wr + 1; b_sent <= b_sent + 1;
                if (b_sent + 1 < b_target) begin
                    if (b_scripted) begin
                        t_m_bid <= b_scr_id[b_sent+1]; t_m_bresp <= b_scr_resp[b_sent+1];
                    end else begin
                        b_r1 = $random(bd_seed);
                        t_m_bid <= b_r1[ID_W-1:0]; t_m_bresp <= b_r1[5:4];
                    end
                    t_m_bvalid <= 1'b1;
                end else begin
                    t_m_bvalid <= 1'b0;
                end
            end else if (!t_m_bvalid && b_sent < b_target) begin
                if (b_scripted) begin
                    t_m_bid <= b_scr_id[0]; t_m_bresp <= b_scr_resp[0];
                end else begin
                    b_r1 = $random(bd_seed);
                    t_m_bid <= b_r1[ID_W-1:0]; t_m_bresp <= b_r1[5:4];
                end
                t_m_bvalid <= 1'b1;
            end
        end else begin
            t_m_bvalid <= 1'b0;
        end
    end

    // ================================================================ B monitor (TB reads S side) ====
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            b_rd <= 0; b_recv <= 0; b_errors <= 0; b_hold_active <= 0; b_hold_data <= 0;
        end else begin
            if (b_hold_active) begin
                if (!d_s_bvalid || ({d_s_bid,d_s_bresp} !== b_hold_data)) begin
                    b_errors <= b_errors + 1;
                    $display("[%0t] B HOLD-STABLE VIOLATION", $time);
                end
            end
            if (d_s_bvalid && t_s_bready) begin
                if ({d_s_bid,d_s_bresp} !== bq[b_rd]) begin
                    b_errors <= b_errors + 1;
                    $display("[%0t] B DATA MISMATCH beat %0d", $time, b_rd);
                end
                b_rd <= b_rd + 1; b_recv <= b_recv + 1;
            end
            if (!b_bp_en && b_recv >= 1 && b_recv < b_target && !d_s_bvalid) begin
                b_errors <= b_errors + 1;
                $display("[%0t] B BUBBLE at recv=%0d/%0d", $time, b_recv, b_target);
            end
            b_hold_active <= d_s_bvalid && !t_s_bready;
            b_hold_data <= {d_s_bid, d_s_bresp};
        end
    end

    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) t_s_bready <= 1'b1;
        else t_s_bready <= b_bp_en ? $random(brp_seed) : 1'b1;

    // ================================================================ AR driver ============
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            t_s_arvalid <= 1'b0; ar_wr <= 0; ar_sent <= 0;
        end else if (ar_active) begin
            if (t_s_arvalid && d_s_arready) begin
                arq[ar_wr] <= {t_s_arid, t_s_araddr, t_s_arlen, t_s_arsize, t_s_arburst,
                               t_s_arlock, t_s_arcache, t_s_arprot, t_s_arqos, t_s_arregion,
                               t_s_aruser};
                ar_wr <= ar_wr + 1; ar_sent <= ar_sent + 1;
                if (ar_sent + 1 < ar_target) begin
                    if (ar_scripted) begin
                        t_s_arid <= ar_scr_id[ar_sent+1]; t_s_araddr <= ar_scr_addr[ar_sent+1];
                        t_s_arlen <= 8'd0; t_s_arsize <= 3'd3; t_s_arburst <= 2'b01;
                        t_s_arlock <= 2'b0; t_s_arcache <= 4'b0; t_s_arprot <= 3'b0;
                        t_s_arqos <= 4'b0; t_s_arregion <= 4'b0; t_s_aruser <= 1'b0;
                    end else begin
                        ar_r1 = $random(ard_seed); ar_r2 = $random(ard_seed);
                        t_s_arid <= ar_r1[ID_W-1:0]; t_s_araddr <= ar_r2;
                        t_s_arlen <= ar_r1[15:8]; t_s_arsize <= ar_r1[18:16];
                        t_s_arburst <= ar_r1[20:19]; t_s_arlock <= ar_r1[22:21];
                        t_s_arcache <= ar_r1[26:23]; t_s_arprot <= ar_r1[29:27];
                        t_s_arqos <= ~ar_r1[3:0]; t_s_arregion <= ~ar_r1[7:4];
                        t_s_aruser <= ar_r1[31];
                    end
                    t_s_arvalid <= 1'b1;
                end else begin
                    t_s_arvalid <= 1'b0;
                end
            end else if (!t_s_arvalid && ar_sent < ar_target) begin
                if (ar_scripted) begin
                    t_s_arid <= ar_scr_id[0]; t_s_araddr <= ar_scr_addr[0];
                    t_s_arlen <= 8'd0; t_s_arsize <= 3'd3; t_s_arburst <= 2'b01;
                    t_s_arlock <= 2'b0; t_s_arcache <= 4'b0; t_s_arprot <= 3'b0;
                    t_s_arqos <= 4'b0; t_s_arregion <= 4'b0; t_s_aruser <= 1'b0;
                end else begin
                    ar_r1 = $random(ard_seed); ar_r2 = $random(ard_seed);
                    t_s_arid <= ar_r1[ID_W-1:0]; t_s_araddr <= ar_r2;
                    t_s_arlen <= ar_r1[15:8]; t_s_arsize <= ar_r1[18:16];
                    t_s_arburst <= ar_r1[20:19]; t_s_arlock <= ar_r1[22:21];
                    t_s_arcache <= ar_r1[26:23]; t_s_arprot <= ar_r1[29:27];
                    t_s_arqos <= ~ar_r1[3:0]; t_s_arregion <= ~ar_r1[7:4];
                    t_s_aruser <= ar_r1[31];
                end
                t_s_arvalid <= 1'b1;
            end
        end else begin
            t_s_arvalid <= 1'b0;
        end
    end

    // ================================================================ AR monitor ============
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            ar_rd <= 0; ar_recv <= 0; ar_errors <= 0; ar_hold_active <= 0; ar_hold_data <= 0;
        end else begin
            if (ar_hold_active) begin
                if (!d_m_arvalid || ({d_m_arid,d_m_araddr,d_m_arlen,d_m_arsize,d_m_arburst,
                        d_m_arlock,d_m_arcache,d_m_arprot,d_m_arqos,d_m_arregion,d_m_aruser}
                        !== ar_hold_data)) begin
                    ar_errors <= ar_errors + 1;
                    $display("[%0t] AR HOLD-STABLE VIOLATION", $time);
                end
            end
            if (d_m_arvalid && t_m_arready) begin
                if ({d_m_arid,d_m_araddr,d_m_arlen,d_m_arsize,d_m_arburst,d_m_arlock,d_m_arcache,
                     d_m_arprot,d_m_arqos,d_m_arregion,d_m_aruser} !== arq[ar_rd]) begin
                    ar_errors <= ar_errors + 1;
                    $display("[%0t] AR DATA MISMATCH beat %0d", $time, ar_rd);
                end
                ar_rd <= ar_rd + 1; ar_recv <= ar_recv + 1;
            end
            if (!ar_bp_en && ar_recv >= 1 && ar_recv < ar_target && !d_m_arvalid) begin
                ar_errors <= ar_errors + 1;
                $display("[%0t] AR BUBBLE at recv=%0d/%0d", $time, ar_recv, ar_target);
            end
            ar_hold_active <= d_m_arvalid && !t_m_arready;
            ar_hold_data <= {d_m_arid,d_m_araddr,d_m_arlen,d_m_arsize,d_m_arburst,d_m_arlock,
                              d_m_arcache,d_m_arprot,d_m_arqos,d_m_arregion,d_m_aruser};
        end
    end

    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) t_m_arready <= 1'b1;
        else t_m_arready <= ar_bp_en ? $random(arrp_seed) : 1'b1;

    // ================================================================ R driver (TB = M side) ====
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            t_m_rvalid <= 1'b0; r_wr <= 0; r_sent <= 0;
        end else if (r_active) begin
            if (t_m_rvalid && d_m_rready) begin
                rq[r_wr] <= {t_m_rid, t_m_rdata, t_m_rresp, t_m_rlast};
                r_wr <= r_wr + 1; r_sent <= r_sent + 1;
                if (r_sent + 1 < r_target) begin
                    if (r_scripted) begin
                        t_m_rid <= r_scr_id[r_sent+1]; t_m_rdata <= r_scr_data[r_sent+1];
                        t_m_rresp <= 2'b00; t_m_rlast <= 1'b1;
                    end else begin
                        r_r1 = $random(rd_seed); r_r2 = $random(rd_seed); r_r3 = $random(rd_seed);
                        t_m_rid <= r_r1[ID_W-1:0]; t_m_rdata <= {r_r2, r_r3};
                        t_m_rresp <= r_r1[5:4]; t_m_rlast <= r_r1[6];
                    end
                    t_m_rvalid <= 1'b1;
                end else begin
                    t_m_rvalid <= 1'b0;
                end
            end else if (!t_m_rvalid && r_sent < r_target) begin
                if (r_scripted) begin
                    t_m_rid <= r_scr_id[0]; t_m_rdata <= r_scr_data[0];
                    t_m_rresp <= 2'b00; t_m_rlast <= 1'b1;
                end else begin
                    r_r1 = $random(rd_seed); r_r2 = $random(rd_seed); r_r3 = $random(rd_seed);
                    t_m_rid <= r_r1[ID_W-1:0]; t_m_rdata <= {r_r2, r_r3};
                    t_m_rresp <= r_r1[5:4]; t_m_rlast <= r_r1[6];
                end
                t_m_rvalid <= 1'b1;
            end
        end else begin
            t_m_rvalid <= 1'b0;
        end
    end

    // ================================================================ R monitor ============
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            r_rd <= 0; r_recv <= 0; r_errors <= 0; r_hold_active <= 0; r_hold_data <= 0;
        end else begin
            if (r_hold_active) begin
                if (!d_s_rvalid || ({d_s_rid,d_s_rdata,d_s_rresp,d_s_rlast} !== r_hold_data)) begin
                    r_errors <= r_errors + 1;
                    $display("[%0t] R HOLD-STABLE VIOLATION", $time);
                end
            end
            if (d_s_rvalid && t_s_rready) begin
                if ({d_s_rid,d_s_rdata,d_s_rresp,d_s_rlast} !== rq[r_rd]) begin
                    r_errors <= r_errors + 1;
                    $display("[%0t] R DATA MISMATCH beat %0d", $time, r_rd);
                end
                r_rd <= r_rd + 1; r_recv <= r_recv + 1;
            end
            if (!r_bp_en && r_recv >= 1 && r_recv < r_target && !d_s_rvalid) begin
                r_errors <= r_errors + 1;
                $display("[%0t] R BUBBLE at recv=%0d/%0d", $time, r_recv, r_target);
            end
            r_hold_active <= d_s_rvalid && !t_s_rready;
            r_hold_data <= {d_s_rid, d_s_rdata, d_s_rresp, d_s_rlast};
        end
    end

    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) t_s_rready <= 1'b1;
        else t_s_rready <= r_bp_en ? $random(rrp_seed) : 1'b1;

    // ================================================================ DUT #2 (DEPTH=3) -- AW channel only, proves DEPTH is a real parameter ====
    reg  [ID_W-1:0]   t2_s_awid;   reg [ADDR_W-1:0] t2_s_awaddr; reg [7:0] t2_s_awlen;
    reg  [2:0]        t2_s_awsize; reg [1:0] t2_s_awburst; reg [1:0] t2_s_awlock;
    reg  [3:0]        t2_s_awcache; reg [2:0] t2_s_awprot; reg [3:0] t2_s_awqos;
    reg  [3:0]        t2_s_awregion; reg t2_s_awuser; reg t2_s_awvalid;
    wire               d2_s_awready;
    wire [ID_W-1:0]   d2_m_awid;   wire [ADDR_W-1:0] d2_m_awaddr; wire [7:0] d2_m_awlen;
    wire [2:0]        d2_m_awsize; wire [1:0] d2_m_awburst; wire [1:0] d2_m_awlock;
    wire [3:0]        d2_m_awcache; wire [2:0] d2_m_awprot; wire [3:0] d2_m_awqos;
    wire [3:0]        d2_m_awregion; wire d2_m_awuser; wire d2_m_awvalid;
    reg                t2_m_awready;

    axi4_regslice #(.ID_WIDTH(ID_W), .ADDR_WIDTH(ADDR_W), .DATA_WIDTH(DATA_W), .DEPTH(3)) dut2 (
        .ACLK(ACLK), .ARESETN(ARESETN),
        .S_AXI_AWID(t2_s_awid), .S_AXI_AWADDR(t2_s_awaddr), .S_AXI_AWLEN(t2_s_awlen),
        .S_AXI_AWSIZE(t2_s_awsize), .S_AXI_AWBURST(t2_s_awburst), .S_AXI_AWLOCK(t2_s_awlock),
        .S_AXI_AWCACHE(t2_s_awcache), .S_AXI_AWPROT(t2_s_awprot), .S_AXI_AWQOS(t2_s_awqos),
        .S_AXI_AWREGION(t2_s_awregion), .S_AXI_AWUSER(t2_s_awuser),
        .S_AXI_AWVALID(t2_s_awvalid), .S_AXI_AWREADY(d2_s_awready),
        .S_AXI_WDATA({DATA_W{1'b0}}), .S_AXI_WSTRB({STRB_W{1'b0}}), .S_AXI_WLAST(1'b0),
        .S_AXI_WUSER(1'b0), .S_AXI_WVALID(1'b0), .S_AXI_WREADY(),
        .S_AXI_BID(), .S_AXI_BRESP(), .S_AXI_BVALID(), .S_AXI_BREADY(1'b1),
        .S_AXI_ARID({ID_W{1'b0}}), .S_AXI_ARADDR({ADDR_W{1'b0}}), .S_AXI_ARLEN(8'd0),
        .S_AXI_ARSIZE(3'd0), .S_AXI_ARBURST(2'd0), .S_AXI_ARLOCK(2'd0),
        .S_AXI_ARCACHE(4'd0), .S_AXI_ARPROT(3'd0), .S_AXI_ARQOS(4'd0),
        .S_AXI_ARREGION(4'd0), .S_AXI_ARUSER(1'b0),
        .S_AXI_ARVALID(1'b0), .S_AXI_ARREADY(),
        .S_AXI_RID(), .S_AXI_RDATA(), .S_AXI_RRESP(),
        .S_AXI_RLAST(), .S_AXI_RVALID(), .S_AXI_RREADY(1'b1),

        .M_AXI_AWID(d2_m_awid), .M_AXI_AWADDR(d2_m_awaddr), .M_AXI_AWLEN(d2_m_awlen),
        .M_AXI_AWSIZE(d2_m_awsize), .M_AXI_AWBURST(d2_m_awburst), .M_AXI_AWLOCK(d2_m_awlock),
        .M_AXI_AWCACHE(d2_m_awcache), .M_AXI_AWPROT(d2_m_awprot), .M_AXI_AWQOS(d2_m_awqos),
        .M_AXI_AWREGION(d2_m_awregion), .M_AXI_AWUSER(d2_m_awuser),
        .M_AXI_AWVALID(d2_m_awvalid), .M_AXI_AWREADY(t2_m_awready),
        .M_AXI_WDATA(), .M_AXI_WSTRB(), .M_AXI_WLAST(), .M_AXI_WUSER(),
        .M_AXI_WVALID(), .M_AXI_WREADY(1'b1),
        .M_AXI_BID({ID_W{1'b0}}), .M_AXI_BRESP(2'd0), .M_AXI_BVALID(1'b0), .M_AXI_BREADY(),
        .M_AXI_ARID(), .M_AXI_ARADDR(), .M_AXI_ARLEN(), .M_AXI_ARSIZE(), .M_AXI_ARBURST(),
        .M_AXI_ARLOCK(), .M_AXI_ARCACHE(), .M_AXI_ARPROT(), .M_AXI_ARQOS(), .M_AXI_ARREGION(),
        .M_AXI_ARUSER(), .M_AXI_ARVALID(), .M_AXI_ARREADY(1'b1),
        .M_AXI_RID({ID_W{1'b0}}), .M_AXI_RDATA({DATA_W{1'b0}}), .M_AXI_RRESP(2'd0),
        .M_AXI_RLAST(1'b0), .M_AXI_RVALID(1'b0), .M_AXI_RREADY()
    );

    reg [LP_AW-1:0] awq2 [0:QDEPTH-1];
    integer aw2_wr, aw2_rd, aw2_sent, aw2_recv, aw2_errors, aw2_target;
    reg aw2_active;
    reg [LP_AW-1:0] aw2_hold_data; reg aw2_hold_active;
    reg [31:0] aw2d_seed, aw2_r1, aw2_r2;
    integer aw2_first_push_cyc, aw2_first_pop_cyc;

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            t2_s_awvalid <= 1'b0; aw2_wr <= 0; aw2_sent <= 0;
        end else if (aw2_active) begin
            if (t2_s_awvalid && d2_s_awready) begin
                awq2[aw2_wr] <= {t2_s_awid, t2_s_awaddr, t2_s_awlen, t2_s_awsize, t2_s_awburst,
                                  t2_s_awlock, t2_s_awcache, t2_s_awprot, t2_s_awqos,
                                  t2_s_awregion, t2_s_awuser};
                if (aw2_wr == 0) aw2_first_push_cyc <= cyc_cnt;
                aw2_wr <= aw2_wr + 1; aw2_sent <= aw2_sent + 1;
                if (aw2_sent + 1 < aw2_target) begin
                    aw2_r1 = $random(aw2d_seed); aw2_r2 = $random(aw2d_seed);
                    t2_s_awid <= aw2_r1[ID_W-1:0]; t2_s_awaddr <= aw2_r2;
                    t2_s_awlen <= aw2_r1[15:8]; t2_s_awsize <= aw2_r1[18:16];
                    t2_s_awburst <= aw2_r1[20:19]; t2_s_awlock <= aw2_r1[22:21];
                    t2_s_awcache <= aw2_r1[26:23]; t2_s_awprot <= aw2_r1[29:27];
                    t2_s_awqos <= ~aw2_r1[3:0]; t2_s_awregion <= ~aw2_r1[7:4];
                    t2_s_awuser <= aw2_r1[31];
                    t2_s_awvalid <= 1'b1;
                end else begin
                    t2_s_awvalid <= 1'b0;
                end
            end else if (!t2_s_awvalid && aw2_sent < aw2_target) begin
                aw2_r1 = $random(aw2d_seed); aw2_r2 = $random(aw2d_seed);
                t2_s_awid <= aw2_r1[ID_W-1:0]; t2_s_awaddr <= aw2_r2;
                t2_s_awlen <= aw2_r1[15:8]; t2_s_awsize <= aw2_r1[18:16];
                t2_s_awburst <= aw2_r1[20:19]; t2_s_awlock <= aw2_r1[22:21];
                t2_s_awcache <= aw2_r1[26:23]; t2_s_awprot <= aw2_r1[29:27];
                t2_s_awqos <= ~aw2_r1[3:0]; t2_s_awregion <= ~aw2_r1[7:4];
                t2_s_awuser <= aw2_r1[31];
                t2_s_awvalid <= 1'b1;
            end
        end else begin
            t2_s_awvalid <= 1'b0;
        end
    end

    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            aw2_rd <= 0; aw2_recv <= 0; aw2_errors <= 0;
            aw2_hold_active <= 0; aw2_hold_data <= 0;
        end else begin
            if (aw2_hold_active) begin
                if (!d2_m_awvalid || ({d2_m_awid,d2_m_awaddr,d2_m_awlen,d2_m_awsize,d2_m_awburst,
                        d2_m_awlock,d2_m_awcache,d2_m_awprot,d2_m_awqos,d2_m_awregion,
                        d2_m_awuser} !== aw2_hold_data)) begin
                    aw2_errors <= aw2_errors + 1;
                    $display("[%0t] DUT2(DEPTH=3) AW HOLD-STABLE VIOLATION", $time);
                end
            end
            if (d2_m_awvalid && t2_m_awready) begin
                if ({d2_m_awid,d2_m_awaddr,d2_m_awlen,d2_m_awsize,d2_m_awburst,d2_m_awlock,
                     d2_m_awcache,d2_m_awprot,d2_m_awqos,d2_m_awregion,d2_m_awuser}
                     !== awq2[aw2_rd]) begin
                    aw2_errors <= aw2_errors + 1;
                    $display("[%0t] DUT2(DEPTH=3) AW DATA MISMATCH beat %0d", $time, aw2_rd);
                end
                if (aw2_rd == 0) aw2_first_pop_cyc <= cyc_cnt;
                aw2_rd <= aw2_rd + 1; aw2_recv <= aw2_recv + 1;
            end
            if (aw2_recv >= 1 && aw2_recv < aw2_target && !d2_m_awvalid) begin
                aw2_errors <= aw2_errors + 1;
                $display("[%0t] DUT2(DEPTH=3) AW BUBBLE at recv=%0d/%0d", $time, aw2_recv, aw2_target);
            end
            aw2_hold_active <= d2_m_awvalid && !t2_m_awready;
            aw2_hold_data <= {d2_m_awid,d2_m_awaddr,d2_m_awlen,d2_m_awsize,d2_m_awburst,
                               d2_m_awlock,d2_m_awcache,d2_m_awprot,d2_m_awqos,d2_m_awregion,
                               d2_m_awuser};
        end
    end

    always @(posedge ACLK or negedge ARESETN)
        if (!ARESETN) t2_m_awready <= 1'b1; else t2_m_awready <= 1'b1;   // back-to-back only

    // ================================================================ sequencer =============
    integer aw_snap, w_snap, b_snap, ar_snap, r_snap;

    initial begin
        if (!$value$plusargs("seed=%d", rseed)) rseed = 32'h1234_5678 ^ $time;
        $display("SEED=%0d (rerun with +seed=%0d to reproduce)", rseed, rseed);
        awd_seed  = rseed ^ 32'h1111_1111; awrp_seed = rseed ^ 32'h2222_2222;
        wd_seed   = rseed ^ 32'h3333_3333; wrp_seed  = rseed ^ 32'h4444_4444;
        bd_seed   = rseed ^ 32'h5555_5555; brp_seed  = rseed ^ 32'h6666_6666;
        ard_seed  = rseed ^ 32'h7777_7777; arrp_seed = rseed ^ 32'h8888_8888;
        rd_seed   = rseed ^ 32'h9999_9999; rrp_seed  = rseed ^ 32'hAAAA_AAAA;
        aw2d_seed = rseed ^ 32'hBBBB_BBBB;

        // scripted tables: non-monotonic IDs, ID 3 repeated, responses NOT in issue order.
        aw_scr_id[0]=4'd3; aw_scr_id[1]=4'd6; aw_scr_id[2]=4'd3; aw_scr_id[3]=4'd9;
        aw_scr_addr[0]=32'h1000_0000; aw_scr_addr[1]=32'h2000_0000;
        aw_scr_addr[2]=32'h3000_0000; aw_scr_addr[3]=32'h4000_0000;
        b_scr_id[0]=4'd6; b_scr_id[1]=4'd3; b_scr_id[2]=4'd9; b_scr_id[3]=4'd3;
        b_scr_resp[0]=2'b00; b_scr_resp[1]=2'b01; b_scr_resp[2]=2'b10; b_scr_resp[3]=2'b00;

        ar_scr_id[0]=4'd3; ar_scr_id[1]=4'd6; ar_scr_id[2]=4'd3; ar_scr_id[3]=4'd9;
        ar_scr_addr[0]=32'h5000_0000; ar_scr_addr[1]=32'h6000_0000;
        ar_scr_addr[2]=32'h7000_0000; ar_scr_addr[3]=32'h8000_0000;
        r_scr_id[0]=4'd6; r_scr_id[1]=4'd3; r_scr_id[2]=4'd9; r_scr_id[3]=4'd3;
        r_scr_data[0]=64'hAAAA_AAAA_0000_0006; r_scr_data[1]=64'hBBBB_BBBB_0000_0003;
        r_scr_data[2]=64'hCCCC_CCCC_0000_0009; r_scr_data[3]=64'hDDDD_DDDD_0000_0003;

        aw_active=0; w_active=0; b_active=0; ar_active=0; r_active=0; aw2_active=0;
        aw_bp_en=0; w_bp_en=0; b_bp_en=0; ar_bp_en=0; r_bp_en=0;
        aw_scripted=0; b_scripted=0; ar_scripted=0; r_scripted=0;
        aw_target=0; w_target=0; b_target=0; ar_target=0; r_target=0; aw2_target=0;
        aw_first_push_cyc=-1; aw_first_pop_cyc=-1; aw2_first_push_cyc=-1; aw2_first_pop_cyc=-1;

        repeat (6) @(posedge ACLK);
        ARESETN = 1;
        repeat (4) @(posedge ACLK);

        // -------------------------------------------------- AW: bb, then random backpressure --
        aw_wr=0; aw_rd=0; aw_sent=0; aw_recv=0; aw_target=N_BB; aw_bp_en=0; aw_scripted=0;
        aw_snap = aw_errors; aw_active=1;
        wait (aw_recv >= aw_target);
        aw_active=0; repeat(4) @(posedge ACLK);
        if (aw_first_pop_cyc - aw_first_push_cyc != 1) begin
            aw_errors = aw_errors + 1;
            $display("AW LATENCY CHECK FAIL: got %0d cyc, want 1 (DEPTH=1)",
                      aw_first_pop_cyc - aw_first_push_cyc);
        end
        $display("AW back-to-back : sent=%0d recv=%0d errors=%0d", aw_sent, aw_recv, aw_errors-aw_snap);

        aw_wr=0; aw_rd=0; aw_sent=0; aw_recv=0; aw_target=N_BP; aw_bp_en=1;
        aw_snap = aw_errors; aw_active=1;
        wait (aw_recv >= aw_target);
        aw_active=0; repeat(4) @(posedge ACLK);
        $display("AW backpressure : sent=%0d recv=%0d errors=%0d", aw_sent, aw_recv, aw_errors-aw_snap);

        // -------------------------------------------------- W: bb, then random backpressure ---
        w_wr=0; w_rd=0; w_sent=0; w_recv=0; w_target=N_BB; w_bp_en=0;
        w_snap = w_errors; w_active=1;
        wait (w_recv >= w_target);
        w_active=0; repeat(4) @(posedge ACLK);
        $display("W  back-to-back : sent=%0d recv=%0d errors=%0d", w_sent, w_recv, w_errors-w_snap);

        w_wr=0; w_rd=0; w_sent=0; w_recv=0; w_target=N_BP; w_bp_en=1;
        w_snap = w_errors; w_active=1;
        wait (w_recv >= w_target);
        w_active=0; repeat(4) @(posedge ACLK);
        $display("W  backpressure : sent=%0d recv=%0d errors=%0d", w_sent, w_recv, w_errors-w_snap);

        // -------------------------------------------------- B: bb, then random backpressure ---
        b_wr=0; b_rd=0; b_sent=0; b_recv=0; b_target=N_BB; b_bp_en=0; b_scripted=0;
        b_snap = b_errors; b_active=1;
        wait (b_recv >= b_target);
        b_active=0; repeat(4) @(posedge ACLK);
        $display("B  back-to-back : sent=%0d recv=%0d errors=%0d", b_sent, b_recv, b_errors-b_snap);

        b_wr=0; b_rd=0; b_sent=0; b_recv=0; b_target=N_BP; b_bp_en=1;
        b_snap = b_errors; b_active=1;
        wait (b_recv >= b_target);
        b_active=0; repeat(4) @(posedge ACLK);
        $display("B  backpressure : sent=%0d recv=%0d errors=%0d", b_sent, b_recv, b_errors-b_snap);

        // -------------------------------------------------- AR: bb, then random backpressure --
        ar_wr=0; ar_rd=0; ar_sent=0; ar_recv=0; ar_target=N_BB; ar_bp_en=0; ar_scripted=0;
        ar_snap = ar_errors; ar_active=1;
        wait (ar_recv >= ar_target);
        ar_active=0; repeat(4) @(posedge ACLK);
        $display("AR back-to-back : sent=%0d recv=%0d errors=%0d", ar_sent, ar_recv, ar_errors-ar_snap);

        ar_wr=0; ar_rd=0; ar_sent=0; ar_recv=0; ar_target=N_BP; ar_bp_en=1;
        ar_snap = ar_errors; ar_active=1;
        wait (ar_recv >= ar_target);
        ar_active=0; repeat(4) @(posedge ACLK);
        $display("AR backpressure : sent=%0d recv=%0d errors=%0d", ar_sent, ar_recv, ar_errors-ar_snap);

        // -------------------------------------------------- R: bb, then random backpressure ---
        r_wr=0; r_rd=0; r_sent=0; r_recv=0; r_target=N_BB; r_bp_en=0; r_scripted=0;
        r_snap = r_errors; r_active=1;
        wait (r_recv >= r_target);
        r_active=0; repeat(4) @(posedge ACLK);
        $display("R  back-to-back : sent=%0d recv=%0d errors=%0d", r_sent, r_recv, r_errors-r_snap);

        r_wr=0; r_rd=0; r_sent=0; r_recv=0; r_target=N_BP; r_bp_en=1;
        r_snap = r_errors; r_active=1;
        wait (r_recv >= r_target);
        r_active=0; repeat(4) @(posedge ACLK);
        $display("R  backpressure : sent=%0d recv=%0d errors=%0d", r_sent, r_recv, r_errors-r_snap);

        // -------------------------------------------------- scripted multi-ID, out-of-order --
        aw_wr=0; aw_rd=0; aw_sent=0; aw_recv=0; aw_target=4; aw_bp_en=0; aw_scripted=1;
        aw_snap = aw_errors; aw_active=1;
        wait (aw_recv >= aw_target);
        aw_active=0; aw_scripted=0; repeat(4) @(posedge ACLK);
        $display("AW scripted (IDs 3,6,3,9)            : errors=%0d", aw_errors-aw_snap);

        b_wr=0; b_rd=0; b_sent=0; b_recv=0; b_target=4; b_bp_en=0; b_scripted=1;
        b_snap = b_errors; b_active=1;
        wait (b_recv >= b_target);
        b_active=0; b_scripted=0; repeat(4) @(posedge ACLK);
        $display("B  scripted (responses IDs 6,3,9,3)  : errors=%0d", b_errors-b_snap);

        ar_wr=0; ar_rd=0; ar_sent=0; ar_recv=0; ar_target=4; ar_bp_en=0; ar_scripted=1;
        ar_snap = ar_errors; ar_active=1;
        wait (ar_recv >= ar_target);
        ar_active=0; ar_scripted=0; repeat(4) @(posedge ACLK);
        $display("AR scripted (IDs 3,6,3,9)             : errors=%0d", ar_errors-ar_snap);

        r_wr=0; r_rd=0; r_sent=0; r_recv=0; r_target=4; r_bp_en=0; r_scripted=1;
        r_snap = r_errors; r_active=1;
        wait (r_recv >= r_target);
        r_active=0; r_scripted=0; repeat(4) @(posedge ACLK);
        $display("R  scripted (responses IDs 6,3,9,3)  : errors=%0d", r_errors-r_snap);

        // -------------------------------------------------- DEPTH=3 sanity (dut2, AW only) ----
        aw2_wr=0; aw2_rd=0; aw2_sent=0; aw2_recv=0; aw2_target=N_DEEP; aw2_active=1;
        wait (aw2_recv >= aw2_target);
        aw2_active=0; repeat(6) @(posedge ACLK);
        if (aw2_first_pop_cyc - aw2_first_push_cyc != 3) begin
            aw2_errors = aw2_errors + 1;
            $display("DUT2 LATENCY CHECK FAIL: got %0d cyc, want 3 (DEPTH=3)",
                      aw2_first_pop_cyc - aw2_first_push_cyc);
        end
        $display("DUT2(DEPTH=3) AW back-to-back        : sent=%0d recv=%0d errors=%0d",
                  aw2_sent, aw2_recv, aw2_errors);

        total_errors = aw_errors + w_errors + b_errors + ar_errors + r_errors + aw2_errors;
        $display("\n==== AXI4 REGSLICE: %s (%0d errors) ====",
                  total_errors ? "FAIL" : "PASS", total_errors);
        if (total_errors) $fatal(1, "axi4_regslice TB failed");
        $finish;
    end

    initial begin
        #20_000_000;
        $display("==== AXI4 REGSLICE: FAIL (timeout) ====");
        $fatal(1, "timeout");
    end

endmodule
