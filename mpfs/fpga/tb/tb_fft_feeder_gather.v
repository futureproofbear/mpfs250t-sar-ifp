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
    localparam integer TAB_AW    = 4;    // 16 taper words == `TAB_WORDS
    localparam integer G_TAB_AW  = 6;    // 64 idx/wq entries (idx bank 2^5, wq bank 2^4)
    localparam integer G_BUF_AW  = 6;    // 64 source samples/bank -> 128 samples max
    localparam integer G_SFIFO_AW= 5;    // 32-beat gather stream FIFO
    localparam integer FIFO_AW   = 5;
    localparam integer MAX_BURST = 8;

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
        .scale_exp_in(4'd0), .outp_ready_in(1'b0)
    );

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
    integer cid, b, k, errors, total_errors;
    reg [31:0] c_gath, c_win, c_hamr, c_src, c_idx, c_wq, c_s, c_qn, c_nb, c_inj, c_err;
    reg [31:0] st14;
    reg [63:0] want;

    initial begin
        $readmemh("ga_mem.hex", mem);
        $readmemh("ga_exp.hex", exp);
        $readmemh("ga_tab.hex", tab);
        $readmemh("ga_cfg.hex", cfg);
        `CASE_NAMES

        s_awvalid=0; s_wvalid=0; s_arvalid=0; s_awaddr=0; s_wdata=0; s_araddr=0;
        m_axis_tready=1; ngot=0; total_errors=0; do_inject=0;
        gather_cycles=0; gather_samples=0;

        for (cid = 0; cid < `NCASES; cid = cid + 1) begin
            c_gath = cfg[cid*`CFGW+0]; c_win = cfg[cid*`CFGW+1]; c_hamr = cfg[cid*`CFGW+2];
            c_src  = cfg[cid*`CFGW+3]; c_idx = cfg[cid*`CFGW+4]; c_wq   = cfg[cid*`CFGW+5];
            c_s    = cfg[cid*`CFGW+6]; c_qn  = cfg[cid*`CFGW+7]; c_nb   = cfg[cid*`CFGW+8];
            c_inj  = cfg[cid*`CFGW+9]; c_err = cfg[cid*`CFGW+10];

            // fresh reset per case so the sticky err latches are per-case
            resetn = 0; do_inject = 0;
            repeat (6) @(posedge clk);
            resetn = 1;
            repeat (4) @(posedge clk);

            // load the along-row taper (rewind pointer, stream the words)
            lite_w(12'h018, 32'h0002_0000);
            for (k = 0; k < `TAB_WORDS; k = k + 1) lite_w(12'h01c, tab[k]);

            // program the row
            lite_w(12'h020, c_gath);                          // GATHER_CTRL
            lite_w(12'h018, {15'd0, c_win[0], c_hamr[15:0]}); // WIN_CTRL (bit17=0, no rewind)
            lite_w(12'h00c, c_src);                           // ARG0 = src_base
            if (c_gath[0]) begin
                lite_w(12'h024, c_idx);                       // IDX_BASE
                lite_w(12'h028, c_wq);                        // WQ_BASE
                lite_w(12'h02c, {c_qn[15:0], c_s[15:0]});     // GATHER_DIMS
            end else begin
                lite_w(12'h010, c_nb);                        // ARG1 = nbeats (legacy path)
            end

            ngot = 0;
            do_inject = c_inj[0];                             // arm stray injection before START
            lite_w(12'h008, 32'd1);                           // START
            wait_busy_clear;

            // check output beats
            errors = 0;
            for (b = 0; b < `MAXOUT; b = b + 1) begin
                want = exp[cid*`MAXOUT + b];
                if (got[b] !== want) begin
                    if (errors < 4)
                        $display("  case %0s beat %0d: got %016x want %016x",
                                 names[cid], b, got[b], want);
                    errors = errors + 1;
                end
            end

            // check the sticky protocol-violation latches (reg 0x14 bit16 = err_extra)
            lite_r(12'h014, st14);
            if (st14[16] !== c_err[0]) begin
                $display("  case %0s: err_extra=%b expected %b", names[cid], st14[16], c_err[0]);
                errors = errors + 1;
            end

            $display("[gather] case %0s: %0d/%0d beats %s%s", names[cid], `MAXOUT - errors,
                     `MAXOUT, errors ? "FAIL" : "ok",
                     c_inj[0] ? (st14[16] ? "  (err_extra latched)" : "  (ERR NOT LATCHED)") : "");
            total_errors = total_errors + errors;
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
