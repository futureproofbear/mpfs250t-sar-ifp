// tb_sar_sinc32.v -- value-level bench for sar_sinc32_gather.
//
// Checks BOTH halves of the contract:
//   * full-tap requests must produce the value gen_resample_vectors.gather_sinc() computes,
//     bit for bit
//   * EDGE requests must produce NOTHING. The core is not allowed to emit a plausible-looking
//     value there; the caller supplies the 2-tap lerp. A values-only bench would pass a core
//     that quietly answered edge requests with garbage, so silence is asserted explicitly.
//
// PARAMETERS ARE NOT OVERRIDDEN. The DUT is instantiated at its own defaults, i.e. exactly what
// synthesis builds. That is the rule tb/check_tb_params.py enforces after a bench validated a
// different parameterisation than the bitstream and cost a full board bring-up (2026-07-29).
`default_nettype none
`timescale 1ns/1ps
`include "s32_dims.vh"

module tb_sar_sinc32;
    localparam integer TAPS   = `S32_TAPS;
    localparam integer PHASES = `S32_PHASES;
    localparam integer N      = `S32_N;
    localparam integer NREQ   = `S32_NREQ;
    localparam integer NEXP   = `S32_NEXP;

    reg clk = 1'b0, resetn = 1'b0;
    always #5 clk = ~clk;                       // 100 MHz, the fabric domain

    reg  [15:0] coef [0:PHASES*TAPS-1];
    reg  [31:0] src  [0:N-1];
    reg  [31:0] req  [0:NREQ-1];
    reg  [31:0] exp  [0:NEXP-1];

    reg               ct_we = 1'b0, ct_rewind = 1'b0;
    reg signed [15:0] ct_data = 16'sd0;
    reg               sw_we = 1'b0;
    reg  [13:0]       sw_idx = 14'd0;
    reg  [31:0]       sw_data = 32'd0;
    reg               g_v = 1'b0, g_edge = 1'b0;
    reg               en = 1'b1;   // pipeline enable / backpressure
    reg  [13:0]       g_idx = 14'd0;
    reg  [14:0]       g_wq = 15'd0;
    wire              o_v;
    wire [31:0]       o_data;

    sar_sinc32_gather dut (
        .clk(clk), .resetn(resetn),
        .ct_we(ct_we), .ct_data(ct_data), .ct_rewind(ct_rewind),
        .sw_we(sw_we), .sw_idx(sw_idx), .sw_data(sw_data),
        .en(en), .g_v(g_v), .g_idx(g_idx), .g_wq(g_wq), .g_edge(g_edge),
        .o_v(o_v), .o_data(o_data)
    );

    // ---- collect outputs in order; the core emits one per accepted request, LAT cycles later ----
    integer got_n = 0, errors = 0, shown = 0;
    reg [31:0] got [0:NEXP+64];
    always @(posedge clk) begin
        if (resetn && en && o_v) begin
            if (got_n <= NEXP + 64) got[got_n] = o_data;
            got_n = got_n + 1;
        end
    end


    // ---- DIAGNOSTIC: what the DUT actually used, per accepted request ----
    // v1 is asserted once per accepted (non-edge) request, in order, so the k-th v1 pairs with
    // the k-th output. Snapshot the rotation and phase it committed to, plus the 32 bank words
    // it will multiply, so a mismatch can be attributed to ADDRESSING or to COEFFICIENTS rather
    // than inferred from the output value.
    integer v1_n = 0, dumpsel = -1, fh2, pt;
    integer do_stall = 0, stall_cyc = 0;
    reg [7:0]  used_ph  [0:NEXP+8];
    reg [5:0]  used_rot [0:NEXP+8];
    always @(posedge clk) begin
        if (resetn && !en) stall_cyc = stall_cyc + 1;
        if (resetn && en && dut.v1) begin
            if (v1_n <= NEXP) begin
                used_ph[v1_n]  = dut.ph1;
                used_rot[v1_n] = dut.rot1;
            end
            if (v1_n == dumpsel) begin
                $fwrite(fh2, "sel %0d rot %0d ph %0d\n", v1_n, dut.rot1, dut.ph1);
                for (pt = 0; pt < TAPS; pt = pt + 1)
                    $fwrite(fh2, "sq %0d %08x\n", pt, dut.sq[pt]);
                for (pt = 0; pt < TAPS; pt = pt + 1)
                    $fwrite(fh2, "ct %0d %0d\n", pt, $signed(dut.ctab[pt][dut.ph1]));
            end
            v1_n = v1_n + 1;
        end
    end

    integer i, p, t, k, nedge;
    initial begin
        fh2 = $fopen("s32_probe.txt", "w");
        if ($test$plusargs("STALL")) begin do_stall = 1; $display("  RANDOM STALLS enabled"); end
        if ($value$plusargs("SEL=%d", dumpsel)) $display("  probing accepted request %0d", dumpsel);
        $readmemh("s32_coef.hex", coef);
        $readmemh("s32_src.hex",  src);
        $readmemh("s32_req.hex",  req);
        $readmemh("s32_exp.hex",  exp);

        repeat (4) @(posedge clk);
        resetn = 1'b1;
        @(posedge clk);

        // ---- load the coefficient table, in the documented order (phase-major, tap-minor) ----
        ct_rewind = 1'b1; @(posedge clk); ct_rewind = 1'b0;
        for (i = 0; i < PHASES*TAPS; i = i + 1) begin
            ct_we = 1'b1; ct_data = coef[i]; @(posedge clk);
        end
        ct_we = 1'b0; @(posedge clk);

        // ---- load the source line ----
        for (i = 0; i < N; i = i + 1) begin
            sw_we = 1'b1; sw_idx = i[13:0]; sw_data = src[i]; @(posedge clk);
        end
        sw_we = 1'b0;
        repeat (4) @(posedge clk);

        // ---- issue every request; with +STALL, randomly deassert `en` mid-stream ----
        // The results must be IDENTICAL with and without stalls. A stall that drops or duplicates
        // a sample would otherwise only show up on silicon under DDR backpressure, which is the
        // hardest possible place to debug it.
        nedge = 0;
        for (i = 0; i < NREQ; i = i + 1) begin
            g_v    = 1'b1;
            g_idx  = req[i][13:0];
            g_wq   = req[i][30:16];
            g_edge = req[i][31];
            if (req[i][31]) nedge = nedge + 1;
            @(posedge clk);
            while (do_stall && ($random % 4) == 0) begin
                en = 1'b0;                       // hold the request steady while stalled
                @(posedge clk);
                en = 1'b1;
            end
        end
        g_v = 1'b0; g_edge = 1'b0;
        repeat (48) @(posedge clk);             // drain the pipeline

        // ---- compare ----
        $display("  requests %0d (%0d full-tap, %0d edge) -> outputs %0d", NREQ, NEXP, nedge, got_n);
        $display("  stall cycles injected: %0d", stall_cyc);
        if (do_stall && stall_cyc == 0) begin
            $display("  FAIL: +STALL requested but no stall ever fired -- the test is VACUOUS");
            errors = errors + 1;
        end
        if (got_n != NEXP) begin
            $display("  FAIL: expected exactly %0d outputs, got %0d", NEXP, got_n);
            if (got_n == NREQ)
                $display("        (== NREQ: the core answered EDGE requests it must stay silent on)");
            errors = errors + 1;
        end
        for (k = 0; k < NEXP && k < got_n; k = k + 1) begin
            if (got[k] !== exp[k]) begin
                errors = errors + 1;
                if (shown < 8) begin
                    $display("  [%0d] got %08x want %08x", k, got[k], exp[k]);
                    shown = shown + 1;
                end
            end
        end

        begin : dump
            integer fh;
            fh = $fopen("s32_got.hex", "w");
            for (k = 0; k < got_n; k = k + 1)
                $fwrite(fh, "%08x %0d %0d\n", got[k], used_rot[k], used_ph[k]);
            $fclose(fh);
            $fclose(fh2);
        end

        if (errors == 0)
            $display("==== sinc32 gather: PASS (%0d values bit-exact vs the model, %0d edge requests silent) ====",
                     NEXP, nedge);
        else
            $display("==== sinc32 gather: FAIL (%0d error(s)) ====", errors);
        $finish;
    end
endmodule

`default_nettype wire
