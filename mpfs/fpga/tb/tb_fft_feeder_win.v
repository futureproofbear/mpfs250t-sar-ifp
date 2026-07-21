// tb_fft_feeder_win.v -- self-checking testbench for the FUSED 2-D HAMMING WINDOW in
// fft_feeder_v.v.
//
// Proves the fused window is BIT-IDENTICAL to hls_window/window.cpp, which is what makes the
// existing pipeline CRC (0xd596c9eb) still a valid gate after the window pass is deleted.
// Reference vectors come from gen_window_vectors.py (which reproduces window.cpp's exact
// truncation order -- see that file: silicon_emulator.py uses a DIFFERENT order and would be
// the wrong reference).
//
// COVERAGE LIMIT, measured -- do not assume otherwise:
// S_DRAIN's `!vA && !vB && !vC` guard (which keeps `busy` high while the window stages still
// hold beats) is NOT covered by this testbench. Mutation-tested three ways -- guard removed,
// with an internal vA/vB/vC-vs-busy assertion, with a delivery-completeness assertion, and
// again with all slave gaps and stream backpressure removed to force the worst case. The
// mutant passes every time. Reason: reading `busy` over AXI4-Lite takes more cycles than the
// 3-stage pipeline depth, so any early DONE is masked before the poll returns. The real
// firmware polls the same way, so the failure is unreachable from the CPU too. The guard is
// kept because it is free and correct -- but it is defensive, not load-bearing, and no test
// here will tell you if it regresses.
//
// Covers, per the failure modes that actually bite this design:
//   1. windowed rows, value-for-value against the C reference (incl. -32768/+32767 tapers,
//      zero-pad taps, and all four sign combinations)
//   2. win_en=0 passthrough -- the azimuth FFT pass must be bit-unchanged
//   3. AXI R-channel gaps + AXI-Stream backpressure, to stress the 3-stage pipeline's
//      interaction with the pre-reserved FIFO
//   4. re-arm: every row must restart the taper index at 0 (the golden CoreFFT TB never
//      exercised re-arm, and that cost real time once already)
//
// Run (vectors are gitignored -- regenerate them first, the generator is the source of truth):
//   python gen_window_vectors.py
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib work && $MS/vlog -work work +incdir+. tb_fft_feeder_win.v ../fft_feeder_v.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_fft_feeder_win
// Expected: 11 rows "ok" and "==== fused-window feeder: PASS (0 mismatching beats) ===="
`timescale 1ns/1ps
`include "win_dims.vh"

