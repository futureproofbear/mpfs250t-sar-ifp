// tb_sar_coeffgen.v -- self-checking testbench for mpfs/fpga/sar_coeffgen.v
// (on-fabric azimuth resample coefficient generation).
//
// THIS TB CHECKS PAYLOAD, NOT HANDSHAKES. Every streamed {idx, wq} pair is compared, in order,
// against a bit-exact reference; the run FAILS if a single int32 index or Q15 weight differs.
// (The project's standing lesson: tb_sar_axi_idconv.v ties RDATA to zero and consequently proves
// nothing. A coefficient generator checked only on valid/ready would prove even less -- the whole
// risk here is arithmetic.)
//
// CHAIN OF EVIDENCE
//   gen_coeffgen_vectors.py -> mpfs/host/coeffgen_model.py (pure-integer model of this datapath)
//   mpfs/host/check_coeffgen_fixed.py GATE 1 proves the model's binary32 primitives are IEEE RNE
//   mpfs/host/check_coeffgen_fixed.py GATE 2 proves the model == sar_coeffs_pass2_range() (the
//     shipping float32 C) byte-for-byte on the real staged geometry, ascending AND descending.
//   -> a TB pass means RTL == integer model == float32 C reference.
//
// GEOMETRY IS REAL: tan_s / KC / KR from mpfs/host/jtag_stage_small (M=705, Mp=8192).
//
// Cases:
//   0 asc_real   real staged KC, kr>0            -- mostly out-of-range (the FFT zero pad)
//   1 desc_real  real staged KC, kr<0            -- the INVSPAN SIGN FLIP + reversed emit index
//   2 asc_dense  dense KC inside the extent      -- 4096/4096 in range, every bracket exercised
//   3 desc_dense dense KC, kr<0                  -- 4096/4096 in range, descending
//   4 stutter    dense KC with 50% m_ready gaps  -- ordering/reservation under backpressure
//   5 edges      KC lands EXACTLY on xlo and xhi -- q==xlo is IN range, q==xhi is OUT
//   6 degen_kr0  kr == 0.0f                      -- the C's degenerate line: all {-1, 0}
// Mild m_ready backpressure (~6%) runs in every case as well.
// Plus a direct fp32-primitive check on bound sar_fp32_mul / sar_fp32_add instances, because the
// geometry cases provably cannot reach every rounding corner (see gen_coeffgen_vectors.py).
//
// MUTATION CHECKS -- each was APPLIED to sar_coeffgen.v and this TB re-run, so the coverage below
// is measured, not asserted (see gen_coeffgen_vectors.py for the same list):
//   * drop the INVSPAN sign flip for kr<0    -> desc_real + desc_dense FAIL (4800 coefficients)
//   * emit `k` instead of `S-2-k` when kr<0  -> desc_real + desc_dense FAIL (4801)
//   * truncate instead of RNE in fp32_mul    -> ALL six value cases FAIL (3131)
//   * `q > xhi` instead of `q >= xhi`        -> `edges` FAILs by exactly 1 (the query on xhi)
//   * drop the fp32_add alignment sticky bit -> the geometry cases do NOT catch it; the fp32
//     primitive vectors DO. That gap is why the primitive check exists.
//   * advance the bracket BEFORE the range test -> NOT observable on a non-decreasing KC; the
//     two orderings are equivalent here. Stated, not claimed as covered.
//
// Run (vectors are gitignored -- the generator is the source of truth, regenerate first):
//   python gen_coeffgen_vectors.py
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib cgwork && $MS/vlog -work cgwork +incdir+. ../sar_coeffgen.v tb_sar_coeffgen.v
//   $MS/vsim -c -do "run -all; quit -f" cgwork.tb_sar_coeffgen
// Expected: every case "ok" and "==== sar_coeffgen: PASS (0 mismatching coefficients) ===="
`timescale 1ns/1ps
`include "cg_dims.vh"

