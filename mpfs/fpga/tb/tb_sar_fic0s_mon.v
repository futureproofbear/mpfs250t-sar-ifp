// tb_sar_fic0s_mon.v -- self-checking TB for the ARLEN histogram / busy / elapsed / max-gap
// extension to sar_fic0s_mon.v.
//
// WHY: resample's gather kernel measures ~880 us/line against a SmartHLS-correct 361 us/line
// schedule (2.44x). This monitor is what tells us whether that's short bursts (SmartHLS not
// hitting the configured max_burst_len) or long idle gaps (DDR/interconnect arbitration) --
// two counters (ARLEN histogram vs MAX_GAP) with opposite implied fixes. This TB proves the
// counters actually measure what their names say before trusting them on silicon.
//
// The DUT's mon_* inputs are pure observe-only taps (no ready/valid is DUT-driven), so this TB
// plays BOTH the AXI master (AR/R valid) and slave (AR/R ready) sides of the tapped channels.
//
// Clocking convention (race-free, used throughout): stimulus is set on the NEGEDGE, the DUT's
// synchronous logic samples it at the following POSEDGE. Every cyc() call is exactly one clock
// cycle of AR/R activity or idle, so cycle counts in this TB are exact -- no hidden gaps from
// task-call boundaries.
//
// Cases (see inline phase markers):
//   1. ARLEN histogram: boundary lengths spanning every bucket (1 / 2,4 / 5,16 / 17,64 / 65,256),
//      confirm exact per-bucket counts and no cross-bucket leakage.
//   2. MAX_GAP: four gaps of different lengths (5,20,3,12) -- confirm MAX_GAP==20 specifically,
//      not the sum (40) and not the most-recent (12).
//   3. BUSY_CYCLES + idle reconciles against ELAPSED_CYCLES, using independently-known idle and
//      busy cycle counts (not a tautology -- the TB computes both sides from what it drove).
//   4. 0x00 write clears STATUS + ALL new counters together; confirms ARADDR_LO (existing
//      0x00-0x0C semantics) is UNCHANGED by the clear, exactly as before this extension.
//   5. Saturation: hierarchically poke a bucket/BUSY/ELAPSED counter to 0xFFFF_FFFE (skips
//      clocking 4+ billion cycles) and confirm one more real RTL increment holds at
//      0xFFFF_FFFF rather than wrapping.
//
// Run:
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib work && $MS/vlog -work work tb_sar_fic0s_mon.v ../sar_fic0s_mon.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_sar_fic0s_mon
// Expected: "FIC0 MONITOR TB: PASS (0 errors)".
`timescale 1ns/1ps

module tb_sar_fic0s_mon;

    reg aclk = 0, aresetn = 0;
    always #5 aclk = ~aclk;

    // ---- mon_* stimulus (TB drives both valid and ready for the tapped AR/R channels) ----
    reg        mon_arvalid, mon_arready;
    reg [37:0] mon_araddr;
    reg [3:0]  mon_arid;
    reg [7:0]  mon_arlen;
    reg        mon_rvalid, mon_rready;
    reg [1:0]  mon_rresp;
    reg [3:0]  mon_rid;
    reg        mon_rlast;

    // ---- AXI4-Lite control/status side ----
    reg  [11:0] s_awaddr;  reg s_awvalid; wire s_awready;
    reg  [31:0] s_wdata;   reg s_wvalid;  wire s_wready;
    wire [1:0]  s_bresp;   wire s_bvalid; reg  s_bready;
    reg  [11:0] s_araddr;  reg s_arvalid; wire s_arready;
    wire [31:0] s_rdata;   wire [1:0] s_rresp; wire s_rvalid; reg s_rready;

    sar_fic0s_mon dut (
        .aclk(aclk), .aresetn(aresetn),
        .mon_arvalid(mon_arvalid), .mon_arready(mon_arready),
        .mon_araddr(mon_araddr), .mon_arid(mon_arid), .mon_arlen(mon_arlen),
        .mon_rvalid(mon_rvalid), .mon_rready(mon_rready),
        .mon_rresp(mon_rresp), .mon_rid(mon_rid), .mon_rlast(mon_rlast),
        .s_axi_awaddr(s_awaddr), .s_axi_awvalid(s_awvalid), .s_axi_awready(s_awready),
        .s_axi_wdata(s_wdata), .s_axi_wvalid(s_wvalid), .s_axi_wready(s_wready),
        .s_axi_bresp(s_bresp), .s_axi_bvalid(s_bvalid), .s_axi_bready(s_bready),
        .s_axi_araddr(s_araddr), .s_axi_arvalid(s_arvalid), .s_axi_arready(s_arready),
        .s_axi_rdata(s_rdata), .s_axi_rresp(s_rresp), .s_axi_rvalid(s_rvalid), .s_axi_rready(s_rready)
    );

    integer errors = 0;

    // one clean clock cycle of AR/R activity (or idle if all args are 0)
    task cyc(input arv, input [7:0] arlen_m1, input arr, input rv, input rr, input rl);
        begin
            @(negedge aclk);
            mon_arvalid = arv; mon_arlen = arlen_m1; mon_arready = arr;
            mon_araddr  = 38'd0; mon_arid = 4'd0;
            mon_rvalid  = rv;  mon_rready = rr; mon_rlast = rl;
            mon_rresp   = 2'd0; mon_rid = 4'd0;
            @(posedge aclk);
        end
    endtask

    task idle_n(input integer n);
        integer i;
        begin
            for (i = 0; i < n; i = i + 1) cyc(0,8'd0,0, 0,0,0);
        end
    endtask

    // one AR handshake requesting `beats` beats (ARLEN = beats-1). Deasserts immediately after
    // its own cyc() (no extra clock edge -- same sim time) so a caller that goes straight into
    // an axi_read/axi_write does not leave mon_arvalid held high across it (cyc() sets regs
    // with blocking assignment and nothing after the last cyc() call would otherwise lower them).
    task ar_issue(input integer beats);
        begin
            cyc(1, beats-1, 1, 0,0,0);
            mon_arvalid = 1'b0; mon_arready = 1'b0;
        end
    endtask

    // `len` back-to-back R beats, RLAST on the last one. Same deassert-on-return rationale as
    // ar_issue() above.
    task r_burst(input integer len);
        integer i;
        begin
            for (i = 0; i < len; i = i + 1)
                cyc(0,8'd0,0, 1,1, (i==len-1));
            mon_rvalid = 1'b0; mon_rready = 1'b0; mon_rlast = 1'b0;
        end
    endtask

    // ---- AXI4-Lite BFM (same negedge-stimulus / posedge-sample convention) ----
    // NOTE: the DUT asserts awready and bvalid TOGETHER for exactly one registered cycle (it
    // completes the B response in the same cycle it accepts AW/W, since bready is held high
    // throughout). So awready and bvalid must be detected in the SAME wait loop -- waiting for
    // awready, then deasserting AW/W, then starting a SEPARATE wait for bvalid one cycle later
    // finds bvalid already auto-cleared and hangs forever (caught by this TB's own watchdog).
    task axi_write(input [11:0] addr, input [31:0] data);
        begin
            @(negedge aclk);
            s_awaddr = addr; s_awvalid = 1'b1;
            s_wdata  = data; s_wvalid  = 1'b1;
            s_bready = 1'b1;
            @(posedge aclk);
            while (!s_awready) @(posedge aclk);   // awready and bvalid are valid together here
            @(negedge aclk);
            s_awvalid = 1'b0; s_wvalid = 1'b0; s_bready = 1'b0;
        end
    endtask

    task axi_read(input [11:0] addr, output [31:0] data);
        begin
            @(negedge aclk);
            s_araddr = addr; s_arvalid = 1'b1; s_rready = 1'b1;
            @(posedge aclk);
            while (!s_rvalid) @(posedge aclk);
            data = s_rdata;
            @(negedge aclk);
            s_arvalid = 1'b0; s_rready = 1'b0;
        end
    endtask

    task expect_eq(input [31:0] actual, input [31:0] expect_v, input [639:0] label);
        begin
            if (actual !== expect_v) begin
                $display("  FAIL [%0s]: got 0x%08x want 0x%08x", label, actual, expect_v);
                errors = errors + 1;
            end else begin
                $display("  ok   [%0s]: 0x%08x", label, actual);
            end
        end
    endtask

    reg [31:0] rd;
    reg [31:0] pre_alo;
    reg [31:0] base_elaps;

    // register offsets (see sar_fic0s_mon.v header for the full map)
    localparam ST=12'h00, ALO=12'h04, AHI=12'h08, IDS=12'h0C,
               H1=12'h10, H24=12'h14, H516=12'h18, H1764=12'h1C, H65256=12'h20,
               BUSY=12'h24, ELAPS=12'h28, MAXG=12'h2C;

    initial begin
        mon_arvalid=0; mon_arready=0; mon_araddr=0; mon_arid=0; mon_arlen=0;
        mon_rvalid=0; mon_rready=0; mon_rresp=0; mon_rid=0; mon_rlast=0;
        s_awaddr=0; s_awvalid=0; s_wdata=0; s_wvalid=0; s_bready=0;
        s_araddr=0; s_arvalid=0; s_rready=0;

        repeat (4) @(negedge aclk);
        aresetn = 1'b1;
        repeat (2) @(negedge aclk);

        // ================= Phase 1: ARLEN histogram, boundary lengths =================
        $display("-- Phase 1: ARLEN histogram boundaries --");
        axi_write(ST, 32'hFFFF_FFFF);          // clear (any write data clears)
        ar_issue(1);                            // bucket0
        ar_issue(2);  ar_issue(4);              // bucket1 boundaries (x2)
        ar_issue(5);  ar_issue(16);             // bucket2 boundaries (x2)
        ar_issue(17); ar_issue(64);             // bucket3 boundaries (x2)
        ar_issue(65); ar_issue(256);            // bucket4 boundaries (x2)
        idle_n(2);
        axi_read(H1,     rd); expect_eq(rd, 32'd1, "hist len==1");
        axi_read(H24,    rd); expect_eq(rd, 32'd2, "hist 2-4");
        axi_read(H516,   rd); expect_eq(rd, 32'd2, "hist 5-16");
        axi_read(H1764,  rd); expect_eq(rd, 32'd2, "hist 17-64");
        axi_read(H65256, rd); expect_eq(rd, 32'd2, "hist 65-256");

        // ================= Phase 2: MAX_GAP -- longest gap, not sum, not most-recent ====
        $display("-- Phase 2: MAX_GAP --");
        axi_write(ST, 32'hFFFF_FFFF);
        idle_n(5);   ar_issue(1);   // gap 5
        idle_n(20);  ar_issue(1);   // gap 20 <- the longest
        idle_n(3);   ar_issue(1);   // gap 3
        idle_n(12);  ar_issue(1);   // gap 12 (most recent, but NOT the longest)
        axi_read(MAXG, rd); expect_eq(rd, 32'd20, "max gap is longest, not sum or last");

        // ================= Phase 3: BUSY + idle reconciles against ELAPSED =============
        // ELAPSED_CYCLES is free-running: it also counts the handful of cycles this TB's own
        // AXI4-Lite read transaction itself takes to complete (elapsed keeps ticking while we
        // are in the middle of reading it). So it must read back >= the 28 real driven cycles
        // (no undercounting -- every real cycle must be captured) and only a SMALL, bounded
        // amount above that (no runaway/leaked counting from a stuck mon_* signal, which is
        // exactly the bug class this TB caught earlier in bring-up -- see git history of this
        // file). It is not expected to read back exactly 28. BUSY_CYCLES has no such artifact
        // (mon_ar/mon_r are held low for the entire AXI4-Lite polling sequence) so it IS checked
        // for exact equality.
        $display("-- Phase 3: BUSY/ELAPSED reconciliation --");
        axi_write(ST, 32'hFFFF_FFFF);
        idle_n(7);  ar_issue(3);        // 1 busy cycle (the AR handshake itself)
        idle_n(4);  r_burst(6);         // 6 busy cycles
        idle_n(9);  ar_issue(1);        // 1 busy cycle
        axi_read(ELAPS, rd);
        if (rd < 32'd28 || rd > 32'd28 + 32'd8) begin
            $display("  FAIL [elapsed >= 28 driven cycles, few cycles read overhead]: got 0x%08x", rd);
            errors = errors + 1;
        end else begin
            $display("  ok   [elapsed >= 28 driven cycles, few cycles read overhead]: 0x%08x", rd);
        end
        base_elaps = rd;                // reuse as "elapsed value at this checkpoint"
        axi_read(BUSY,  rd); expect_eq(rd, 32'd8,  "busy == 1+6+1 (exact)");
        // idle implied by (elapsed-busy) must be >= the 20 real idle cycles driven, and only the
        // same small bounded amount above it (the read-overhead cycles are idle cycles too, from
        // the monitor's point of view, since mon_ar/mon_r are low throughout the AXI4-Lite read).
        if ((base_elaps - rd) < 32'd20 || (base_elaps - rd) > 32'd20 + 32'd8) begin
            $display("  FAIL [elapsed-busy >= 20 real idle cycles]: got %0d", base_elaps - rd);
            errors = errors + 1;
        end else begin
            $display("  ok   [elapsed-busy >= 20 real idle cycles]: %0d", base_elaps - rd);
        end

        // ================= Phase 4: 0x00 clears ALL sticky + ALL new counters ===========
        $display("-- Phase 4: clear-all --");
        idle_n(3); ar_issue(4); idle_n(1); r_burst(4);   // leave STATUS + counters nonzero
        axi_read(ST, rd);
        if (rd[7:0] == 8'h00) begin
            $display("  FAIL [pre-clear STATUS sanity]: expected nonzero, got 0x%08x", rd);
            errors = errors + 1;
        end
        axi_read(ALO, pre_alo);          // capture pre-clear ARADDR_LO (must survive the clear)
        axi_write(ST, 32'hFFFF_FFFF);    // clear
        // ELAPSED read FIRST and against a small bound, not exact 0 -- it is free-running, so
        // even this one immediate read-back transaction ticks it a little; a broken clear would
        // show the large pre-clear-scale value (tens of cycles+), not a handful.
        axi_read(ELAPS, rd);
        if (rd > 32'd8) begin
            $display("  FAIL [elapsed cleared]: got 0x%08x, want < 9 (near-zero, free-running)", rd);
            errors = errors + 1;
        end else begin
            $display("  ok   [elapsed cleared]: 0x%08x (< 9, free-running read overhead only)", rd);
        end
        axi_read(ST, rd);
        expect_eq(rd & 32'h00FF_FFFF, 32'h0000_0000, "STATUS sticky+counts cleared");
        axi_read(H1,     rd); expect_eq(rd, 32'd0, "hist len1 cleared");
        axi_read(H24,    rd); expect_eq(rd, 32'd0, "hist 2-4 cleared");
        axi_read(H516,   rd); expect_eq(rd, 32'd0, "hist 5-16 cleared");
        axi_read(H1764,  rd); expect_eq(rd, 32'd0, "hist 17-64 cleared");
        axi_read(H65256, rd); expect_eq(rd, 32'd0, "hist 65-256 cleared");
        axi_read(BUSY,   rd); expect_eq(rd, 32'd0, "busy cleared");
        axi_read(MAXG,   rd); expect_eq(rd, 32'd0, "max_gap cleared");
        axi_read(ALO,    rd); expect_eq(rd, pre_alo, "ARADDR_LO unchanged by clear (pre-existing semantics)");

        // ================= Phase 5: saturation (poke to skip 4G real cycles) ============
        $display("-- Phase 5: saturation --");
        axi_write(ST, 32'hFFFF_FFFF);
        dut.hist_len1      = 32'hFFFF_FFFE;
        dut.busy_cycles     = 32'hFFFF_FFFE;
        dut.elapsed_cycles  = 32'hFFFF_FFFE;
        ar_issue(1);                      // real RTL increment: bucket0 + busy + elapsed all +1
        axi_read(H1,    rd); expect_eq(rd, 32'hFFFF_FFFF, "hist len1 at max not wrapped");
        axi_read(BUSY,  rd); expect_eq(rd, 32'hFFFF_FFFF, "busy at max not wrapped");
        axi_read(ELAPS, rd); expect_eq(rd, 32'hFFFF_FFFF, "elapsed at max not wrapped");
        idle_n(1);                        // one more elapsed tick, no ar/busy activity
        axi_read(H1,    rd); expect_eq(rd, 32'hFFFF_FFFF, "hist len1 holds at max");
        axi_read(ELAPS, rd); expect_eq(rd, 32'hFFFF_FFFF, "elapsed holds at max");
        ar_issue(1);                      // one more AR -> busy must hold, not wrap to 0
        axi_read(BUSY,  rd); expect_eq(rd, 32'hFFFF_FFFF, "busy holds at max");

        $display("\n==== FIC0 MONITOR TB: %s (%0d errors) ====", errors ? "FAIL" : "PASS", errors);
        if (errors) $fatal(1, "sar_fic0s_mon self-check failed");
        $finish;
    end

    initial begin
        #1_000_000;
        $display("==== FIC0 MONITOR TB: FAIL (timeout) ====");
        $fatal(1, "timeout");
    end
endmodule