module tb_fft_feeder_win;

    localparam integer TAB_AW    = 4;                 // 16 taper words == `TAB_WORDS
    localparam integer FIFO_AW   = 5;
    localparam integer MAX_BURST = 8;
    localparam integer NBEATS    = `ROWS * `BEATS_PER_ROW;

    reg clk = 0, resetn = 0;
    always #8 clk = ~clk;                              // 62.5 MHz, the fabric clock

    // ---- reference data ----
    reg [63:0] mem     [0:NBEATS-1];                   // DDR image the read master fetches
    reg [63:0] expect  [0:NBEATS-1];
    reg [31:0] tab     [0:`TAB_WORDS-1];
    reg [15:0] scale   [0:`ROWS-1];

    // ---- DUT wires ----
    reg  [11:0] s_awaddr; reg s_awvalid; wire s_awready;
    reg  [31:0] s_wdata;  reg s_wvalid;  wire s_wready;
    wire s_bvalid; reg s_bready = 1'b1;
    reg  [11:0] s_araddr; reg s_arvalid; wire s_arready;
    wire [31:0] s_rdata;  wire s_rvalid; reg s_rready = 1'b1;

    wire [3:0]  m_arid;  wire [31:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0]  m_arsize; wire [1:0] m_arburst; wire m_arvalid; reg m_arready;
    reg  [3:0]  m_rid = 4'd0; reg [63:0] m_rdata; reg m_rlast; reg m_rvalid; wire m_rready;

    wire [63:0] m_axis_tdata; wire m_axis_tvalid; reg m_axis_tready;

    fft_feeder_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4),
                   .MAX_BURST(MAX_BURST), .FIFO_AW(FIFO_AW), .TAB_AW(TAB_AW)) dut (
        .clk(clk), .resetn(resetn),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_arid(m_arid), .m_araddr(m_araddr), .m_arlen(m_arlen), .m_arsize(m_arsize),
        .m_arburst(m_arburst), .m_arvalid(m_arvalid), .m_arready(m_arready),
        .m_rid(m_rid), .m_rdata(m_rdata), .m_rlast(m_rlast), .m_rvalid(m_rvalid),
        .m_rready(m_rready),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid), .m_axis_tready(m_axis_tready),
        .scale_exp_in(4'd0), .outp_ready_in(1'b0)
    );

    // ================= mock AXI4 read slave (with random R gaps) =================
    // `s_cnt` counts beats PRESENTED, and only advances when one is actually consumed
    // (rvalid & rready). Conflating "presented" with "consumed" silently replays a beat
    // around every idle bubble, which looks exactly like a DUT off-by-one.
    localparam SL_IDLE = 1'b0, SL_DATA = 1'b1;
    reg        sl_state;
    reg [31:0] s_addr;
    integer    s_cnt, s_tot;
    integer    seed = 32'h5eed_1234;
    reg        rnd_ok;
    always @(posedge clk) rnd_ok <= (($random(seed) % 4) != 0);   // ~25% idle R beats

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_arready <= 1'b1; m_rvalid <= 1'b0; m_rlast <= 1'b0;
            sl_state  <= SL_IDLE; s_cnt <= 0; s_tot <= 0; s_addr <= 0;
        end else case (sl_state)
            SL_IDLE: begin
                m_rvalid <= 1'b0; m_rlast <= 1'b0;
                if (m_arvalid && m_arready) begin
                    s_addr    <= m_araddr >> 3;
                    s_tot     <= m_arlen + 1;
                    s_cnt     <= 0;
                    m_arready <= 1'b0;
                    sl_state  <= SL_DATA;
                end
            end
            SL_DATA: begin
                if (m_rvalid && m_rready) begin           // beat consumed
                    if (m_rlast) begin
                        m_rvalid <= 1'b0; m_rlast <= 1'b0;
                        m_arready <= 1'b1; sl_state <= SL_IDLE;
                    end else begin
                        s_cnt <= s_cnt + 1;
                        if (rnd_ok) begin
                            m_rdata  <= mem[s_addr + s_cnt + 1];
                            m_rlast  <= ((s_cnt + 1) == s_tot - 1);
                            m_rvalid <= 1'b1;
                        end else m_rvalid <= 1'b0;
                    end
                end else if (!m_rvalid) begin             // idle -> maybe present the next beat
                    if (rnd_ok) begin
                        m_rdata  <= mem[s_addr + s_cnt];
                        m_rlast  <= (s_cnt == s_tot - 1);
                        m_rvalid <= 1'b1;
                    end
                end
                // m_rvalid && !m_rready: hold data/valid stable, as AXI requires
            end
        endcase
    end

    // ================= busy (0x08) polling + the property that matters =================
    // The firmware declares a row complete by polling busy, then immediately rewrites
    // win_scale for the next row. So `busy` must NOT drop while the window stages still
    // hold data -- otherwise a row is split across two hamr values. Counting stream beats
    // and waiting a fixed delay (the original approach) passes even if busy drops early,
    // which is precisely the regression S_DRAIN's !vA/!vB/!vC guard exists to prevent.
    integer ngot;                   // beats collected off the stream (declared ahead of the tasks)
    task lite_r(input [11:0] a, output [31:0] d);
    begin
        @(posedge clk);
        s_araddr <= a; s_arvalid <= 1'b1;
        @(posedge clk);
        while (!s_arready) @(posedge clk);
        s_arvalid <= 1'b0;
        while (!s_rvalid) @(posedge clk);
        d = s_rdata;
        @(posedge clk);
    end
    endtask

    // ngot sampled at the instant busy cleared. THIS is the property that matters: the
    // firmware treats busy==0 as "row complete" and immediately rewrites win_scale, so every
    // beat of the row must already be on the stream by then. Checking an internal signal
    // (vA/vB/vC vs busy) is weaker -- it can pass vacuously if the scenario never arises.
    integer ngot_at_done;
    task wait_row_done;
        reg [31:0] st;
        integer guard;
    begin
        guard = 0;
        st = 32'd1;
        while (st[0] !== 1'b0) begin
            lite_r(12'h008, st);
            guard = guard + 1;
            if (guard > 20000) begin
                $display("  TIMEOUT waiting for busy to clear");
                $fatal(1, "busy never cleared");
            end
        end
        ngot_at_done = ngot;
        if (ngot_at_done < `BEATS_PER_ROW) begin
            $display("  ASSERT FAIL: busy cleared with only %0d/%0d beats delivered",
                     ngot_at_done, `BEATS_PER_ROW);
            $fatal(1, "DONE reported before all data was streamed");
        end
    end
    endtask

    // Continuous assertion: busy must be high whenever a stage holds a beat.
    always @(posedge clk) begin
        if (resetn && (dut.vA || dut.vB || dut.vC) && !dut.busy) begin
            $display("  ASSERT FAIL: busy=0 while pipeline holds data (vA=%b vB=%b vC=%b)",
                     dut.vA, dut.vB, dut.vC);
            $fatal(1, "busy dropped with beats in flight");
        end
    end

    // ================= AXI4-Lite register write =================
    task lite_w(input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        s_awaddr <= a; s_wdata <= d; s_awvalid <= 1'b1; s_wvalid <= 1'b1;
        @(posedge clk);
        while (!s_awready) @(posedge clk);
        s_awvalid <= 1'b0; s_wvalid <= 1'b0;
        @(posedge clk);
    end
    endtask

    // ================= stream collector =================
    reg [63:0] got [0:NBEATS-1];
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready) begin
            got[ngot] = m_axis_tdata;
            ngot = ngot + 1;
        end
        m_axis_tready <= ($random(seed) % 8 != 0);      // ~12% backpressure
    end

    // ================= test =================
    integer row, b, errors, total_errors, k;
    reg [63:0] want;

    initial begin
        $readmemh("win_in.hex",    mem);
        $readmemh("win_exp.hex",   expect);
        $readmemh("win_tab.hex",   tab);
        $readmemh("win_scale.hex", scale);

        s_awvalid = 0; s_wvalid = 0; s_arvalid = 0; s_awaddr = 0; s_wdata = 0; s_araddr = 0;
        m_axis_tready = 1; ngot = 0; total_errors = 0;
        repeat (8) @(posedge clk);
        resetn = 1;
        repeat (4) @(posedge clk);

        // ---- load the taper: rewind the pointer, then stream the words ----
        lite_w(12'h018, 32'h0002_0000);                 // bit17 = rewind tab pointer
        for (k = 0; k < `TAB_WORDS; k = k + 1) lite_w(12'h01c, tab[k]);

        // ================= PASS 1: window ENABLED =================
        for (row = 0; row < `ROWS; row = row + 1) begin
            ngot = 0;
            lite_w(12'h018, {15'd0, 1'b1, scale[row]});             // enable + hamr[row]
            lite_w(12'h00c, row * `BEATS_PER_ROW * 8);              // ARG0 src byte address
            lite_w(12'h010, `BEATS_PER_ROW);                        // ARG1 nbeats
            lite_w(12'h008, 32'd1);                                 // START
            wait_row_done;                                          // poll busy, not beat count

            errors = 0;
            for (b = 0; b < `BEATS_PER_ROW; b = b + 1) begin
                want = expect[row * `BEATS_PER_ROW + b];
                if (got[b] !== want) begin
                    if (errors < 4)
                        $display("  ROW %0d BEAT %0d: got %016x want %016x", row, b, got[b], want);
                    errors = errors + 1;
                end
            end
            $display("[win ] row %0d: %0d/%0d beats %s", row, `BEATS_PER_ROW - errors,
                     `BEATS_PER_ROW, errors ? "FAIL" : "ok");
            total_errors = total_errors + errors;
        end

        // ================= PASS 2: window DISABLED -> passthrough =================
        // The azimuth FFT pass reuses this feeder and must be bit-unchanged.
        for (row = 0; row < 2; row = row + 1) begin
            ngot = 0;
            lite_w(12'h018, 32'h0000_0000);                         // disable
            lite_w(12'h00c, row * `BEATS_PER_ROW * 8);
            lite_w(12'h010, `BEATS_PER_ROW);
            lite_w(12'h008, 32'd1);
            wait_row_done;

            errors = 0;
            for (b = 0; b < `BEATS_PER_ROW; b = b + 1) begin
                want = mem[row * `BEATS_PER_ROW + b];
                if (got[b] !== want) begin
                    if (errors < 4)
                        $display("  BYPASS ROW %0d BEAT %0d: got %016x want %016x",
                                 row, b, got[b], want);
                    errors = errors + 1;
                end
            end
            $display("[pass] row %0d: %0d/%0d beats %s", row, `BEATS_PER_ROW - errors,
                     `BEATS_PER_ROW, errors ? "FAIL" : "ok");
            total_errors = total_errors + errors;
        end

        // ================= PASS 3: re-arm after bypass must re-enable cleanly =================
        // (catches a sticky win_en or a taper index that did not restart)
        ngot = 0;
        lite_w(12'h018, {15'd0, 1'b1, scale[3]});
        lite_w(12'h00c, 3 * `BEATS_PER_ROW * 8);
        lite_w(12'h010, `BEATS_PER_ROW);
        lite_w(12'h008, 32'd1);
        wait_row_done;
        errors = 0;
        for (b = 0; b < `BEATS_PER_ROW; b = b + 1)
            if (got[b] !== expect[3 * `BEATS_PER_ROW + b]) errors = errors + 1;
        $display("[rearm] row 3 after bypass: %0d/%0d beats %s",
                 `BEATS_PER_ROW - errors, `BEATS_PER_ROW, errors ? "FAIL" : "ok");
        total_errors = total_errors + errors;

        $display("\n==== fused-window feeder: %s (%0d mismatching beats) ====",
                 total_errors ? "FAIL" : "PASS", total_errors);
        if (total_errors) $fatal(1, "window fusion is NOT bit-identical to window.cpp");
        $finish;
    end

    // watchdog -- a stalled handshake must fail loudly, not hang the build
    initial begin
        #5_000_000;
        $display("==== fused-window feeder: FAIL (timeout -- handshake stalled) ====");
        $fatal(1, "timeout");
    end
endmodule
