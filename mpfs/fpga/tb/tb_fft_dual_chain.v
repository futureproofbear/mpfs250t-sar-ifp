// tb_fft_dual_chain.v -- TWO complete CoreFFT chains vs ONE, over the same rows, byte-for-byte.
//
// WHAT THIS PROVES (the acceptance question for the second chain):
//   Splitting a pass's ROWS across two independent feeder->gearbox->CoreFFT->unloader chains
//   produces DDR contents and per-row block exponents BIT-IDENTICAL to running the same rows
//   sequentially on one chain -- including each chain latching its OWN CoreFFT's SCALE_EXP.
//
// STRUCTURE (mirrors sartop_assembly.tcl exactly, one instance quadruple per chain):
//
//   COEF stream A --> FEED_A(fft_feeder_v) --> GBX_A(corefft_stream64_adapter) --> FFT_A
//                          ^  SCALE_EXP/OUTP_READY <---------------------------------|
//                                                   GBX_A --> UNLD_A(fft_unloader_v) --> DDR
//   COEF stream B --> FEED_B ------------------> GBX_B --> FFT_B --> GBX_B --> UNLD_B --> DDR
//
//   All four AXI masters share ONE DDR model through an arbiter that grants ONE READ BURST at a
//   time interconnect-wide -- that is the SASD (CROSSBAR_MODE:0 / OPEN_TRANS_MAX:1) property the
//   ID-less feeders (m_arid tied 0) depend on, and it is why this change does NOT touch SASD.
//   Writes are arbitrated the same way (single shared target = MSS FIC_0_AXI4_S).
//
// THE FFT IS A MODEL, NOT THE IP -- STATE THIS PLAINLY.
//   `tb_corefft_model` below is a 64-point integer Walsh-Hadamard transform with the SAME port
//   list and the SAME handshake contract as CoreFFT (DATAI_VALID/BUF_READY load, READ_OUTP/
//   DATAO_VALID/OUTP_READY unload, conditional block-floating-point SCALE_EXP), and unlike
//   sim/corefft_behav.v it RE-ARMS, which is the whole point here (8 transforms per run, per
//   chain). It is NOT CoreFFT's arithmetic and makes no claim about it. That is sound for this
//   testbench's claim: CoreFFT is hard IP, both instances are the SAME COREFFT_C0 component with
//   the same parameters, and nothing in this change touches its arithmetic. What IS being proven
//   is the plumbing, the row partition, the DDR disjointness and the per-chain exponent capture.
//   A transform that mixes every input into every output (Hadamard does) and whose BFP exponent
//   is data-dependent is exactly what makes those observable.
//
// VACUOUS-TEST GUARDS (a previous A/B on this project passed because the second path inherited
// the first's buffer contents):
//   * the destination DDR region is POISONED with a run-specific pattern before every run, and
//     the run FAILS unless 100% of the destination bytes were rewritten (reported as mutation
//     coverage);
//   * every LSRAM-backed array inside BOTH feeders, BOTH unloaders and BOTH gearboxes, plus both
//     FFT models' sample arrays, is poisoned between runs -- reset does not clear LSRAM;
//   * chain B is driven with DIFFERENT source data, DIFFERENT coefficients and a DIFFERENT window
//     scalar from chain A on every group, so any cross-wire changes the answer;
//   * the per-row BFP exponent is made to VARY across rows (row amplitude sweeps 2^r), so a
//     mis-captured exponent is observable at all.
//
// MUTATIONS (run with +MUT=n; each MUST fail, and the measured failure is printed):
//   1  chain B's exponent read from chain A's feeder     (the H-2 SCALE_EXP cross-wire)
//   2  chain B writes chain A's destination row          (DDR aliasing)
//   3  chain B fed chain A's coefficients                (coefficient stream cross-wire)
//   4  exponents captured one group late                 (software-pipelined re-arm, rule (a))
//   5  chain B fed chain A's source row                  (source aliasing)
//
// Run (from mpfs/fpga/tb):
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib dcwork && $MS/vlog -work dcwork tb_fft_dual_chain.v ../fft_feeder_v.v \
//        ../fft_unloader_v.v ../corefft_stream64_adapter.v
//   $MS/vsim -c -do "run -all; quit -f" dcwork.tb_fft_dual_chain
// Expect: "==== dual-chain FFT: PASS ====" and exit without $fatal.

