// tb_fft_feeder_gather.v -- self-checking testbench for the FUSED azimuth-resample GATHER in
// fft_feeder_v.v (gather -> 2-D Hamming window -> stream, runtime-enabled by reg 0x20 bit0).
//
// Proves the fused gather+window is BIT-IDENTICAL to a gather-then-window reference (the shipping
// resample.cpp lerp followed by window.cpp window). Reference vectors come from
// gen_gather_vectors.py, which reproduces both authorities with exact Python integers.
//
// Cases (mandatory coverage from the brief):
//   0 normal   : monotonic idx in range, varied wq, window ON            (a)
//   1 zerofill : idx off BOTH ends -> zero fill                          (b)
//   2 bypass   : gather DISABLED -> legacy window-only path bit-identical(c)
//   3 stray    : a stray R beat during the SOURCE load -> err_extra AND no row shift (d)
//   4 descend  : descending idx + edge zero fill                          (e)
//   5 nowin    : gather ON, window OFF (win_en gating inside gather mode)
// Random R-channel gaps (mock slave) + AXI-Stream backpressure run throughout (f).
//
// ---- COEFFICIENT-SOURCE A/B (added with the sar_coeffgen fuse, reg 0x20 bit1) ---------------
// Every gather-enabled case is run TWICE on identical inputs: once with coefficients loaded from
// DDR (bit1=0, the shipping path) and once with the SAME idx/wq values pushed in on the
// {c_idx,c_wq,c_valid,c_ready} stream (bit1=1). The run FAILS unless the two output streams are
// beat-for-beat IDENTICAL -- that is the property the runtime fallback rests on, and it is the
// one thing a coeffgen-only testbench cannot show.
// In the stream run IDX_BASE/WQ_BASE are deliberately pointed at the SOURCE row instead of the
// coefficient tables: if the feeder still touched the DDR coefficient path it would gather with
// source samples as indices/weights and the compare would diverge immediately.
// The stream is driven with ~20% valid bubbles, so the c_valid gating of g_issue is exercised
// (a feeder that ignored c_valid would consume a stale entry and shift the whole row).
// The stream run's DDR read-beat count is also asserted to be the SOURCE row only, because the
// skipped idx/wq passes are a throughput property that no value compare can observe.
//
// A/B MUTATION COVERAGE -- measured by applying each to fft_feeder_v.v and re-running:
//   * idx1 source mux forced to the DDR banks   -> FAIL 148 beats
//   * wq1  source mux forced to the DDR banks   -> FAIL 148
//   * g_issue ignores c_valid (stale entry)     -> FAIL 125 (and the drained-entry guard trips)
//   * G_IDX/G_WQ passes NOT skipped in stream mode -> FAIL 5 (read-beat count 42 vs 18)
//   * capture c_idx/c_wq unconditionally instead of at issue -> NOT observable, and provably so:
//     stage 1 consumes c_idx_r only on the cycle after issue, which the issue-edge capture already
//     fixes. Stated, not claimed as covered.
//
// NOTE ON SCOPE: this proves the FEEDER's consumption path. That the streamed VALUES equal the C
// reference is proven separately by tb_sar_coeffgen.v + mpfs/host/check_coeffgen_fixed.py; no
// board-free test wires the two RTL blocks together through the real interconnect.
//
// MUTATION CHECKS (confirmed to FAIL the TB -- see gen_gather_vectors.py header):
//   * drop `signed` on the lerp difference (b-a)  -> negative source samples diverge (cases 0/1/4)
//   * B = srcbuf[idx] instead of srcbuf[idx+1]    -> interior interpolation wrong
//   * drop `signed` on the window multiply        -> negative taper/sample diverge
//   * lose the stray-beat err latch or shift a bank -> case 3 diverges / err mismatch
//
// Run (vectors are gitignored -- regenerate first, the generator is the source of truth):
//   python gen_gather_vectors.py
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib work && $MS/vlog -work work +incdir+. tb_fft_feeder_gather.v ../fft_feeder_v.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_fft_feeder_gather
// Expected: every case "ok" and "==== fused-gather feeder: PASS (0 mismatching beats) ===="
`timescale 1ns/1ps
`include "ga_dims.vh"