module tb_sar_coeffgen;

    reg clk = 0, resetn = 0;
    always #5 clk = ~clk;                     // 100 MHz fabric clock

    // ---- reference data ----
    reg [31:0] tabm [0:`TAB_WORDS-1];
    reg [47:0] expm [0:`EXP_WORDS-1];
    reg [31:0] cfg  [0:`NCASES*`CFGW-1];
    reg [31:0] p1mode, p1x0, p1inv, p1tmax;   // PASS-1 (range) mode + row scalars
    reg [8*12:1] names [0:`NCASES-1];

    // ---- DUT ----
    reg  [11:0] s_awaddr; reg s_awvalid; wire s_awready;
    reg  [31:0] s_wdata;  reg s_wvalid;  wire s_wready;
    wire s_bvalid; reg s_bready = 1'b1;
    reg  [11:0] s_araddr; reg s_arvalid; wire s_arready;
    wire [31:0] s_rdata;  wire s_rvalid; reg s_rready = 1'b1;
    wire [31:0] m_idx; wire [15:0] m_wq; wire m_valid; reg m_ready;

    sar_coeffgen #(.TAN_AW(13), .KC_AW(13)) dut (
        .clk(clk), .resetn(resetn),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .m_idx(m_idx), .m_wq(m_wq), .m_valid(m_valid), .m_ready(m_ready)
    );

    // ================= AXI4-Lite driver (same idiom as tb_fft_feeder_gather.v) =================
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

    // ================= stream collector: compares EVERY entry, in order =================
    integer seed = 32'h5eed_c0f5;
    integer exp_base, ngot, nbad, nlive, ncase_bad;
    integer stutter, collect;
    reg [47:0] want;

    always @(posedge clk) begin
        if (resetn && collect && m_valid && m_ready) begin
            want = expm[exp_base + ngot];
            if ({m_idx, m_wq} !== want) begin
                if (ncase_bad < 6)
                    $display("  %0s out %0d: got idx=%0d wq=%0d  want idx=%0d wq=%0d",
                             names[curcase], ngot, $signed(m_idx), m_wq,
                             $signed(want[47:16]), want[15:0]);
                nbad = nbad + 1; ncase_bad = ncase_bad + 1;
            end else if (!want[47] && want[15:0] > 16'd64 && want[15:0] < 16'd32704) begin
                nlive = nlive + 1;                  // a genuinely interpolated (non-edge) weight
            end
            ngot = ngot + 1;
        end
        // ~6% mild backpressure everywhere; 50% in the `stutter` case
        m_ready <= stutter ? (($random(seed) % 2) != 0) : (($random(seed) % 16) != 0);
    end

    // ================= fp32 primitive check (bound instances, driven directly) =============
    // The geometry cases cannot reach every rounding corner: the only wide-alignment add in the
    // datapath is `w*32768.0f + 0.5f`, whose 1 ulp lands far below the integer truncation, so a
    // dropped alignment sticky bit is INVISIBLE end-to-end (measured). These vectors drive the
    // two primitives directly with RNE ties, wide alignments and heavy cancellation.
    reg  [31:0] fp_a, fp_b;
    wire [31:0] fp_mul_y, fp_add_y;
    reg  [31:0] fpv [0:4*`FP_VECS-1];
    integer v, fp_bad;
    sar_fp32_mul u_chk_mul (.clk(clk), .a(fp_a), .b(fp_b), .y(fp_mul_y));
    sar_fp32_add u_chk_add (.clk(clk), .a(fp_a), .b(fp_b), .y(fp_add_y));

    task check_fp_primitives;
    begin
        fp_bad = 0;
        for (v = 0; v < `FP_VECS; v = v + 1) begin
            @(posedge clk);
            fp_a = fpv[4*v + 0]; fp_b = fpv[4*v + 1];
            // sar_fp32_mul is LATENCY 3 since 2026-07-31 (a third stage split the round-add off
            // the 48-bit normalise mux to close 100 MHz timing), so mul and add are now BOTH valid
            // 3 clocks after the inputs and are checked on the same edge. The expected VALUES are
            // unchanged -- only when the bench samples them. Sampling a cycle early here produced
            // 2656 "mismatches" that had nothing to do with the coefficient datapath.
            @(posedge clk);                       // stage 1 latches
            @(posedge clk);                       // stage 2 latches
            @(posedge clk); #1;                   // mul y and add y both latched (latency 3)
            if (fp_mul_y !== fpv[4*v + 2]) begin
                if (fp_bad < 5)
                    $display("  fp32_mul(%h,%h) = %h  want %h",
                             fp_a, fp_b, fp_mul_y, fpv[4*v + 2]);
                fp_bad = fp_bad + 1;
            end
            if (fp_add_y !== fpv[4*v + 3]) begin
                if (fp_bad < 5)
                    $display("  fp32_add(%h,%h) = %h  want %h",
                             fp_a, fp_b, fp_add_y, fpv[4*v + 3]);
                fp_bad = fp_bad + 1;
            end
        end
        $display("[coeffgen] fp32 primitives: %0d vectors, %0d mismatches  %0s",
                 `FP_VECS, fp_bad, (fp_bad == 0) ? "ok" : "FAIL");
        nbad = nbad + fp_bad;
    end
    endtask

    // ================= busy-gated cycle counter (throughput, not just correctness) ==========
    integer run_cycles;
    always @(posedge clk) if (resetn && dut.busy) run_cycles = run_cycles + 1;

    integer curcase;
    integer c, i, S, QN, tab_off, exp_off, degen_exp;
    integer guard;
    reg [31:0] kr_b, rinv_b, st;

    initial begin
        $readmemh("cg_tab.hex", tabm);
        $readmemh("cg_exp.hex", expm);
        $readmemh("cg_cfg.hex", cfg);
        $readmemh("cg_fp.hex", fpv);
        `CASE_NAMES

        s_awaddr = 0; s_awvalid = 0; s_wdata = 0; s_wvalid = 0;
        s_araddr = 0; s_arvalid = 0; m_ready = 1'b1;
        nbad = 0; nlive = 0; collect = 0; stutter = 0; exp_base = 0; curcase = 0;

        repeat (8) @(posedge clk);
        resetn = 1;
        repeat (4) @(posedge clk);

        // ---- POWER-UP STATE: the bitstream must be behaviour-neutral out of reset ----------
        // Every case below writes MODE (0x020) explicitly, so none of them can observe what the
        // module does when firmware NEVER writes it -- which is the real deployment, since there
        // is no firmware knob for pass-1. That blind spot shipped: measured on silicon 2026-07-28
        // straight after power-up, MODE=0x00000001 with X0/INV/TMAX full of garbage, so the
        // generator ran pass-1 maths through a pass-2 frame and produced a wrong image.
        // coeffgen1_design.md 3 requires MODE = 0 out of reset. Check it before anything is armed.
        if (dut.p1_mode !== 1'b0) begin
            $display("  POWER-UP: p1_mode = %b, expected 0 -- bitstream is NOT behaviour-neutral",
                     dut.p1_mode);
            nbad = nbad + 1;
        end
        if (dut.p1_x0 !== 32'd0 || dut.p1_inv !== 32'd0 || dut.p1_tmax !== 32'd0) begin
            $display("  POWER-UP: pass-1 row scalars not zeroed (x0=%08x inv=%08x tmax=%08x)",
                     dut.p1_x0, dut.p1_inv, dut.p1_tmax);
            nbad = nbad + 1;
        end

        check_fp_primitives;

        for (c = 0; c < `NCASES; c = c + 1) begin
            curcase   = c;
            S         = cfg[c*`CFGW + 0];
            QN        = cfg[c*`CFGW + 1];
            kr_b      = cfg[c*`CFGW + 2];
            rinv_b    = cfg[c*`CFGW + 3];
            tab_off   = cfg[c*`CFGW + 4];
            exp_off   = cfg[c*`CFGW + 5];
            stutter   = cfg[c*`CFGW + 6];
            degen_exp = cfg[c*`CFGW + 7];
            p1mode    = cfg[c*`CFGW + 8];    // 1 = PASS-1 (range): affine, no bracket search
            p1x0      = cfg[c*`CFGW + 9];
            p1inv     = cfg[c*`CFGW + 10];
            p1tmax    = cfg[c*`CFGW + 11];

            // ---- one-time-per-scene table load (rewind, then push tan_s / inv_tan / KC) ----
            lite_w(12'h000, 32'h0000_000E);                       // rewind all three pointers
            for (i = 0; i < S;     i = i + 1) lite_w(12'h010, tabm[tab_off + i]);
            for (i = 0; i < S - 1; i = i + 1) lite_w(12'h014, tabm[tab_off + S + i]);
            for (i = 0; i < QN;    i = i + 1) lite_w(12'h018, tabm[tab_off + S + (S-1) + i]);

            // ---- per-row arm ----
            lite_w(12'h00c, ((QN & 32'h3FFF) << 16) | (S & 32'h3FFF));  // 14-bit fields: QN can be 8192
            lite_w(12'h004, kr_b);
            lite_w(12'h008, rinv_b);
            // PASS-1 scalars. Written for EVERY case -- pass-2 cases set mode 0 and the generator
            // ignores x0/inv/tmax, so this also proves they cannot leak into the pass-2 datapath.
            lite_w(12'h020, p1mode);
            lite_w(12'h024, p1x0);
            lite_w(12'h028, p1inv);
            lite_w(12'h02c, p1tmax);

            exp_base = exp_off; ngot = 0; ncase_bad = 0; run_cycles = 0;
            collect = 1;
            lite_w(12'h000, 32'h0000_0001);                       // START

            guard = 0;
            while (ngot < QN) begin
                @(posedge clk);
                guard = guard + 1;
                if (guard > 4000000) begin
                    $display("  %0s: TIMEOUT after %0d outputs of %0d", names[c], ngot, QN);
                    nbad = nbad + 1; ncase_bad = ncase_bad + 1;
                    ngot = QN;
                end
            end
            // the stream must STOP at exactly QN entries -- an over-run is a real bug
            repeat (64) @(posedge clk);
            collect = 0;
            if (ngot != QN) begin
                $display("  %0s: emitted %0d entries, expected exactly %0d", names[c], ngot, QN);
                nbad = nbad + 1; ncase_bad = ncase_bad + 1;
            end

            // ---- busy must clear, and the status register must agree ----
            guard = 0; st = 32'd1;
            while (st[0] !== 1'b0) begin
                lite_r(12'h01c, st);
                guard = guard + 1;
                if (guard > 20000) $fatal(1, "busy never cleared");
            end
            if (st[1] !== 1'b0) begin
                $display("  %0s: err_fmt latched (NaN/Inf/denormal operand)", names[c]);
                nbad = nbad + 1; ncase_bad = ncase_bad + 1;
            end
            if (st[2] !== 1'b0) begin
                $display("  %0s: err_dims latched (tables short / bad S,QN)", names[c]);
                nbad = nbad + 1; ncase_bad = ncase_bad + 1;
            end
            if (st[3] !== degen_exp[0]) begin
                $display("  %0s: degenerate flag %0d, expected %0d", names[c], st[3], degen_exp);
                nbad = nbad + 1; ncase_bad = ncase_bad + 1;
            end
            if (st[29:16] !== QN[13:0]) begin
                $display("  %0s: status emitted=%0d, expected %0d", names[c], st[29:16], QN);
                nbad = nbad + 1; ncase_bad = ncase_bad + 1;
            end

            $display("[coeffgen] case %0s QN=%0d  %0d cycles (%0.2f cyc/output)  %0s",
                     names[c], QN, run_cycles, run_cycles * 1.0 / QN,
                     (ncase_bad == 0) ? "ok" : "FAIL");
        end

        // A TB that passes without checking payload proves nothing. `nlive` counts entries whose
        // reference weight is genuinely interpolated (in range, not clamped near 0 or 32767), so
        // this asserts the run actually exercised the arithmetic and not just the zero-pad path.
        $display("");
        $display("checked %0d non-trivial interpolated weights", nlive);
        if (nlive < 5000) begin
            $display("==== sar_coeffgen: FAIL (hollow run -- only %0d live weights) ====", nlive);
            $finish;
        end
        if (nbad == 0)
            $display("==== sar_coeffgen: PASS (0 mismatching coefficients) ====");
        else
            $display("==== sar_coeffgen: FAIL (%0d mismatching coefficients) ====", nbad);
        $finish;
    end
endmodule
