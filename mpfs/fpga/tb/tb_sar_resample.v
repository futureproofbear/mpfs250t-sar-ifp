// tb_sar_resample.v -- self-checking testbench for the FUSED coefficient-generation + gather
// kernel in sar_resample_v.v.
//
// It proves the fabric kernel reproduces, VALUE FOR VALUE, the contract in that file's header:
//     out[i] = in[idx[i]] + (in[idx[i]+1]-in[idx[i]]) * wq[i]/32768 ; idx=-1 -> zero fill
// with idx/wq generated on chip from the affine map of a fixed query table. Reference vectors
// come from gen_resample_vectors.py, which implements the DOCUMENTED fixed-point spec (not the
// RTL structure) in exact Python integers.
//
// Value-level diffing is not a style choice here. The CPU bug this kernel replaces was a missing
// sign flip on the hoisted reciprocal (sar_resample_coeffs.c's `rr = asc ? r : -r`), which makes
// every weight on a descending line negative. A sign-flipped weight still produces a smooth,
// plausible image, so correlation/magnitude checks pass on it. Cases 5 and 6 below (kr<0) are
// the ones that would have caught it; they check actual complex sample values.
//
// Cases (each reproduces a failure that has happened here or was identified as reachable):
//   0 m0-asc         MODE=0, dx>0                      + idx=-1 zero fill at BOTH ends
//   1 m0-desc-odd    MODE=0, dx<0 (A negative)         + the odd IN_BASE 32-bit word pass 1 has
//   2 m1-pos-fine    MODE=1, kr>0, <=1 bracket advance per query
//   3 m1-pos-coarse  MODE=1, kr>0, 2-3 advances per query (back-to-back merge-scan advances)
//   4 m1-neg-fine    MODE=1, kr<0, descending source, single advance
//   5 m1-neg-coarse  MODE=1, kr<0, descending source, back-to-back advances
//   6 m0-stray-R     one extra R beat injected after a burst: STATUS2[0] must latch AND the
//                    line must NOT shift by a sample (the hazard the feeder red-team found)
//   7 m0-affine-sat  affine result overflows 48 bits: STATUS2[4] must latch and the sample must
//                    zero fill rather than wrap to a plausible in-range index
// Random R-channel gaps and W-channel backpressure run throughout, on every case.
//
// KNOWN DUT DEFECTS this bench currently reports (2026-07-21, first run of this bench against
// sar_resample_v.v as committed). A RED run is the expected result until they are fixed; each is
// a value-level diff, not a heuristic:
//   D1 elaboration: TAB_AW < IDX_W(14) is a negative replication multiplier at lines 470/476, so
//      the module does not elaborate at its OWN default TAB_AW=13 (vsim-8607). vlog passes.
//   D2 sign extension: p_sum (line 372) zero-extends the low partial product with
//      {{15{1'b0}}, pL}. pL is signed, so every query whose table entry is NEGATIVE gets
//      v off by +2^49>>SH. Reproduced exactly in Python: case 1 wq +1024 (SH=30),
//      case 2 v +2^22 (SH=27). Sign-sensitive fixed point -- the class this project has been
//      bitten by before.
//   D3 merge scan: ts_q lags ts_addr by one cycle, so the k+2/k+1 speculation is only valid for
//      the FIRST advance of a run. On back-to-back advances ts_k/ts_k1 go stale, idx over-advances
//      by one and wq clamps to 32767. Cases 3/5 (coarse) fail, cases 2/4 (fine) do not -- that
//      split is what isolates it.
//   D4 gather output: g_out is combinational from the STAGE-3 registers (ah2/mh) but is qualified
//      and pushed with g4_v/g4_val, one cycle later. Every output word is the NEXT coefficient's
//      lerp masked by the PREVIOUS coefficient's valid bit; the first result is dropped and the
//      whole line shifts by one query. A one-sample shift is invisible to a correlation check.
//   D5 deadlock: bresp_left is incremented (AW handshake) and decremented (B handshake) by two
//      nonblocking assignments in the same always block, so a B that lands in the same cycle as
//      an AW loses the decrement and `busy` never clears. Hit 4 of 8 cases here; the bench
//      recovers with a reset and keeps going rather than hanging the run.
//
// The bench itself is validated: with D2/D3/D4/D5 patched in a throwaway copy of the DUT, all 8
// cases report 32/32 words ok and PASS, so the reference vectors are not the thing that is wrong.
//
// COVERAGE LIMITS, measured -- do not assume otherwise:
//  1. SH=44 IS NOT TESTED, because it is arithmetically unreachable for this datapath. QTAB and
//     A are both int32 so |QTAB*A| <= 2^62, while MODE=0 needs QTAB*A = t*2^(SH+24): at SH=44
//     every query would land in bracket 0 (t <= 2^-6). The generator asserts A fits in int32 and
//     backs off to the largest feasible SH (30 for MODE=0, 25-27 for MODE=1). Widening the
//     product is an RTL change, not a table rescale -- flagged to the architectural-critic.
//  2. err_sat proves the LATCH and the zero fill, not that a wrapped v is caught before it looks
//     plausible: with a 48-bit accumulator and a 32-bit table, any single-add overflow wraps to
//     |v| ~ 2^47, which is outside every in-range window this design can configure. The bit is
//     belt-and-braces at these widths.
//  3. err_rlast (STATUS2[1]) and err_bresp (STATUS2[2]) are never provoked -- the mock slaves are
//     protocol-correct. They are checked only for being CLEAR.
//  4. The r_len/w_len "clamp to >= 1" guards are unreachable from an 8-byte-aligned address, as
//     the RTL comment says; nothing here covers them.
//
// Run (vectors are gitignored -- regenerate first, the generator is the source of truth):
//   python gen_resample_vectors.py
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib work && $MS/vlog -work work +incdir+. tb_sar_resample.v ../sar_resample_v.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_sar_resample
// Expected: 8 cases "ok" and "==== fused resample gather: PASS (0 mismatching words) ===="
`timescale 1ns/1ps
`include "rs_dims.vh"