module tb_fft_feeder_gather;

    // DUT sized down for the toy frame (QN=32, S<=36).
    // SILICON PARAMETERS. These were 4/6/6/5/5/8 until 2026-07-30 -- every earlier pass of this
    // bench described a DIFFERENT module than the bitstream. fft_feeder_top.v overrides only the
    // three AXI widths, so synthesis builds fft_feeder_v's module defaults, and those are these.
    // Registered in check_tb_params.py at the same time; the gate now enforces it.
    localparam integer TAB_AW    = 12;   // taper table 4096 words
    localparam integer G_TAB_AW  = 13;   // 8192 idx/wq entries
    localparam integer G_BUF_AW  = 12;   // 4096 source samples/bank -> 8192 samples max
    localparam integer G_SFIFO_AW= 9;    // 512-beat gather stream FIFO
    localparam integer FIFO_AW   = 9;
    localparam integer MAX_BURST = 64;

    reg clk = 0, resetn = 0;
    always #8 clk = ~clk;                // 62.5 MHz fabric clock

    // ---- reference data ----
    reg [63:0] mem [0:`MEM_BEATS-1];
    reg [63:0] exp [0:`NCASES*`MAXOUT-1];
    reg [31:0] tab [0:`TAB_WORDS-1];
    reg [31:0] cfg [0:`NCASES*`CFGW-1];
    reg [8*12:1] names [0:`NCASES-1];

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

    // coefficient stream (TB-driven; sar_coeffgen's stream contract)
    wire signed [31:0] c_idx; wire [15:0] c_wq; wire c_valid; wire c_ready;

    fft_feeder_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4),
                   .MAX_BURST(MAX_BURST), .FIFO_AW(FIFO_AW), .TAB_AW(TAB_AW),
                   .G_BUF_AW(G_BUF_AW), .G_TAB_AW(G_TAB_AW), .G_SFIFO_AW(G_SFIFO_AW)) dut (
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
        .c_idx(c_idx), .c_wq(c_wq), .c_valid(c_valid), .c_ready(c_ready),
        .scale_exp_in(4'd0), .outp_ready_in(1'b0)
    );

    // ================= coefficient stream driver (sar_coeffgen's contract) ==================
    // Presents cs_n entries in qi order with ~20% valid bubbles. Held off entirely (c_valid low)
    // when cs_en == 0, so the DDR-coefficient runs are bit-unchanged.
    reg        cs_en;                       // set by the test before START
    reg [15:0] cs_n;                        // entries to present == QN
    reg [31:0] cidx_a [0:`QN-1];
    reg [15:0] cwq_a  [0:`QN-1];
    reg [31:0] cs_idx_r; reg [15:0] cs_wq_r; reg cs_valid_r; reg [15:0] cs_i;
    reg        cs_gap;
    always @(posedge clk) cs_gap <= (($random(seed) % 5) == 0);   // ~20% valid bubbles

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cs_valid_r <= 1'b0; cs_idx_r <= 32'd0; cs_wq_r <= 16'd0; cs_i <= 16'd0;
        end else begin
            if (cs_valid_r & c_ready) cs_valid_r <= 1'b0;
            if ((~cs_valid_r | c_ready) & cs_en & ~cs_gap & (cs_i < cs_n)) begin
                cs_idx_r   <= cidx_a[cs_i];
                cs_wq_r    <= cwq_a[cs_i];
                cs_valid_r <= 1'b1;
                cs_i       <= cs_i + 16'd1;
            end
        end
    end
    assign c_idx  = $signed(cs_idx_r);
    assign c_wq   = cs_wq_r;
    assign c_valid = cs_valid_r & cs_en;

    // ================= mock AXI4 read slave (random R gaps + one-shot stray injection) =======
    // s_cnt counts beats PRESENTED; advances only on a consumed beat (rvalid&rready), so an idle
    // bubble never silently replays a beat (which would mimic a DUT off-by-one).
    localparam SL_IDLE = 2'd0, SL_DATA = 2'd1, SL_INJECT = 2'd2;
    reg [1:0]  sl_state;
    reg [31:0] s_addr;
    integer    s_cnt, s_tot;
    integer    seed = 32'h5eed_1234;
    reg        rnd_ok;
    reg        do_inject;                 // set per case (case 3) BEFORE START
    reg        injected;                  // one-shot latch
    always @(posedge clk) rnd_ok <= (($random(seed) % 4) != 0);   // ~25% idle R beats

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_arready <= 1'b1; m_rvalid <= 1'b0; m_rlast <= 1'b0;
            sl_state <= SL_IDLE; s_cnt <= 0; s_tot <= 0; s_addr <= 0; injected <= 1'b0;
        end else case (sl_state)
            SL_IDLE: begin
                m_rvalid <= 1'b0; m_rlast <= 1'b0;
                if (m_arvalid && m_arready) begin
                    s_addr <= m_araddr >> 3; s_tot <= m_arlen + 1; s_cnt <= 0;
                    m_arready <= 1'b0; sl_state <= SL_DATA;
                end
            end
            SL_DATA: begin
                if (m_rvalid && m_rready) begin              // beat consumed
                    if (m_rlast) begin
                        // Inject ONE stray beat after the first completed burst (SOURCE load).
                        if (do_inject && !injected) begin
                            m_rdata  <= 64'hDEAD_BEEF_F00D_CAFE;
                            m_rlast  <= 1'b0; m_rvalid <= 1'b1;
                            m_arready <= 1'b0; sl_state <= SL_INJECT;
                        end else begin
                            m_rvalid <= 1'b0; m_rlast <= 1'b0;
                            m_arready <= 1'b1; sl_state <= SL_IDLE;
                        end
                    end else begin
                        s_cnt <= s_cnt + 1;
                        if (rnd_ok) begin
                            m_rdata  <= mem[s_addr + s_cnt + 1];
                            m_rlast  <= ((s_cnt + 1) == s_tot - 1);
                            m_rvalid <= 1'b1;
                        end else m_rvalid <= 1'b0;
                    end
                end else if (!m_rvalid) begin                // idle -> maybe present next beat
                    if (rnd_ok) begin
                        m_rdata  <= mem[s_addr + s_cnt];
                        m_rlast  <= (s_cnt == s_tot - 1);
                        m_rvalid <= 1'b1;
                    end
                end
            end
            SL_INJECT: begin
                if (m_rvalid && m_rready) begin              // stray beat consumed by the DUT
                    m_rvalid <= 1'b0; injected <= 1'b1;
                    m_arready <= 1'b1; sl_state <= SL_IDLE;
                end
            end
        endcase
    end

    // ================= AXI4-Lite register access =================
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

    // ================= stream collector (with backpressure) =================
    integer ngot;
    reg [63:0] got [0:`MAXOUT-1];
    always @(posedge clk) begin
        if (m_axis_tvalid && m_axis_tready && ngot < `MAXOUT) begin
            got[ngot] = m_axis_tdata;
            ngot = ngot + 1;
        end
        m_axis_tready <= ($random(seed) % 8 != 0);   // ~12% backpressure
    end

    // DDR read beats REQUESTED per run (sum of ARLEN+1 over accepted ARs). The stream run must
    // ask for the SOURCE row only -- that deletion (idx+wq = 6144 of 8961 beats/row in production)
    // is the whole throughput case for the fuse, and it is a property no value compare can see.
    integer ar_beats;
    always @(posedge clk)
        if (resetn && m_arvalid && m_arready) ar_beats = ar_beats + (m_arlen + 1);

    // throughput measurement (gather/stream phase): count cycles where a sample could be produced
    integer gather_cycles, gather_samples;
    always @(posedge clk) begin
        if (resetn && dut.gstate == 3'd4 /*G_GATHER*/) begin
            gather_cycles = gather_cycles + 1;
            if (dut.g5_v && dut.gen) gather_samples = gather_samples + 1;
        end
    end

    task wait_busy_clear;
        reg [31:0] st; integer guard;
    begin
        guard = 0; st = 32'd1;
        while (st[0] !== 1'b0) begin
            lite_r(12'h008, st);
            guard = guard + 1;
            if (guard > 40000) $fatal(1, "busy never cleared");
        end
    end
    endtask

    // ================= test =================
    integer cid, b, k, errors, total_errors, mode, nmode, ab_errors, ddr_beats;
    reg [31:0] c_gath, c_win, c_hamr, c_src, c_idxb, c_wqb, c_s, c_qn, c_nb, c_inj, c_err;
    reg [31:0] st14;
    reg [63:0] want, tmpw;
    reg [63:0] got_ddr [0:`MAXOUT-1];     // DDR-coefficient reference run, for the A/B compare
    integer    mb;

    initial begin
        $readmemh("ga_mem.hex", mem);
        $readmemh("ga_exp.hex", exp);
        $readmemh("ga_tab.hex", tab);
        $readmemh("ga_cfg.hex", cfg);
        `CASE_NAMES

        s_awvalid=0; s_wvalid=0; s_arvalid=0; s_awaddr=0; s_wdata=0; s_araddr=0;
        m_axis_tready=1; ngot=0; total_errors=0; do_inject=0;
        gather_cycles=0; gather_samples=0; cs_en=0; cs_n=0;

        for (cid = 0; cid < `NCASES; cid = cid + 1) begin
            c_gath = cfg[cid*`CFGW+0]; c_win = cfg[cid*`CFGW+1]; c_hamr = cfg[cid*`CFGW+2];
            c_src  = cfg[cid*`CFGW+3]; c_idxb= cfg[cid*`CFGW+4]; c_wqb  = cfg[cid*`CFGW+5];
            c_s    = cfg[cid*`CFGW+6]; c_qn  = cfg[cid*`CFGW+7]; c_nb   = cfg[cid*`CFGW+8];
            c_inj  = cfg[cid*`CFGW+9]; c_err = cfg[cid*`CFGW+10];

            // mode 0 = coefficients from DDR (shipping path). mode 1 = same values on the stream.
            // Only gather-enabled cases have a coefficient source to switch.
            nmode = c_gath[0] ? 2 : 1;
            for (mode = 0; mode < nmode; mode = mode + 1) begin

            // Extract this case's idx/wq entries STRAIGHT OUT OF THE DDR IMAGE the other mode
            // reads, so the two runs are driven by literally the same numbers. Layout mirrors the
            // feeder's bank fill: idx entry i -> beat i>>1 lane i&1 ; wq entry i -> beat i>>2 lane i&3.
            if (mode == 1) begin
                for (k = 0; k < c_qn; k = k + 1) begin
                    mb   = (c_idxb >> 3) + (k >> 1);
                    tmpw = mem[mb];
                    cidx_a[k] = k[0] ? tmpw[63:32] : tmpw[31:0];
                    mb   = (c_wqb >> 3) + (k >> 2);
                    tmpw = mem[mb];
                    case (k[1:0])
                        0: cwq_a[k] = tmpw[15:0];
                        1: cwq_a[k] = tmpw[31:16];
                        2: cwq_a[k] = tmpw[47:32];
                        default: cwq_a[k] = tmpw[63:48];
                    endcase
                end
            end

            // fresh reset per run so the sticky err latches and the stream index are per-run
            resetn = 0; do_inject = 0; cs_en = 0;
            repeat (6) @(posedge clk);
            resetn = 1;
            repeat (4) @(posedge clk);

            // POISON the DDR coefficient banks before a stream run. WITHOUT THIS THE A/B IS
            // VACUOUS: reset does not clear LSRAM, and the stream run SKIPS the G_IDX/G_WQ load
            // passes, so the banks still hold the DDR run's correct coefficients -- a feeder that
            // ignored the stream entirely would still produce the right answer. MEASURED: with the
            // idx1 source mux mutated to always read the banks, the A/B passed until this was
            // added, and fails now.
            if (mode == 1) begin
                for (k = 0; k < (1 << (G_TAB_AW-1)); k = k + 1) begin
                    dut.idxbuf0[k] = 32'hDEAD_BEEF;   // negative -> would zero-fill, not interpolate
                    dut.idxbuf1[k] = 32'hDEAD_BEEF;
                end
                for (k = 0; k < (1 << (G_TAB_AW-2)); k = k + 1) begin
                    dut.wqbuf0[k] = 16'h5A5A; dut.wqbuf1[k] = 16'h5A5A;
                    dut.wqbuf2[k] = 16'h5A5A; dut.wqbuf3[k] = 16'h5A5A;
                end
            end

            // load the along-row taper (rewind pointer, stream the words)
            lite_w(12'h018, 32'h0002_0000);
            for (k = 0; k < `TAB_WORDS; k = k + 1) lite_w(12'h01c, tab[k]);

            // program the row
            lite_w(12'h020, {30'd0, (mode == 1), c_gath[0]}); // GATHER_CTRL [1]=stream coeffs
            lite_w(12'h018, {15'd0, c_win[0], c_hamr[15:0]}); // WIN_CTRL (bit17=0, no rewind)
            lite_w(12'h00c, c_src);                           // ARG0 = src_base
            if (c_gath[0]) begin
                // mode 1 points the DDR coefficient bases at the SOURCE row: if the feeder still
                // used them the gather would run on source samples and diverge at once.
                lite_w(12'h024, (mode == 1) ? c_src : c_idxb); // IDX_BASE
                lite_w(12'h028, (mode == 1) ? c_src : c_wqb);  // WQ_BASE
                lite_w(12'h02c, {c_qn[15:0], c_s[15:0]});      // GATHER_DIMS
            end else begin
                lite_w(12'h010, c_nb);                        // ARG1 = nbeats (legacy path)
            end

            ngot = 0; ar_beats = 0;
            cs_n = c_qn[15:0];
            cs_en = (mode == 1);                              // arm the coefficient stream
            do_inject = c_inj[0];                             // arm stray injection before START
            lite_w(12'h008, 32'd1);                           // START
            wait_busy_clear;
            cs_en = 0;

            // check output beats
            errors = 0;
            for (b = 0; b < `MAXOUT; b = b + 1) begin
                want = exp[cid*`MAXOUT + b];
                if (got[b] !== want) begin
                    if (errors < 4)
                        $display("  case %0s[%0s] beat %0d: got %016x want %016x",
                                 names[cid], mode ? "stream" : "ddr", b, got[b], want);
                    errors = errors + 1;
                end
            end

            // check the sticky protocol-violation latches (reg 0x14 bit16 = err_extra)
            lite_r(12'h014, st14);
            if (st14[16] !== c_err[0]) begin
                $display("  case %0s[%0s]: err_extra=%b expected %b", names[cid],
                         mode ? "stream" : "ddr", st14[16], c_err[0]);
                errors = errors + 1;
            end

            // A/B: the stream run must be beat-for-beat identical to the DDR run
            ab_errors = 0;
            if (mode == 0) begin
                for (b = 0; b < `MAXOUT; b = b + 1) got_ddr[b] = got[b];
                ddr_beats = ar_beats;
            end else begin
                // the stream run must fetch the SOURCE row and NOTHING else
                if (ar_beats !== ((c_s + 1) >> 1)) begin
                    $display("  case %0s A/B: stream run read %0d beats, expected %0d (source only, ddr run read %0d) -- idx/wq passes not skipped",
                             names[cid], ar_beats, (c_s + 1) >> 1, ddr_beats);
                    ab_errors = ab_errors + 1;
                end
                for (b = 0; b < `MAXOUT; b = b + 1)
                    if (got[b] !== got_ddr[b]) begin
                        if (ab_errors < 4)
                            $display("  case %0s A/B beat %0d: stream %016x ddr %016x",
                                     names[cid], b, got[b], got_ddr[b]);
                        ab_errors = ab_errors + 1;
                    end
                // Guard against a vacuous A/B: the stream must actually have been drained.
                if (cs_i !== c_qn[15:0]) begin
                    $display("  case %0s A/B: feeder consumed %0d of %0d stream entries",
                             names[cid], cs_i, c_qn);
                    ab_errors = ab_errors + 1;
                end
            end

            $display("[gather] case %0s[%0s]: %0d/%0d beats, %0d DDR reads %s%s%s", names[cid],
                     mode ? "stream" : "ddr", `MAXOUT - errors, `MAXOUT, ar_beats,
                     errors ? "FAIL" : "ok",
                     (mode == 1) ? (ab_errors ? "  A/B FAIL" : "  A/B identical to ddr") : "",
                     c_inj[0] ? (st14[16] ? "  (err_extra latched)" : "  (ERR NOT LATCHED)") : "");
            total_errors = total_errors + errors + ab_errors;
            end
        end

        $display("\ngather/stream phase: %0d samples in %0d G_GATHER cycles",
                 gather_samples, gather_cycles);
        $display("\n==== fused-gather feeder: %s (%0d mismatching beats) ====",
                 total_errors ? "FAIL" : "PASS", total_errors);
        if (total_errors) $fatal(1, "fused gather is NOT bit-identical to gather-then-window");
        $finish;
    end

    // watchdog
    initial begin
        #10_000_000;
        $display("==== fused-gather feeder: FAIL (timeout -- handshake stalled) ====");
        $fatal(1, "timeout");
    end
endmodule