`timescale 1ns/1ps

// ===================================================================================
// tb_corefft_model -- CoreFFT-contract stand-in that RE-ARMS. See the header note.
// ===================================================================================
module tb_corefft_model #(parameter integer W = 16, parameter integer POINTS = 64) (
    input  wire                 CLK,
    input  wire                 SLOWCLK,
    input  wire                 NGRST,
    input  wire signed [W-1:0]  DATAI_RE,
    input  wire signed [W-1:0]  DATAI_IM,
    input  wire                 DATAI_VALID,
    input  wire                 READ_OUTP,
    output reg  signed [W-1:0]  DATAO_RE,
    output reg  signed [W-1:0]  DATAO_IM,
    output reg                  DATAO_VALID,
    output reg                  BUF_READY,
    output reg                  OUTP_READY,
    output reg  [3:0]           SCALE_EXP
);
    integer xr [0:POINTS-1], xi [0:POINTS-1];
    integer yr [0:POINTS-1], yi [0:POINTS-1];
    integer nin, nout, k, n, sh, ar, ai, mx, a;
    reg [1:0] st;
    localparam LOAD = 2'd0, OUT = 2'd1;

    // Walsh-Hadamard sign: (-1)^popcount(k & n). Every output depends on every input.
    function integer had_sign;
        input integer kk, nn;
        integer m, p;
        begin
            m = kk & nn; p = 0;
            while (m != 0) begin p = p ^ (m & 1); m = m >> 1; end
            had_sign = p ? -1 : 1;
        end
    endfunction

    always @(posedge CLK or negedge NGRST) begin
        if (!NGRST) begin
            nin <= 0; nout <= 0; st <= LOAD;
            BUF_READY <= 1'b1; OUTP_READY <= 1'b0; DATAO_VALID <= 1'b0; SCALE_EXP <= 4'd0;
            DATAO_RE <= {W{1'b0}}; DATAO_IM <= {W{1'b0}};
        end else begin
            case (st)
              LOAD: begin
                  DATAO_VALID <= 1'b0;
                  if (DATAI_VALID && BUF_READY) begin
                      xr[nin] = DATAI_RE; xi[nin] = DATAI_IM;   // already sign-extended (signed port)
                      nin = nin + 1;
                      if (nin == POINTS) begin
                          BUF_READY <= 1'b0;
                          mx = 0;
                          for (k = 0; k < POINTS; k = k + 1) begin
                              ar = 0; ai = 0;
                              for (n = 0; n < POINTS; n = n + 1) begin
                                  ar = ar + had_sign(k, n) * xr[n];
                                  ai = ai + had_sign(k, n) * xi[n];
                              end
                              yr[k] = ar; yi[k] = ai;
                              a = (ar < 0) ? -ar : ar; if (a > mx) mx = a;
                              a = (ai < 0) ? -ai : ai; if (a > mx) mx = a;
                          end
                          // conditional BFP: smallest right shift that fits signed W bits
                          sh = 0;
                          while ((mx >>> sh) > ((1 << (W-1)) - 1)) sh = sh + 1;
                          for (k = 0; k < POINTS; k = k + 1) begin
                              yr[k] = yr[k] >>> sh;             // arithmetic, matches a BFP core
                              yi[k] = yi[k] >>> sh;
                          end
                          SCALE_EXP  <= sh[3:0];
                          nout       <= 0;
                          OUTP_READY <= 1'b1;
                          st         <= OUT;
                      end
                  end
              end
              OUT: begin
                  if (READ_OUTP && nout < POINTS) begin
                      DATAO_RE    <= yr[nout];
                      DATAO_IM    <= yi[nout];
                      DATAO_VALID <= 1'b1;
                      nout = nout + 1;
                  end else begin
                      DATAO_VALID <= 1'b0;
                      if (nout == POINTS) begin                 // RE-ARM (sim/corefft_behav.v does not)
                          OUTP_READY <= 1'b0;
                          BUF_READY  <= 1'b1;
                          nin        = 0;
                          st         <= LOAD;
                      end
                  end
              end
              default: st <= LOAD;
            endcase
        end
    end
endmodule

// ===================================================================================
module tb_fft_dual_chain;

    localparam integer W        = 16;
    localparam integer POINTS   = 64;                 // CoreFFT frame
    localparam integer QN       = POINTS;             // gather outputs per row (even)
    localparam integer S        = 48;                 // source samples per row
    localparam integer NROWS    = 8;                  // rows per run (even; NROWS/2 groups)
    localparam integer ROW_BEATS= POINTS/2;           // stream beats per row = 32
    localparam integer TAB_WORDS= QN/2;               // 32 taper words (2 taps each)

    localparam [31:0] SRC_BASE = 32'h0000_1000;       // 4 KiB aligned
    localparam integer SRC_STRIDE = 256;              // bytes per source row (32 beats)
    localparam [31:0] DST_BASE = 32'h0000_8000;
    localparam integer DST_STRIDE = POINTS*4;         // 256 bytes = 32 beats

    localparam integer MEMB   = 8192;                 // 64-bit DDR beats
    localparam integer DSTB0  = DST_BASE >> 3;        // first destination beat
    localparam integer DSTBN  = (NROWS*DST_STRIDE) >> 3;  // destination beats total

    // feeder/unloader sized down for the toy frame
    localparam integer F_MAXB = 8,  F_FIFO = 5, F_TAB = 5, F_GBUF = 6, F_GTAB = 6, F_GSF = 5;
    localparam integer U_MAXB = 8,  U_FIFO = 6;

    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;                             // 100 MHz fabric clock

    integer seed = 32'h0d0a_1234;
    integer mut  = 0;                                  // +MUT=n

    // =============================== DDR ===============================
    reg [63:0] mem [0:MEMB-1];

    // ======================= AXI4-Lite control fan-out ==================
    // Four control blocks: 0 = FEED_A, 1 = UNLD_A, 2 = FEED_B, 3 = UNLD_B.
    reg  [11:0] la_addr; reg [31:0] la_data;
    reg  [3:0]  la_awv,  la_wv,  la_arv;
    reg  [11:0] lr_addr;
    wire [3:0]  la_awr,  la_wr,  la_bv,  la_arr, la_rv;
    reg         la_bready = 1'b1, la_rready = 1'b1;

    // =============================== chain A ===============================
    wire [3:0]  a_arid;  wire [31:0] a_araddr; wire [7:0] a_arlen;
    wire [2:0]  a_arsize; wire [1:0] a_arburst; wire a_arvalid; wire a_arready;
    wire [63:0] a_rdata; wire a_rlast, a_rvalid, a_rready;
    wire [63:0] a_tdata; wire a_tvalid, a_tready;
    wire signed [W-1:0] a_datai_re, a_datai_im, a_datao_re, a_datao_im;
    wire a_datai_valid, a_buf_ready, a_datao_valid, a_outp_ready, a_read_outp;
    wire [3:0] a_scale_exp;
    wire [63:0] a_mtdata; wire a_mtvalid, a_mtready, a_mtlast; wire [1:0] a_mtdest;
    wire [3:0]  a_awid;  wire [31:0] a_awaddr; wire [7:0] a_awlen;
    wire [2:0]  a_awsize; wire [1:0] a_awburst; wire a_awvalid, a_awready;
    wire [63:0] a_wdata; wire [7:0] a_wstrb; wire a_wlast, a_wvalid, a_wready;
    wire a_bvalid, a_bready;
    wire [31:0] a_lrdata; wire [31:0] au_lrdata;
    wire signed [31:0] a_cidx; wire [15:0] a_cwq; wire a_cvalid, a_cready;

    // =============================== chain B ===============================
    wire [3:0]  b_arid;  wire [31:0] b_araddr; wire [7:0] b_arlen;
    wire [2:0]  b_arsize; wire [1:0] b_arburst; wire b_arvalid; wire b_arready;
    wire [63:0] b_rdata; wire b_rlast, b_rvalid, b_rready;
    wire [63:0] b_tdata; wire b_tvalid, b_tready;
    wire signed [W-1:0] b_datai_re, b_datai_im, b_datao_re, b_datao_im;
    wire b_datai_valid, b_buf_ready, b_datao_valid, b_outp_ready, b_read_outp;
    wire [3:0] b_scale_exp;
    wire [63:0] b_mtdata; wire b_mtvalid, b_mtready, b_mtlast; wire [1:0] b_mtdest;
    wire [3:0]  b_awid;  wire [31:0] b_awaddr; wire [7:0] b_awlen;
    wire [2:0]  b_awsize; wire [1:0] b_awburst; wire b_awvalid, b_awready;
    wire [63:0] b_wdata; wire [7:0] b_wstrb; wire b_wlast, b_wvalid, b_wready;
    wire b_bvalid, b_bready;
    wire [31:0] b_lrdata; wire [31:0] bu_lrdata;
    wire signed [31:0] b_cidx; wire [15:0] b_cwq; wire b_cvalid, b_cready;

    // ===================================================================
    // CHAIN A
    // ===================================================================
    fft_feeder_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4), .MAX_BURST(F_MAXB),
                   .FIFO_AW(F_FIFO), .TAB_AW(F_TAB), .G_BUF_AW(F_GBUF), .G_TAB_AW(F_GTAB),
                   .G_SFIFO_AW(F_GSF)) FEED_A (
        .clk(clk), .resetn(resetn),
        .s_awaddr(la_addr), .s_awvalid(la_awv[0]), .s_awready(la_awr[0]),
        .s_wdata(la_data), .s_wvalid(la_wv[0]), .s_wready(la_wr[0]),
        .s_bvalid(la_bv[0]), .s_bready(la_bready),
        .s_araddr(lr_addr), .s_arvalid(la_arv[0]), .s_arready(la_arr[0]),
        .s_rdata(a_lrdata), .s_rvalid(la_rv[0]), .s_rready(la_rready),
        .m_arid(a_arid), .m_araddr(a_araddr), .m_arlen(a_arlen), .m_arsize(a_arsize),
        .m_arburst(a_arburst), .m_arvalid(a_arvalid), .m_arready(a_arready),
        .m_rid(4'd0), .m_rdata(a_rdata), .m_rlast(a_rlast), .m_rvalid(a_rvalid),
        .m_rready(a_rready),
        .m_axis_tdata(a_tdata), .m_axis_tvalid(a_tvalid), .m_axis_tready(a_tready),
        .c_idx(a_cidx), .c_wq(a_cwq), .c_valid(a_cvalid), .c_ready(a_cready),
        // ---- H-2: chain A's feeder latches chain A's CoreFFT exponent, and only that one ----
        .scale_exp_in(a_scale_exp), .outp_ready_in(a_outp_ready)
    );

    corefft_stream64_adapter #(.W(W), .POINTS(POINTS)) GBX_A (
        .clk(clk), .resetn(resetn),
        .s_axis_tdata(a_tdata), .s_axis_tvalid(a_tvalid), .s_axis_tready(a_tready),
        .datai_re(a_datai_re), .datai_im(a_datai_im), .datai_valid(a_datai_valid),
        .buf_ready(a_buf_ready),
        .datao_re(a_datao_re), .datao_im(a_datao_im), .datao_valid(a_datao_valid),
        .outp_ready(a_outp_ready), .read_outp(a_read_outp),
        .m_axis_tdata(a_mtdata), .m_axis_tvalid(a_mtvalid), .m_axis_tlast(a_mtlast),
        .m_axis_tdest(a_mtdest), .m_axis_tready(a_mtready)
    );

    tb_corefft_model #(.W(W), .POINTS(POINTS)) FFT_A (
        .CLK(clk), .SLOWCLK(clk), .NGRST(resetn),
        .DATAI_RE(a_datai_re), .DATAI_IM(a_datai_im), .DATAI_VALID(a_datai_valid),
        .READ_OUTP(a_read_outp),
        .DATAO_RE(a_datao_re), .DATAO_IM(a_datao_im), .DATAO_VALID(a_datao_valid),
        .BUF_READY(a_buf_ready), .OUTP_READY(a_outp_ready), .SCALE_EXP(a_scale_exp)
    );

    fft_unloader_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4), .MAX_BURST(U_MAXB),
                     .FIFO_AW(U_FIFO), .OUTSTAND(4)) UNLD_A (
        .clk(clk), .resetn(resetn),
        .s_awaddr(la_addr), .s_awvalid(la_awv[1]), .s_awready(la_awr[1]),
        .s_wdata(la_data), .s_wvalid(la_wv[1]), .s_wready(la_wr[1]),
        .s_bvalid(la_bv[1]), .s_bready(la_bready),
        .s_araddr(lr_addr), .s_arvalid(la_arv[1]), .s_arready(la_arr[1]),
        .s_rdata(au_lrdata), .s_rvalid(la_rv[1]), .s_rready(la_rready),
        .s_axis_tdata(a_mtdata), .s_axis_tvalid(a_mtvalid), .s_axis_tready(a_mtready),
        .m_awid(a_awid), .m_awaddr(a_awaddr), .m_awlen(a_awlen), .m_awsize(a_awsize),
        .m_awburst(a_awburst), .m_awvalid(a_awvalid), .m_awready(a_awready),
        .m_wdata(a_wdata), .m_wstrb(a_wstrb), .m_wlast(a_wlast), .m_wvalid(a_wvalid),
        .m_wready(a_wready),
        .m_bid(4'd0), .m_bresp(2'b00), .m_bvalid(a_bvalid), .m_bready(a_bready)
    );

    // ===================================================================
    // CHAIN B -- identical instantiation, B signals throughout.
    // ===================================================================
    fft_feeder_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4), .MAX_BURST(F_MAXB),
                   .FIFO_AW(F_FIFO), .TAB_AW(F_TAB), .G_BUF_AW(F_GBUF), .G_TAB_AW(F_GTAB),
                   .G_SFIFO_AW(F_GSF)) FEED_B (
        .clk(clk), .resetn(resetn),
        .s_awaddr(la_addr), .s_awvalid(la_awv[2]), .s_awready(la_awr[2]),
        .s_wdata(la_data), .s_wvalid(la_wv[2]), .s_wready(la_wr[2]),
        .s_bvalid(la_bv[2]), .s_bready(la_bready),
        .s_araddr(lr_addr), .s_arvalid(la_arv[2]), .s_arready(la_arr[2]),
        .s_rdata(b_lrdata), .s_rvalid(la_rv[2]), .s_rready(la_rready),
        .m_arid(b_arid), .m_araddr(b_araddr), .m_arlen(b_arlen), .m_arsize(b_arsize),
        .m_arburst(b_arburst), .m_arvalid(b_arvalid), .m_arready(b_arready),
        .m_rid(4'd0), .m_rdata(b_rdata), .m_rlast(b_rlast), .m_rvalid(b_rvalid),
        .m_rready(b_rready),
        .m_axis_tdata(b_tdata), .m_axis_tvalid(b_tvalid), .m_axis_tready(b_tready),
        .c_idx(b_cidx), .c_wq(b_cwq), .c_valid(b_cvalid), .c_ready(b_cready),
        // ---- H-2: chain B's feeder latches chain B's CoreFFT exponent, and only that one ----
        .scale_exp_in(b_scale_exp), .outp_ready_in(b_outp_ready)
    );

    corefft_stream64_adapter #(.W(W), .POINTS(POINTS)) GBX_B (
        .clk(clk), .resetn(resetn),
        .s_axis_tdata(b_tdata), .s_axis_tvalid(b_tvalid), .s_axis_tready(b_tready),
        .datai_re(b_datai_re), .datai_im(b_datai_im), .datai_valid(b_datai_valid),
        .buf_ready(b_buf_ready),
        .datao_re(b_datao_re), .datao_im(b_datao_im), .datao_valid(b_datao_valid),
        .outp_ready(b_outp_ready), .read_outp(b_read_outp),
        .m_axis_tdata(b_mtdata), .m_axis_tvalid(b_mtvalid), .m_axis_tlast(b_mtlast),
        .m_axis_tdest(b_mtdest), .m_axis_tready(b_mtready)
    );

    tb_corefft_model #(.W(W), .POINTS(POINTS)) FFT_B (
        .CLK(clk), .SLOWCLK(clk), .NGRST(resetn),
        .DATAI_RE(b_datai_re), .DATAI_IM(b_datai_im), .DATAI_VALID(b_datai_valid),
        .READ_OUTP(b_read_outp),
        .DATAO_RE(b_datao_re), .DATAO_IM(b_datao_im), .DATAO_VALID(b_datao_valid),
        .BUF_READY(b_buf_ready), .OUTP_READY(b_outp_ready), .SCALE_EXP(b_scale_exp)
    );

    fft_unloader_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4), .MAX_BURST(U_MAXB),
                     .FIFO_AW(U_FIFO), .OUTSTAND(4)) UNLD_B (
        .clk(clk), .resetn(resetn),
        .s_awaddr(la_addr), .s_awvalid(la_awv[3]), .s_awready(la_awr[3]),
        .s_wdata(la_data), .s_wvalid(la_wv[3]), .s_wready(la_wr[3]),
        .s_bvalid(la_bv[3]), .s_bready(la_bready),
        .s_araddr(lr_addr), .s_arvalid(la_arv[3]), .s_arready(la_arr[3]),
        .s_rdata(bu_lrdata), .s_rvalid(la_rv[3]), .s_rready(la_rready),
        .s_axis_tdata(b_mtdata), .s_axis_tvalid(b_mtvalid), .s_axis_tready(b_mtready),
        .m_awid(b_awid), .m_awaddr(b_awaddr), .m_awlen(b_awlen), .m_awsize(b_awsize),
        .m_awburst(b_awburst), .m_awvalid(b_awvalid), .m_awready(b_awready),
        .m_wdata(b_wdata), .m_wstrb(b_wstrb), .m_wlast(b_wlast), .m_wvalid(b_wvalid),
        .m_wready(b_wready),
        .m_bid(4'd0), .m_bresp(2'b00), .m_bvalid(b_bvalid), .m_bready(b_bready)
    );

    // ===================================================================
    // SHARED DDR: one read burst in flight interconnect-wide (SASD), one write burst likewise.
    // ===================================================================
    localparam R_IDLE = 1'b0, R_DATA = 1'b1;
    reg        rstate, rsel, rpri;
    reg [31:0] rbeat;
    reg [8:0]  rrem;
    reg [63:0] rdata_q; reg rvalid_q, rlast_q;
    reg        rgap;
    always @(posedge clk) rgap <= (($random(seed) % 4) == 0);      // ~25% R bubbles

    wire rgrant_a = (rstate == R_IDLE) && a_arvalid && (rpri == 1'b0 || !b_arvalid);
    wire rgrant_b = (rstate == R_IDLE) && b_arvalid && !rgrant_a;
    assign a_arready = rgrant_a;
    assign b_arready = rgrant_b;
    assign a_rvalid  = rvalid_q & (rsel == 1'b0);
    assign b_rvalid  = rvalid_q & (rsel == 1'b1);
    assign a_rdata   = rdata_q;
    assign b_rdata   = rdata_q;
    assign a_rlast   = rlast_q;
    assign b_rlast   = rlast_q;
    wire rready_sel  = rsel ? b_rready : a_rready;

    integer rburst_a = 0, rburst_b = 0, rbeats_a = 0, rbeats_b = 0;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rstate <= R_IDLE; rsel <= 1'b0; rpri <= 1'b0; rbeat <= 0; rrem <= 0;
            rvalid_q <= 1'b0; rlast_q <= 1'b0; rdata_q <= 64'd0;
        end else case (rstate)
            R_IDLE: begin
                rvalid_q <= 1'b0;
                if (rgrant_a) begin
                    rbeat <= a_araddr >> 3; rrem <= {1'b0, a_arlen} + 9'd1;
                    rsel  <= 1'b0; rpri <= 1'b1; rstate <= R_DATA;
                    rburst_a = rburst_a + 1;
                end else if (rgrant_b) begin
                    rbeat <= b_araddr >> 3; rrem <= {1'b0, b_arlen} + 9'd1;
                    rsel  <= 1'b1; rpri <= 1'b0; rstate <= R_DATA;
                    rburst_b = rburst_b + 1;
                end
            end
            R_DATA: begin
                if (rvalid_q && rready_sel) begin
                    rvalid_q <= 1'b0;
                    if (rsel) rbeats_b = rbeats_b + 1; else rbeats_a = rbeats_a + 1;
                    if (rlast_q) rstate <= R_IDLE;
                end
                if ((!rvalid_q || rready_sel) && (rrem != 9'd0) && !rgap) begin
                    rdata_q  <= mem[rbeat[12:0]];
                    rlast_q  <= (rrem == 9'd1);
                    rvalid_q <= 1'b1;
                    rbeat    <= rbeat + 1;
                    rrem     <= rrem - 9'd1;
                end
            end
        endcase
    end

    localparam WI = 2'd0, WD = 2'd1, WB = 2'd2;
    reg [1:0]  wstate;
    reg        wsel, wpri;
    reg [31:0] wbeat;
    reg [8:0]  wrem;
    reg        wgap;
    integer    wbeats = 0, wlast_bad = 0;
    always @(posedge clk) wgap <= (($random(seed) % 6) == 0);      // ~17% W bubbles

    wire wgrant_a = (wstate == WI) && a_awvalid && (wpri == 1'b0 || !b_awvalid);
    wire wgrant_b = (wstate == WI) && b_awvalid && !wgrant_a;
    assign a_awready = wgrant_a;
    assign b_awready = wgrant_b;
    assign a_wready  = (wstate == WD) && (wsel == 1'b0) && !wgap;
    assign b_wready  = (wstate == WD) && (wsel == 1'b1) && !wgap;
    assign a_bvalid  = (wstate == WB) && (wsel == 1'b0);
    assign b_bvalid  = (wstate == WB) && (wsel == 1'b1);
    wire wfire   = (wsel ? (b_wvalid & b_wready) : (a_wvalid & a_wready));
    wire [63:0] wdat  = wsel ? b_wdata : a_wdata;
    wire        wlst  = wsel ? b_wlast : a_wlast;
    wire        bfire = (wsel ? (b_bvalid & b_bready) : (a_bvalid & a_bready));

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            wstate <= WI; wsel <= 1'b0; wpri <= 1'b0; wbeat <= 0; wrem <= 0;
        end else case (wstate)
            WI: begin
                if (wgrant_a) begin
                    wbeat <= a_awaddr >> 3; wrem <= {1'b0, a_awlen} + 9'd1;
                    wsel  <= 1'b0; wpri <= 1'b1; wstate <= WD;
                end else if (wgrant_b) begin
                    wbeat <= b_awaddr >> 3; wrem <= {1'b0, b_awlen} + 9'd1;
                    wsel  <= 1'b1; wpri <= 1'b0; wstate <= WD;
                end
            end
            WD: if (wfire) begin
                mem[wbeat[12:0]] <= wdat;
                wbeats = wbeats + 1;
                wbeat <= wbeat + 1;
                wrem  <= wrem - 9'd1;
                if (wlst != (wrem == 9'd1)) wlast_bad = wlast_bad + 1;
                if (wrem == 9'd1) wstate <= WB;
            end
            WB: if (bfire) wstate <= WI;
            default: wstate <= WI;
        endcase
    end

    // ===================================================================
    // coefficient stream drivers (sar_coeffgen's contract), one per chain
    // ===================================================================
    reg  [31:0] cidx_a [0:QN-1];  reg [15:0] cwq_a [0:QN-1];
    reg  [31:0] cidx_b [0:QN-1];  reg [15:0] cwq_b [0:QN-1];
    reg         csa_en, csb_en;
    reg  [31:0] csa_idx; reg [15:0] csa_wq; reg csa_v; integer csa_i;
    reg  [31:0] csb_idx; reg [15:0] csb_wq; reg csb_v; integer csb_i;
    reg         csa_gap, csb_gap;
    always @(posedge clk) begin
        csa_gap <= (($random(seed) % 5) == 0);        // ~20% valid bubbles
        csb_gap <= (($random(seed) % 5) == 0);
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin csa_v <= 1'b0; csa_idx <= 0; csa_wq <= 0; csa_i <= 0; end
        else begin
            if (csa_v & a_cready) csa_v <= 1'b0;
            if ((~csa_v | a_cready) & csa_en & ~csa_gap & (csa_i < QN)) begin
                csa_idx <= cidx_a[csa_i]; csa_wq <= cwq_a[csa_i];
                csa_v <= 1'b1; csa_i <= csa_i + 1;
            end
        end
    end
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin csb_v <= 1'b0; csb_idx <= 0; csb_wq <= 0; csb_i <= 0; end
        else begin
            if (csb_v & b_cready) csb_v <= 1'b0;
            if ((~csb_v | b_cready) & csb_en & ~csb_gap & (csb_i < QN)) begin
                csb_idx <= cidx_b[csb_i]; csb_wq <= cwq_b[csb_i];
                csb_v <= 1'b1; csb_i <= csb_i + 1;
            end
        end
    end
    assign a_cidx  = $signed(csa_idx); assign a_cwq = csa_wq; assign a_cvalid = csa_v & csa_en;
    assign b_cidx  = $signed(csb_idx); assign b_cwq = csb_wq; assign b_cvalid = csb_v & csb_en;

    // ===================================================================
    // AXI4-Lite master (one at a time; the real CPU is one master too)
    // ===================================================================
    function lite_awready; input integer blk; begin lite_awready = la_awr[blk]; end endfunction
    function lite_arready; input integer blk; begin lite_arready = la_arr[blk]; end endfunction
    function lite_rvalid;  input integer blk; begin lite_rvalid  = la_rv[blk];  end endfunction
    function [31:0] lite_rdata; input integer blk;
        begin
            case (blk)
                0: lite_rdata = a_lrdata;
                1: lite_rdata = au_lrdata;
                2: lite_rdata = b_lrdata;
                default: lite_rdata = bu_lrdata;
            endcase
        end
    endfunction

    task lite_w(input integer blk, input [11:0] a, input [31:0] d);
    begin
        @(posedge clk);
        la_addr <= a; la_data <= d;
        la_awv  <= (4'd1 << blk); la_wv <= (4'd1 << blk);
        @(posedge clk);
        while (!lite_awready(blk)) @(posedge clk);
        la_awv <= 4'd0; la_wv <= 4'd0;
        @(posedge clk);
    end
    endtask

    task lite_r(input integer blk, input [11:0] a, output [31:0] d);
    begin
        @(posedge clk);
        lr_addr <= a; la_arv <= (4'd1 << blk);
        @(posedge clk);
        while (!lite_arready(blk)) @(posedge clk);
        la_arv <= 4'd0;
        while (!lite_rvalid(blk)) @(posedge clk);
        d = lite_rdata(blk);
        @(posedge clk);
    end
    endtask

    // ===================================================================
    // scene data
    // ===================================================================
    reg [31:0] taper [0:TAB_WORDS-1];        // {hamc[2i+1], hamc[2i]}
    reg [15:0] hamr  [0:NROWS-1];
    reg [7:0]  exp_ref [0:NROWS-1];          // single-chain reference exponents
    reg [7:0]  exp_got [0:NROWS-1];
    reg [63:0] dst_ref [0:DSTBN-1];          // single-chain reference destination image
    integer    poison_pat;

    // idx/wq for row r, chain-independent by ROW (so the same row gets the same coefficients in
    // both runs) but strongly row-dependent (so feeding the wrong row's coefficients diverges).
    task build_coeffs(input integer r, input integer which);   // which: 0 -> A arrays, 1 -> B
        integer i, ix;
        reg [15:0] wq;
    begin
        for (i = 0; i < QN; i = i + 1) begin
            // out-of-range entries at both ends -> the zero-fill path
            if (i < 2 || i >= QN-2) ix = -1;
            else                    ix = ((i * 3 + r * 7) % (S - 1));
            wq = ((i * 511 + r * 1237) % 32768);
            if (which == 0) begin cidx_a[i] = ix; cwq_a[i] = wq; end
            else            begin cidx_b[i] = ix; cwq_b[i] = wq; end
        end
    end
    endtask

    task load_scene;
        integer r, i, b;
        reg [15:0] re, im;
        reg [31:0] amp;
    begin
        for (i = 0; i < MEMB; i = i + 1) mem[i] = 64'd0;
        // Source rows: amplitude sweeps 2^7..2^14 with the row, and the samples are single-signed
        // so the transform's DC output carries the full fan-in gain. That is what makes the BFP
        // exponent VARY row to row -- with a constant exponent the whole exponent check would be
        // vacuous (a mis-captured exponent would be indistinguishable from a correct one), which
        // is exactly what an earlier revision of this testbench measured and rejected.
        for (r = 0; r < NROWS; r = r + 1) begin
            amp = (32'd1 << (7 + r));                       // 128 .. 16384
            for (i = 0; i < S; i = i + 1) begin
                re = (amp >> 1) + ((i * 37 + r * 101) % (amp >> 1));
                im = (amp >> 1) + ((i * 53 + r * 197) % (amp >> 1));
                b  = ((SRC_BASE + r*SRC_STRIDE) >> 3) + (i >> 1);
                if (i[0] == 1'b0) mem[b][31:0]  = {re, im};
                else              mem[b][63:32] = {re, im};
            end
        end
        // Taper and row scalar are kept NEAR unity (Q15 ~0.73..1.0) but not constant: the window
        // arithmetic itself is proven by tb_fft_feeder_win.v, and a heavy taper here would crush
        // the amplitude sweep the exponent check depends on.
        for (i = 0; i < TAB_WORDS; i = i + 1)
            taper[i] = {16'(24000 + ((i*173) % 8767)), 16'(24000 + ((i*331 + 7) % 8767))};
        for (r = 0; r < NROWS; r = r + 1) hamr[r] = 28000 + ((r * 601) % 4767);
    end
    endtask

    // Poison every LSRAM-backed array. Reset does NOT clear LSRAM on silicon, and the previous
    // A/B on this project passed only because the second path inherited the first's buffers.
    task poison_all(input [31:0] pat);
        integer i;
    begin
        for (i = 0; i < (1 << F_TAB);      i = i + 1) begin
            FEED_A.wtab[i]    = pat;      FEED_B.wtab[i]    = ~pat;
        end
        for (i = 0; i < (1 << F_GBUF);     i = i + 1) begin
            FEED_A.buf_e[i]   = pat;      FEED_A.buf_o[i]   = pat;
            FEED_B.buf_e[i]   = ~pat;     FEED_B.buf_o[i]   = ~pat;
        end
        for (i = 0; i < (1 << (F_GTAB-1)); i = i + 1) begin
            FEED_A.idxbuf0[i] = 32'hDEAD_BEEF; FEED_A.idxbuf1[i] = 32'hDEAD_BEEF;
            FEED_B.idxbuf0[i] = 32'hDEAD_BEEF; FEED_B.idxbuf1[i] = 32'hDEAD_BEEF;
        end
        for (i = 0; i < (1 << (F_GTAB-2)); i = i + 1) begin
            FEED_A.wqbuf0[i] = 16'h5A5A; FEED_A.wqbuf1[i] = 16'h5A5A;
            FEED_A.wqbuf2[i] = 16'h5A5A; FEED_A.wqbuf3[i] = 16'h5A5A;
            FEED_B.wqbuf0[i] = 16'h5A5A; FEED_B.wqbuf1[i] = 16'h5A5A;
            FEED_B.wqbuf2[i] = 16'h5A5A; FEED_B.wqbuf3[i] = 16'h5A5A;
        end
        for (i = 0; i < (1 << F_FIFO);  i = i + 1) begin
            FEED_A.fifo[i]  = {2{pat}};  FEED_B.fifo[i]  = {2{~pat}};
        end
        for (i = 0; i < (1 << F_GSF);   i = i + 1) begin
            FEED_A.gfifo[i] = {2{pat}};  FEED_B.gfifo[i] = {2{~pat}};
        end
        for (i = 0; i < (1 << U_FIFO);  i = i + 1) begin
            UNLD_A.fifo[i]  = {2{pat}};  UNLD_B.fifo[i]  = {2{~pat}};
        end
        for (i = 0; i < 64; i = i + 1) begin
            GBX_A.fifo[i]   = {4{pat[15:0]}}; GBX_B.fifo[i] = {4{~pat[15:0]}};
        end
        for (i = 0; i < POINTS; i = i + 1) begin
            FFT_A.xr[i] = 32'sh0BAD0BAD; FFT_A.xi[i] = 32'sh0BAD0BAD;
            FFT_A.yr[i] = 32'sh0BAD0BAD; FFT_A.yi[i] = 32'sh0BAD0BAD;
            FFT_B.xr[i] = 32'sh0BAD0BAD; FFT_B.xi[i] = 32'sh0BAD0BAD;
            FFT_B.yr[i] = 32'sh0BAD0BAD; FFT_B.yi[i] = 32'sh0BAD0BAD;
        end
    end
    endtask

    task poison_dst(input [63:0] pat);
        integer i;
    begin
        for (i = 0; i < DSTBN; i = i + 1) mem[DSTB0 + i] = pat;
    end
    endtask

    // load the along-row taper into ONE chain's feeder
    task load_taper(input integer blk);
        integer i;
    begin
        lite_w(blk, 12'h018, 32'h0002_0000);              // rewind the taper write pointer
        for (i = 0; i < TAB_WORDS; i = i + 1) lite_w(blk, 12'h01c, taper[i]);
    end
    endtask

    // Arm ONE row on ONE chain. fblk/ublk are that chain's feeder/unloader control blocks.
    // srow/drow are ROW INDICES -- the mutations perturb them at the call site.
    task arm_row(input integer fblk, input integer ublk, input integer srow, input integer drow,
                 input integer hrow);
    begin
        lite_w(ublk, 12'h018, 32'd0);                                   // DET_CTRL = 0
        lite_w(ublk, 12'h00c, DST_BASE + drow * DST_STRIDE);            // ARG0 dst
        lite_w(ublk, 12'h010, ROW_BEATS);                               // ARG1 stream beats
        lite_w(ublk, 12'h008, 32'd1);                                   // START
        lite_w(fblk, 12'h024, SRC_BASE);                                // IDX_BASE (unused: stream)
        lite_w(fblk, 12'h028, SRC_BASE);                                // WQ_BASE  (unused: stream)
        lite_w(fblk, 12'h02c, {16'(QN), 16'(S)});                       // GATHER_DIMS
        lite_w(fblk, 12'h020, 32'd3);                                   // gather + stream coeffs
        lite_w(fblk, 12'h018, {15'd0, 1'b1, hamr[hrow]});               // window on, hamr[row]
        lite_w(fblk, 12'h00c, SRC_BASE + srow * SRC_STRIDE);            // ARG0 src row
        lite_w(fblk, 12'h008, 32'd1);                                   // START
    end
    endtask

    task wait_idle(input integer blk);
        reg [31:0] st; integer guard;
    begin
        guard = 0; st = 32'd1;
        while (st[0] !== 1'b0) begin
            lite_r(blk, 12'h008, st);
            guard = guard + 1;
            if (guard > 200000) $fatal(1, "block %0d never went idle", blk);
        end
    end
    endtask

    // ===================================================================
    // runs
    // ===================================================================
    integer r, g, i, errs, mism, mutated, total;
    reg [31:0] st14;

    task run_single;
    begin
        poison_dst(64'hA5A5_A5A5_A5A5_A5A5);
        poison_all(32'h1111_1111);
        resetn = 0; repeat (6) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
        load_taper(0);
        for (r = 0; r < NROWS; r = r + 1) begin
            build_coeffs(r, 0);
            csa_i = 0; csa_en = 1'b1;
            arm_row(0, 1, r, r, r);
            wait_idle(0); wait_idle(1);
            csa_en = 1'b0;
            if (csa_i !== QN) begin
                $display("  single: row %0d consumed %0d of %0d coefficient entries", r, csa_i, QN);
                errs = errs + 1;
            end
            lite_r(0, 12'h014, st14);
            exp_ref[r] = st14[3:0];
        end
        for (i = 0; i < DSTBN; i = i + 1) dst_ref[i] = mem[DSTB0 + i];
    end
    endtask

    task run_dual;
        integer ra, rb, sb, db, hb;
    begin
        poison_dst(64'h5A5A_5A5A_5A5A_5A5A);     // DIFFERENT pattern: no run can inherit the other
        poison_all(32'h2222_2222);
        resetn = 0; repeat (6) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);
        load_taper(0); load_taper(2);
        for (g = 0; g < NROWS/2; g = g + 1) begin
            ra = 2*g; rb = 2*g + 1;
            build_coeffs(ra, 0);
            build_coeffs((mut == 3) ? ra : rb, 1);           // MUT3: chain B gets A's coefficients
            sb = (mut == 5) ? ra : rb;                        // MUT5: chain B reads A's source row
            db = (mut == 2) ? ra : rb;                        // MUT2: chain B writes A's dst row
            hb = rb;
            csa_i = 0; csb_i = 0; csa_en = 1'b1; csb_en = 1'b1;
            arm_row(0, 1, ra, ra, ra);
            arm_row(2, 3, sb, db, hb);
            wait_idle(0); wait_idle(1); wait_idle(2); wait_idle(3);
            csa_en = 1'b0; csb_en = 1'b0;
            if (csa_i !== QN || csb_i !== QN) begin
                $display("  dual: group %0d consumed A=%0d B=%0d of %0d entries", g, csa_i, csb_i, QN);
                errs = errs + 1;
            end
            // Rule (a): both exponents read HERE, after the join and before the next arm.
            lite_r(0, 12'h014, st14);
            if (mut == 4 && g > 0) exp_got[ra-2] = st14[3:0];  // MUT4: one group late
            else                   exp_got[ra]   = st14[3:0];
            lite_r((mut == 1) ? 0 : 2, 12'h014, st14);         // MUT1: read B's exp from A's feeder
            if (mut == 4 && g > 0) exp_got[rb-2] = st14[3:0];
            else                   exp_got[rb]   = st14[3:0];
        end
    end
    endtask

    initial begin
        if (!$value$plusargs("MUT=%d", mut)) mut = 0;
        la_awv = 0; la_wv = 0; la_arv = 0; la_addr = 0; la_data = 0; lr_addr = 0;
        csa_en = 0; csb_en = 0; errs = 0;
        for (i = 0; i < NROWS; i = i + 1) begin exp_ref[i] = 8'hFF; exp_got[i] = 8'hFE; end

        load_scene;
        $display("==== dual-chain FFT testbench (MUT=%0d) ====", mut);

        // ---- reference: ONE chain, rows 0..NROWS-1 sequentially ----
        run_single;
        $display("[ref ] single chain: %0d rows, %0d read bursts, %0d write beats",
                 NROWS, rburst_a, wbeats);
        $write("[ref ] exponents:");
        for (i = 0; i < NROWS; i = i + 1) $write(" %0d", exp_ref[i]);
        $display("");
        // The exponent MUST vary across rows or this whole check is vacuous.
        begin : expvar
            integer nuniq, j, k2, dup;
            nuniq = 0;
            for (j = 0; j < NROWS; j = j + 1) begin
                dup = 0;
                for (k2 = 0; k2 < j; k2 = k2 + 1) if (exp_ref[k2] === exp_ref[j]) dup = 1;
                if (!dup) nuniq = nuniq + 1;
            end
            $display("[ref ] distinct exponents across rows: %0d (must be >1 or the exp check is vacuous)",
                     nuniq);
            if (nuniq < 2) begin
                $display("==== dual-chain FFT: FAIL (exponent constant -> exponent check is vacuous) ====");
                $fatal(1, "vacuous exponent check");
            end
        end

        // ---- device under test: TWO chains, rows split even/odd ----
        run_dual;
        $display("[dual] two chains: %0d rows, read bursts A=%0d B=%0d, write beats %0d",
                 NROWS, rburst_a, rburst_b, wbeats);
        if (rburst_b == 0) begin
            $display("==== dual-chain FFT: FAIL (chain B never issued a read -- vacuous) ====");
            $fatal(1, "chain B idle");
        end

        // ---- compare ----
        mism = 0; mutated = 0; total = DSTBN;
        for (i = 0; i < DSTBN; i = i + 1) begin
            if (mem[DSTB0 + i] !== 64'h5A5A_5A5A_5A5A_5A5A) mutated = mutated + 1;
            if (mem[DSTB0 + i] !== dst_ref[i]) begin
                if (mism < 6)
                    $display("  dst beat %0d (row %0d): dual %016x  single %016x",
                             i, i / (DST_STRIDE/8), mem[DSTB0 + i], dst_ref[i]);
                mism = mism + 1;
            end
        end
        $display("[dual] destination mutation coverage: %0d/%0d beats rewritten (%0d%%)",
                 mutated, total, (mutated * 100) / total);
        if (mutated != total) begin
            $display("  POISON SURVIVED in %0d beats -- some destination beat was never written",
                     total - mutated);
            errs = errs + 1;
        end

        for (i = 0; i < NROWS; i = i + 1)
            if (exp_got[i] !== exp_ref[i]) begin
                $display("  row %0d exponent: dual %0d  single %0d", i, exp_got[i], exp_ref[i]);
                errs = errs + 1;
            end

        if (wlast_bad) begin
            $display("  %0d WLAST mismatches on the shared write channel", wlast_bad);
            errs = errs + 1;
        end
        // sticky AXI/protocol latches on all four blocks
        lite_r(0, 12'h014, st14); if (st14[18:16] !== 3'd0) begin $display("  FEED_A err %b", st14[18:16]); errs = errs + 1; end
        lite_r(2, 12'h014, st14); if (st14[18:16] !== 3'd0) begin $display("  FEED_B err %b", st14[18:16]); errs = errs + 1; end
        lite_r(1, 12'h014, st14); if (st14[5:0]   !== 6'd0) begin $display("  UNLD_A err %b", st14[5:0]);   errs = errs + 1; end
        lite_r(3, 12'h014, st14); if (st14[5:0]   !== 6'd0) begin $display("  UNLD_B err %b", st14[5:0]);   errs = errs + 1; end

        errs = errs + mism;
        $display("\n[dual] %0d mismatching destination beats of %0d", mism, total);
        if (errs) begin
            $display("==== dual-chain FFT: FAIL (%0d errors, MUT=%0d) ====", errs, mut);
            if (mut == 0) $fatal(1, "two chains are NOT byte-identical to one");
            $display("     (MUT=%0d was EXPECTED to fail -- mutation detected)", mut);
            $finish;
        end
        if (mut != 0) begin
            $display("==== dual-chain FFT: MUTATION %0d NOT DETECTED -- the check is weak ====", mut);
            $fatal(1, "undetected mutation");
        end
        $display("==== dual-chain FFT: PASS ====");
        $finish;
    end

    initial begin
        #200_000_000;
        $display("==== dual-chain FFT: FAIL (timeout -- a handshake stalled) ====");
        $fatal(1, "timeout");
    end
endmodule