module tb_sar_resample;

    localparam integer AXI_ADDR_W = 32;
    localparam integer AXI_DATA_W = 64;
    localparam integer AXI_ID_W   = 4;
    localparam integer MAX_BURST  = 4;    // small, so every line is several bursts
    // TAB_AW=14 is FORCED, not chosen: sar_resample_v.v zero-extends the 14-bit `k` with
    // {{(TAB_AW-IDX_W){1'b0}}, k} (lines 470/476), so any TAB_AW < IDX_W=14 -- INCLUDING the
    // module's own default of 13 -- is a negative replication multiplier and fails to elaborate
    // (vsim-8607). Only the first `MAXTAB entries of each table are loaded here.
    localparam integer TAB_AW     = 14;
    localparam integer BUF_AW     = 6;    // 64 per bank x2 = 128 source samples (SN <= 64)
    localparam integer WF_AW      = 4;    // 16-beat write FIFO, WF_CAP=8 > MAX_BURST -> wf_full
                                          // is actually reached, so `gen` backpressure is live

    reg clk = 0, resetn = 0;
    always #8 clk = ~clk;                 // 62.5 MHz, the fabric clock

    // ---- reference data (all declared before first use; ModelSim will not hoist) ----
    reg [63:0] mem [0:`MEM_BEATS-1];                  // DDR image: source lines + output regions
    reg [31:0] tab [0:(`NCASES*4*`MAXTAB)-1];
    reg [31:0] cfg [0:(`NCASES*`CFGW)-1];
    reg [31:0] exp [0:(`NCASES*`MAXQ)-1];
    reg [31:0] eidx[0:(`NCASES*`MAXQ)-1];
    reg [31:0] ewq [0:(`NCASES*`MAXQ)-1];
    reg [8*16-1:0] names [0:`NCASES-1];

    // ---- DUT wires ----
    reg  [11:0] s_awaddr; reg s_awvalid; wire s_awready;
    reg  [31:0] s_wdata;  reg s_wvalid;  wire s_wready;
    wire s_bvalid; reg s_bready = 1'b1;
    reg  [11:0] s_araddr; reg s_arvalid; wire s_arready;
    wire [31:0] s_rdata;  wire s_rvalid; reg s_rready = 1'b1;

    wire [AXI_ID_W-1:0]   m_arid;   wire [AXI_ADDR_W-1:0] m_araddr; wire [7:0] m_arlen;
    wire [2:0]            m_arsize; wire [1:0] m_arburst; wire m_arvalid; reg m_arready;
    reg  [AXI_DATA_W-1:0] m_rdata;  reg m_rlast; reg m_rvalid; wire m_rready;

    wire [AXI_ID_W-1:0]   m_awid;   wire [AXI_ADDR_W-1:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0]            m_awsize; wire [1:0] m_awburst; wire m_awvalid; reg m_awready;
    wire [AXI_DATA_W-1:0] m_wdata;  wire [(AXI_DATA_W/8)-1:0] m_wstrb;
    wire                  m_wlast;  wire m_wvalid; reg m_wready;
    reg  [1:0]            m_bresp;  reg m_bvalid; wire m_bready;

    sar_resample_v #(.AXI_ADDR_W(AXI_ADDR_W), .AXI_DATA_W(AXI_DATA_W), .AXI_ID_W(AXI_ID_W),
                     .MAX_BURST(MAX_BURST), .TAB_AW(TAB_AW), .BUF_AW(BUF_AW), .WF_AW(WF_AW)) dut (
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

    integer seed = 32'h5eed_9a31;
    reg     hung;                    // set by wait_done when busy never clears
    integer total_errors;
    integer proto_errors;

    // ================= mock AXI4 read slave (random R gaps + stray-beat injection) =========
    // s_cnt counts beats CONSUMED (rvalid & rready), never beats merely PRESENTED. Conflating
    // the two replays a beat around every idle bubble and looks exactly like a DUT off-by-one.
    localparam SL_IDLE = 2'd0, SL_DATA = 2'd1, SL_STRAY = 2'd2;
    reg [1:0]  sl_state;
    reg [31:0] s_baddr;
    integer    s_cnt, s_tot;
    reg        rnd_r;
    reg        inject_arm;         // set by the test for the stray-beat case
    reg        inject_done;
    always @(posedge clk) rnd_r <= (($random(seed) % 4) != 0);      // ~25% idle R beats

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_arready <= 1'b1; m_rvalid <= 1'b0; m_rlast <= 1'b0;
            sl_state <= SL_IDLE; s_cnt <= 0; s_tot <= 0; s_baddr <= 0; inject_done <= 1'b0;
        end else case (sl_state)
            SL_IDLE: begin
                m_rvalid <= 1'b0; m_rlast <= 1'b0;
                if (m_arvalid && m_arready) begin
                    s_baddr   <= m_araddr >> 3;
                    s_tot     <= m_arlen + 1;
                    s_cnt     <= 0;
                    m_arready <= 1'b0;
                    sl_state  <= SL_DATA;
                end
            end
            SL_DATA: begin
                if (m_rvalid && m_rready) begin                     // beat consumed
                    if (m_rlast) begin
                        m_rvalid <= 1'b0; m_rlast <= 1'b0;
                        if (inject_arm && !inject_done) begin
                            // one EXTRA beat, outside any burst we were asked for. The DUT is in
                            // R_ADDR now, so beat_ok is false: it must latch err_extra and must
                            // NOT store the beat (storing it shifts the rest of the line).
                            m_rdata     <= 64'hbadd_beef_badd_beef;
                            m_rvalid    <= 1'b1;
                            inject_done <= 1'b1;
                            sl_state    <= SL_STRAY;
                        end else begin
                            m_arready <= 1'b1; sl_state <= SL_IDLE;
                        end
                    end else begin
                        s_cnt <= s_cnt + 1;
                        if (rnd_r) begin
                            m_rdata  <= mem[s_baddr + s_cnt + 1];
                            m_rlast  <= ((s_cnt + 1) == s_tot - 1);
                            m_rvalid <= 1'b1;
                        end else m_rvalid <= 1'b0;
                    end
                end else if (!m_rvalid) begin                        // idle -> maybe present next
                    if (rnd_r) begin
                        m_rdata  <= mem[s_baddr + s_cnt];
                        m_rlast  <= (s_cnt == s_tot - 1);
                        m_rvalid <= 1'b1;
                    end
                end
                // m_rvalid && !m_rready: hold data/valid stable, as AXI requires
            end
            SL_STRAY: begin
                if (m_rvalid && m_rready) begin
                    m_rvalid  <= 1'b0;
                    m_arready <= 1'b1;
                    sl_state  <= SL_IDLE;
                end
            end
        endcase
    end

    // ================= mock AXI4 write slave (random backpressure) =========================
    reg [31:0] w_baddr;              // beat address of the next W beat
    integer    w_rem;                // beats still expected in this burst
    reg        w_active;
    integer    n_aw, n_b;            // AW accepted vs B returned, for the deadlock diagnostic
    integer    pend_b;               // bursts awaiting a B response
    integer    pb;                   // blocking accumulator for pend_b -- a burst ending in the
                                     // same cycle a B is issued must not lose its increment
    reg [31:0] w_lo, w_hi;           // legal byte window for the case in flight
    reg        rnd_w, rnd_aw, rnd_b;
    always @(posedge clk) begin
        rnd_w  <= (($random(seed) % 4) != 0);       // ~25% WREADY backpressure
        rnd_aw <= (($random(seed) % 3) != 0);
        rnd_b  <= (($random(seed) % 3) != 0);
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_awready <= 1'b0; m_wready <= 1'b0; m_bvalid <= 1'b0; m_bresp <= 2'b00;
            w_active <= 1'b0; w_baddr <= 0; w_rem <= 0; pend_b <= 0; n_aw <= 0; n_b <= 0;
        end else begin
            pb = pend_b;
            m_awready <= ~w_active & rnd_aw & ~(m_awvalid & m_awready);
            m_wready  <= w_active & rnd_w;
            m_bvalid  <= 1'b0;
            if (m_awvalid && m_awready) begin
                if (m_awaddr < w_lo || (m_awaddr + ((m_awlen + 1) << 3)) > w_hi) begin
                    $display("  PROTO FAIL: AW addr %08x len %0d outside the case window %08x..%08x",
                             m_awaddr, m_awlen, w_lo, w_hi);
                    proto_errors = proto_errors + 1;
                end
                n_aw     <= n_aw + 1;
                w_baddr  <= m_awaddr >> 3;
                w_rem    <= m_awlen + 1;
                w_active <= 1'b1;
                m_awready<= 1'b0;
            end
            if (m_wvalid && m_wready) begin
                if (!w_active) begin
                    $display("  PROTO FAIL: W beat with no outstanding AW");
                    proto_errors = proto_errors + 1;
                end
                if (m_wlast !== (w_rem == 1)) begin
                    $display("  PROTO FAIL: WLAST=%b at beat %0d of the burst", m_wlast, w_rem);
                    proto_errors = proto_errors + 1;
                end
                mem[w_baddr] <= m_wdata;
                w_baddr <= w_baddr + 1;
                w_rem   <= w_rem - 1;
                if (w_rem == 1) begin
                    w_active <= 1'b0;
                    pb = pb + 1;
                end
            end
            if (pb != 0 && rnd_b && !m_bvalid) begin
                m_bvalid <= 1'b1;                    // OKAY; m_bready is tied high in the DUT
                m_bresp  <= 2'b00;
                n_b      <= n_b + 1;
                pb = pb - 1;
            end
            pend_b <= pb;
        end
    end

    // ================= AXI4-Lite access =================
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

    // Reset between cases: every case is independent, so STATUS2 is per-case (not cumulative)
    // and a case that deadlocks can be recovered from instead of hiding every case after it.
    // The table RAMs keep their contents across reset (as they do in LSRAM); they are reloaded
    // per case anyway.
    task do_reset;
    begin
        resetn = 1'b0;
        repeat (6) @(posedge clk);
        resetn = 1'b1;
        repeat (4) @(posedge clk);
    end
    endtask

    // busy poll with a guard: a stalled handshake must FAIL LOUDLY, not hang the run
    task wait_done;
        reg [31:0] st;
        integer guard;
    begin
        hung  = 1'b0;
        guard = 0;
        st = 32'd1;
        while (st[0] !== 1'b0 && !hung) begin
            lite_r(12'h008, st);
            guard = guard + 1;
            if (guard > 4000) begin
                hung = 1'b1;
                $display("  TIMEOUT: busy stuck state=%0d rstate=%0d wstate=%0d emit=%0d gl=%0d",
                         dut.state, dut.rstate, dut.wstate, dut.emit_cnt, dut.g_left);
                $display("           drain=%b wrdone=%b bresp=%0d wf=%0d wsv=%b gw=%b gv=%b%b%b%b%b k=%0d ql=%0d",
                         dut.gather_drained, dut.wr_done, dut.bresp_left, dut.wf_cnt, dut.wsv,
                         dut.g_word_v, dut.g0_v, dut.g1_v, dut.g2_v, dut.g3_v, dut.g4_v,
                         dut.k, dut.q_left);
                $display("           slave: AW accepted=%0d  B returned=%0d  pend_b=%0d",
                         n_aw, n_b, pend_b);
            end
        end
    end
    endtask

    // ================= test =================
    integer c, k, i, errors, ci, nhung;
    integer beat_i, half;
    reg [1:0] sel;
    reg [31:0] st2, got, want;
    reg [31:0] qn, sn, md, shv, fshv;

    initial begin
        $readmemh("rs_mem.hex", mem);
        $readmemh("rs_tab.hex", tab);
        $readmemh("rs_cfg.hex", cfg);
        $readmemh("rs_exp.hex", exp);
        $readmemh("rs_idx.hex", eidx);
        $readmemh("rs_wq.hex",  ewq);
        `CASE_NAMES

        s_awvalid = 0; s_wvalid = 0; s_arvalid = 0; s_awaddr = 0; s_wdata = 0; s_araddr = 0;
        inject_arm = 0; total_errors = 0; proto_errors = 0; nhung = 0; hung = 0;
        w_lo = 0; w_hi = 32'hffff_ffff;
        repeat (8) @(posedge clk);

        for (c = 0; c < `NCASES; c = c + 1) begin
            do_reset;
            ci    = c * `CFGW;
            md    = cfg[ci + 0];
            qn    = cfg[ci + 1];
            sn    = cfg[ci + 2];
            shv   = cfg[ci + 3];
            fshv  = cfg[ci + 4];
            w_lo  = cfg[ci + 9];
            w_hi  = cfg[ci + 9] + (qn << 2);

            // ---- on-chip tables: query table always, TS/INV only for the merge scan ----
            sel  = md ? 2'd1 : 2'd0;
            lite_w(12'h02c, {29'd0, 1'b1, sel});                    // select + rewind pointer
            for (k = 0; k < qn; k = k + 1)
                lite_w(12'h030, tab[(c*4 + sel)*`MAXTAB + k]);
            if (md) begin
                lite_w(12'h02c, {29'd0, 1'b1, 2'd2});
                for (k = 0; k < sn; k = k + 1)
                    lite_w(12'h030, tab[(c*4 + 2)*`MAXTAB + k]);
                lite_w(12'h02c, {29'd0, 1'b1, 2'd3});
                for (k = 0; k < sn; k = k + 1)
                    lite_w(12'h030, tab[(c*4 + 3)*`MAXTAB + k]);
            end

            // ---- per-line scalars ----
            lite_w(12'h018, {sn[15:0], qn[15:0]});                  // DIMS
            lite_w(12'h01c, {15'd0, md[0], 2'd0, fshv[5:0], 2'd0, shv[5:0]});  // LCFG
            lite_w(12'h020, cfg[ci + 5]);                           // COEF_A
            lite_w(12'h024, cfg[ci + 6]);                           // COEF_BLO
            lite_w(12'h028, cfg[ci + 7]);                           // COEF_BHI
            lite_w(12'h00c, cfg[ci + 8]);                           // IN_BASE
            lite_w(12'h010, cfg[ci + 9]);                           // OUT_BASE

            inject_arm = cfg[ci + 10][0];

            lite_w(12'h008, 32'd1);                                 // START
            wait_done;
            inject_arm = 0;

            // ---- value-level diff, word for word ----
            errors = 0;
            if (hung) begin
                nhung  = nhung + 1;
                errors = errors + 1;
            end
            for (i = 0; i < qn; i = i + 1) begin
                beat_i = (cfg[ci + 9] >> 3) + (i >> 1);
                half   = i & 1;
                got    = half ? mem[beat_i][63:32] : mem[beat_i][31:0];
                want   = exp[c*`MAXQ + i];
                if (got !== want) begin
                    if (errors < 6)
                        $display("  %0s [%0d]: got %08x want %08x   (expected idx=%0d wq=%0d)",
                                 names[c], i, got, want, $signed(eidx[c*`MAXQ + i]),
                                 ewq[c*`MAXQ + i]);
                    errors = errors + 1;
                end
            end
            // nothing may be written past the line
            for (i = qn; i < qn + 8; i = i + 1) begin
                beat_i = (cfg[ci + 9] >> 3) + (i >> 1);
                half   = i & 1;
                got    = half ? mem[beat_i][63:32] : mem[beat_i][31:0];
                if (got !== `OUT_POISON) begin
                    $display("  %0s: wrote past the line at word %0d (%08x)", names[c], i, got);
                    errors = errors + 1;
                end
            end

            // ---- diagnostics: +rsdump decodes the on-chip coefficient RAM against the
            //      reference, which separates a coefficient-engine bug from a gather bug ----
            if (errors && $test$plusargs("rsdump")) begin
                for (i = 0; i < qn; i = i + 1) begin
                    beat_i = (cfg[ci + 9] >> 3) + (i >> 1);
                    half   = i & 1;
                    got    = half ? mem[beat_i][63:32] : mem[beat_i][31:0];
                    $display("   dump %0d: out %08x/%08x cf(v=%b idx=%0d wq=%0d) ref(idx=%0d wq=%0d)",
                             i, got, exp[c*`MAXQ + i],
                             dut.cf_mem[i][29], dut.cf_mem[i][28:15], dut.cf_mem[i][14:0],
                             $signed(eidx[c*`MAXQ + i]), ewq[c*`MAXQ + i]);
                end
            end

            // ---- sticky error latches ----
            lite_r(12'h014, st2);
            if (st2 !== cfg[ci + 11]) begin
                $display("  %0s: STATUS2 = %02x, expected %02x [0=extra 1=rlast 2=bresp 3=align 4=sat]",
                         names[c], st2, cfg[ci + 11]);
                errors = errors + 1;
            end

            $display("[case %0d] %0s mode%0d SN=%0d QN=%0d SH=%0d : %0d/%0d words %0s%0s",
                     c, names[c], md, sn, qn, shv, qn - (errors > qn ? qn : errors), qn,
                     errors ? "FAIL" : "ok", hung ? "  (DEADLOCK, recovered by reset)" : "");
            total_errors = total_errors + errors;
        end

        if (proto_errors)
            $display("  %0d AXI protocol violations observed by the mock slaves", proto_errors);
        if (nhung)
            $display("  %0d case(s) DEADLOCKED: busy never cleared", nhung);
        $display("\n==== fused resample gather: %0s (%0d mismatching words, %0d proto errors) ====",
                 (total_errors + proto_errors) ? "FAIL" : "PASS", total_errors, proto_errors);
        if (total_errors + proto_errors)
            $fatal(1, "sar_resample_v does not match the documented coefficient/gather contract");
        $finish;
    end

    // watchdog -- a stalled handshake must fail loudly, not hang the build
    initial begin
        #10_000_000;
        $display("==== fused resample gather: FAIL (timeout -- handshake stalled) ====");
        $fatal(1, "timeout");
    end
endmodule
