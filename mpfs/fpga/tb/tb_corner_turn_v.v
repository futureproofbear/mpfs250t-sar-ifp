// tb_corner_turn_v.v -- value-level testbench for the hand-written corner-turn.
//
// The gate is BIT-EXACTNESS against corner_turn.cpp's contract, which is itself verified against
// numpy .T:   dst[(c)*H + r] = src[(r)*W + c]
// Not "it produced bursts", not "it terminated" -- every element is checked.
//
// A SMALL GRID ON PURPOSE. The DUT's GRID is a localparam of 8192; this TB overrides it via
// `GRID_OVR` so a whole frame is a few tiles and a run takes seconds, not hours. The tile edge is
// likewise shrunk (T_LOG2=2 -> T=4) so ragged edges and multi-tile sequencing are actually
// exercised rather than being one big tile.
//
// WHAT IT MUST CATCH (see the mutation list at the bottom of corner_turn_v_design.md):
//   * the bank XOR swapped            -> transposed data lands in the wrong half of every beat
//   * the ragged min() dropped        -> the last tile writes past the edge
//   * the dst stride off by one       -> every row shifted
//   * one element of a packed beat lost -> half the frame stale
//
// The DDR model deliberately returns read data with a GAP after AR (READ_LAT), because the real
// FIC_0 does -- a TB that answers instantly would hide the very stall E4 measured (R_DATAWAIT 35.8%).
`timescale 1ns/1ps
module ct_case #(
    parameter integer GRID_OVR = 16,       // frame edge
    parameter integer T_LOG2   = 2,        // T = 4
    parameter integer CB       = 0,        // c_base  -- strip column base
    parameter integer CC       = 0,        // c_count -- 0 = full frame
    parameter integer NRUNS    = 1,        // arm the SAME instance this many times (RE-ARM path)
    parameter         NAME     = "case"
)(output reg done, output reg [31:0] bad);
    localparam integer READ_LAT = 7;       // cycles between AR accept and first R beat
    initial begin done = 1'b0; bad = 32'd0; end

    reg clk = 1'b0, resetn = 1'b0;
    always #5 clk = ~clk;

    // ---- control ----
    reg  [11:0] s_awaddr;  reg s_awvalid;  wire s_awready;
    reg  [31:0] s_wdata;   reg s_wvalid;   wire s_wready;
    wire s_bvalid;         reg s_bready;
    reg  [11:0] s_araddr;  reg s_arvalid;  wire s_arready;
    wire [31:0] s_rdata;   wire s_rvalid;  reg s_rready;

    // ---- AXI ----
    wire [3:0]  m_arid;  wire [31:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0]  m_arsize; wire [1:0] m_arburst; wire m_arvalid; reg m_arready;
    reg  [63:0] m_rdata; reg m_rlast; reg m_rvalid; wire m_rready;
    wire [3:0]  m_awid;  wire [31:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0]  m_awsize; wire [1:0] m_awburst; wire m_awvalid; reg m_awready;
    wire [63:0] m_wdata; wire [7:0] m_wstrb; wire m_wlast; wire m_wvalid; reg m_wready;
    reg  [1:0]  m_bresp; reg m_bvalid; wire m_bready;

    corner_turn_v #(.T_LOG2(T_LOG2), .GRID(GRID_OVR)) dut (
        .clk(clk), .resetn(resetn),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rdata(m_rdata), .m_rlast(m_rlast), .m_rvalid(m_rvalid), .m_rready(m_rready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready), .m_bresp(m_bresp), .m_bvalid(m_bvalid), .m_bready(m_bready)
    );

    // ============================ DDR model ============================
    localparam integer NEL = GRID_OVR * GRID_OVR;
    // GUARD: dst is allocated LARGER than the frame and the tail is poisoned. An out-of-bounds
    // write would otherwise fall off the end of the array and be silently discarded by the
    // simulator -- which is how a dropped ragged min() escaped the first mutation run. In the real
    // system that same write lands in the next DDR buffer.
    localparam integer GUARD = 4 * GRID_OVR;
    reg [31:0] mem_src [0:NEL+GUARD-1];
    reg [31:0] mem_dst [0:NEL+GUARD-1];
    reg [31:0] golden  [0:NEL-1];

    localparam SRC_BASE = 32'h1000_0000;
    localparam DST_BASE = 32'h2000_0000;

    // ---- read channel: accept AR, wait READ_LAT, then stream beats ----
    integer r_i, r_beats; reg [31:0] r_addr;
    initial begin
        m_arready = 1'b1; m_rvalid = 1'b0; m_rlast = 1'b0; m_rdata = 64'd0;
        forever begin
            @(posedge clk);
            if (m_arvalid && m_arready) begin
                r_addr  = m_araddr; r_beats = m_arlen + 1;
                m_arready = 1'b0;
                repeat (READ_LAT) @(posedge clk);       // the DDR gap E4 measures as R_DATAWAIT
                for (r_i = 0; r_i < r_beats; r_i = r_i + 1) begin
                    m_rdata  = {mem_src[((r_addr - SRC_BASE) >> 2) + 2*r_i + 1],
                                mem_src[((r_addr - SRC_BASE) >> 2) + 2*r_i]};
                    m_rlast  = (r_i == r_beats - 1);
                    m_rvalid = 1'b1;
                    @(posedge clk);
                    while (!m_rready) @(posedge clk);
                end
                m_rvalid = 1'b0; m_rlast = 1'b0;
                m_arready = 1'b1;
            end
        end
    end

    // ---- write channel ----
    integer w_i, w_beats; reg [31:0] w_addr;
    initial begin
        m_awready = 1'b1; m_wready = 1'b0; m_bvalid = 1'b0; m_bresp = 2'b00;
        forever begin
            @(posedge clk);
            if (m_awvalid && m_awready) begin
                w_addr = m_awaddr; w_beats = m_awlen + 1;
                m_awready = 1'b0;
                m_wready  = 1'b1;
                for (w_i = 0; w_i < w_beats; w_i = w_i + 1) begin
                    @(posedge clk);
                    while (!m_wvalid) @(posedge clk);
                    mem_dst[((w_addr - DST_BASE) >> 2) + 2*w_i]     = m_wdata[31:0];
                    mem_dst[((w_addr - DST_BASE) >> 2) + 2*w_i + 1] = m_wdata[63:32];
                end
                m_wready = 1'b0;
                m_bvalid = 1'b1; @(posedge clk);
                while (!m_bready) @(posedge clk);
                m_bvalid = 1'b0;
                m_awready = 1'b1;
            end
        end
    end

    // ============================ control helpers ============================
    task lite_w(input [11:0] a, input [31:0] d);
        begin
            @(posedge clk);
            s_awaddr <= a; s_wdata <= d; s_awvalid <= 1'b1; s_wvalid <= 1'b1; s_bready <= 1'b1;
            @(posedge clk);
            while (!s_awready) @(posedge clk);
            @(posedge clk);
            s_awvalid <= 1'b0; s_wvalid <= 1'b0;
        end
    endtask

    integer i, j, nbad, guard, run, busy_seen;
    initial begin
        s_awaddr=0; s_awvalid=0; s_wdata=0; s_wvalid=0; s_bready=1;
        s_araddr=0; s_arvalid=0; s_rready=1;
        nbad = 0;

        // src = a pattern where every element is unique and position-revealing, so a shifted or
        // swapped element is unmistakable rather than accidentally matching.
        for (i = 0; i < NEL + GUARD; i = i + 1) begin
            mem_src[i] = 32'hC0DE_0000 | i[15:0];
            mem_dst[i] = 32'hDEAD_BEEF;          // poison: an untouched element must FAIL
        end
        // golden: dst[c*H + r] = src[r*W + c], but ONLY for columns the strip covers.
        // Rows outside [CB, CB+CC) must remain poisoned -- that is what proves a strip does not
        // write outside its range, which fft2_ct_overlap's producer/consumer barrier depends on.
        for (i = 0; i < NEL; i = i + 1) golden[i] = 32'hDEAD_BEEF;
        for (j = 0; j < GRID_OVR; j = j + 1)
            if ((CC == 0) || ((j >= CB) && (j < CB + CC)))
                for (i = 0; i < GRID_OVR; i = i + 1)
                    golden[j*GRID_OVR + i] = mem_src[i*GRID_OVR + j];

        repeat (8) @(posedge clk);
        resetn = 1'b1;
        repeat (4) @(posedge clk);

        // RE-ARM LOOP. The kernel is started NRUNS times WITHOUT an intervening reset, because that
        // is what the firmware does: CT#1 inside resample, then CT#2 per strip under
        // fft2_ct_overlap, all on one instance between power cycles. Running each case exactly once
        // after reset -- what this bench did until 2026-07-27 -- cannot see a stale-state re-arm
        // bug, and one shipped to silicon as an instant-completing corner-turn.
        for (run = 0; run < NRUNS; run = run + 1) begin
            // re-poison the destination so run N's PASS can never be run N-1's data
            for (i = 0; i < NEL + GUARD; i = i + 1) mem_dst[i] = 32'hDEAD_BEEF;

            lite_w(12'h00c, SRC_BASE);
            lite_w(12'h010, DST_BASE);
            lite_w(12'h014, CB[31:0]);  // c_base
            lite_w(12'h018, CC[31:0]);  // c_count (0 => full frame)
            lite_w(12'h008, 32'd1);     // START

            // busy MUST assert. If it never does, the firmware's sar_k_wait returns instantly and
            // the pipeline runs on untransposed data -- silent, and the exact silicon failure.
            busy_seen = 0;
            guard = 0;
            while (!busy_seen && guard < 64) begin
                @(posedge clk);
                if (dut.busy) busy_seen = 1;
                guard = guard + 1;
            end
            if (!busy_seen) begin
                $display("  %0s run %0d: BUSY NEVER ASSERTED after START (kernel reports instant done)",
                         NAME, run);
                nbad = nbad + 1;
            end

            guard = 0;
            while (dut.busy && guard < 2000000) begin @(posedge clk); guard = guard + 1; end
            if (dut.busy) begin
                $display("  %0s run %0d: TIMEOUT, busy never cleared after %0d cycles", NAME, run, guard);
                nbad = nbad + 1;
            end
            repeat (32) @(posedge clk);

            for (i = 0; i < NEL; i = i + 1) begin
                if (mem_dst[i] !== golden[i]) begin
                    if (nbad < 10)
                        $display("  %0s run %0d: dst[%0d] (r=%0d c=%0d) got %08x want %08x",
                                 NAME, run, i, i / GRID_OVR, i % GRID_OVR, mem_dst[i], golden[i]);
                    nbad = nbad + 1;
                end
            end

            // the guard must be untouched -- any write past the frame is a bug, however benign it looks
            for (i = NEL; i < NEL + GUARD; i = i + 1)
                if (mem_dst[i] !== 32'hDEAD_BEEF) begin
                    if (nbad < 12) $display("  %0s run %0d: OUT-OF-BOUNDS write at +%0d (%08x)",
                                            NAME, run, i-NEL, mem_dst[i]);
                    nbad = nbad + 1;
                end
        end

        if (nbad == 0)
            $display("  %0s (GRID=%0d, T=%0d, %0d run(s)): PASS (%0d elements bit-exact, guard clean)",
                     NAME, GRID_OVR, (1<<T_LOG2), NRUNS, NEL);
        else
            $display("  %0s (GRID=%0d, T=%0d, %0d run(s)): FAIL (%0d wrong)",
                     NAME, GRID_OVR, (1<<T_LOG2), NRUNS, nbad);
        bad  = nbad[31:0];
        done = 1'b1;
    end
endmodule

// ---- top: an exactly-tiled frame AND a ragged one -------------------------------------------
// 16/4 = 4 exactly, so the ragged min() is UNREACHABLE there -- a mutation removing it survived.
// 14/4 = 3.5, so the last tile is 2 wide/high and the min() is live. Production (8192/128 = 64)
// is exactly tiled, so the ragged path is defensive -- which is precisely why it needs a test:
// untested defensive code that is wrong looks handled.
module tb_corner_turn_v;
    wire d0, d1, d2, d3, d4; wire [31:0] b0, b1, b2, b3, b4;
    ct_case #(.GRID_OVR(16), .T_LOG2(2), .NAME("exact ")) u_exact (.done(d0), .bad(b0));
    ct_case #(.GRID_OVR(14), .T_LOG2(2), .NAME("ragged")) u_ragged(.done(d1), .bad(b1));
    // STRIP: what fft2_ct_overlap actually drives (c_base/c_count), never simulated until now.
    ct_case #(.GRID_OVR(16), .T_LOG2(2), .CB(4), .CC(8), .NAME("strip ")) u_strip(.done(d2), .bad(b2));
    // RE-ARM: the same instance started three times with NO reset between. Silicon does exactly this
    // and nothing above can see it -- each case above resets, runs once, and stops. A corner-turn
    // that leaves stale state behind passes every single-run case and reports instant-done from the
    // second start onward, which is what reached the board on 2026-07-27.
    ct_case #(.GRID_OVR(16), .T_LOG2(2), .NRUNS(3), .NAME("rearm ")) u_rearm(.done(d3), .bad(b3));
    // RE-ARM in strip mode: what the overlap path drives, repeatedly, per strip.
    ct_case #(.GRID_OVR(16), .T_LOG2(2), .CB(4), .CC(8), .NRUNS(3), .NAME("rearmS")) u_rearms(.done(d4), .bad(b4));
    initial begin
        wait (d0 && d1 && d2 && d3 && d4);
        #1;
        if (b0 == 0 && b1 == 0 && b2 == 0 && b3 == 0 && b4 == 0)
            $display("==== corner_turn_v: PASS (all cases bit-exact) ====");
        else
            $display("==== corner_turn_v: FAIL (exact=%0d ragged=%0d strip=%0d rearm=%0d rearmS=%0d) ====",
                     b0, b1, b2, b3, b4);
        $finish;
    end
endmodule
