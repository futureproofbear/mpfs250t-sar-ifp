// corefft_fft_tb.v -- RTL co-simulation testbench for the Microchip CoreFFT IP
// (in-place Radix-2 architecture), driven by the golden vectors from
// mpfs/host/fft_golden.py and checked by `fft_golden.py check`.
//
// FLOW
//   1) python fft_golden.py gen --n 8192 --bits 16 --tw-bits 16 --out fft_vectors
//      (use --bits == CoreFFT WIDTH so the comparison is apples-to-apples; the
//       in-place core uses ONE WIDTH for data AND twiddle.)
//   2) Simulate (ModelSim/QuestaSim) with IN_HEX/OUT_HEX set per case.
//   3) python fft_golden.py check --expected fft_vectors/random_out.hex \
//             --actual rtl_out.hex --corr-min 0.9999 --nrmse-max 0.01
//      Tolerance mode (NOT bit-exact): CoreFFT conditional BFP downscales only on
//      real overflow, so its mantissa scale / SCALE_EXP differs from the emulator;
//      the checker's scale-aligned NRMSE + correlation absorb that.
//
// CoreFFT config that this TB assumes (set in the Libero IP configurator):
//   POINTS = 8192, WIDTH = 16, SCALE = 0 (conditional BFP), SCALE_EXP_ON = 1.
// Ports (Table 2-2, in-place CoreFFT): CLK, SLOWCLK (<= CLK/8, twiddle LUT init),
//   NGRST (async, active-low), DATAI_RE/IM + DATAI_VALID, BUF_READY,
//   READ_OUTP, DATAO_RE/IM + DATAO_VALID, OUTP_READY, SCALE_EXP.
// FFT Result = DATAO * 2^SCALE_EXP  (SCALE_EXP maps to BFP_SHIFT in regmap.md).
//
// Replace the COREFFT instance name/params below with your generated component.

`timescale 1ns/1ps
module corefft_fft_tb;
  parameter integer WIDTH  = 16;
  parameter integer POINTS = 8192;
  parameter integer EXPW   = 5;            // SCALE_EXP width (>=ceil(log2(log2(N)+1)); confirm vs generated core)
  parameter         IN_HEX  = "fft_vectors/random_in.hex";
  parameter         OUT_HEX = "rtl_out.hex";

  reg  clk = 0, slowclk = 0, ngrst = 0;
  reg  [WIDTH-1:0] datai_re = 0, datai_im = 0;
  reg  datai_valid = 0, read_outp = 0;
  wire [WIDTH-1:0] datao_re, datao_im;
  wire datao_valid, buf_ready, outp_ready;
  wire [EXPW-1:0]  scale_exp;

  // 100 MHz CLK; SLOWCLK = CLK/8 (twiddle LUT init clock, must be <= CLK/8)
  always #5  clk = ~clk;
  always #40 slowclk = ~slowclk;

  // ---- DUT: the generated CoreFFT (in-place). Rename to your instance. ----
  COREFFT #(.WIDTH(WIDTH), .POINTS(POINTS), .SCALE(0), .SCALE_EXP_ON(1)) dut (
    .CLK(clk), .SLOWCLK(slowclk), .NGRST(ngrst),
    .DATAI_RE(datai_re), .DATAI_IM(datai_im), .DATAI_VALID(datai_valid),
    .BUF_READY(buf_ready), .READ_OUTP(read_outp),
    .DATAO_RE(datao_re), .DATAO_IM(datao_im), .DATAO_VALID(datao_valid),
    .OUTP_READY(outp_ready), .SCALE_EXP(scale_exp)
  );

  reg [31:0] inmem [0:POINTS-1];           // (uint16(I)<<16)|uint16(Q) per fft_golden
  integer fi, fo, i, nout;

  initial begin
    $readmemh(IN_HEX, inmem);

    // power-on: assert async reset -> twiddle LUT auto-initializes on SLOWCLK
    ngrst = 0; repeat (4) @(posedge slowclk); ngrst = 1; @(posedge clk);

    // ---- feed POINTS complex samples, gated by BUF_READY ----
    i = 0;
    while (i < POINTS) begin
      @(posedge clk);
      if (buf_ready) begin
        datai_valid <= 1'b1;
        datai_re    <= inmem[i][31:16];    // 16-bit two's complement, real
        datai_im    <= inmem[i][15:0];     // 16-bit two's complement, imag
        i = i + 1;
      end else begin
        datai_valid <= 1'b0;
      end
    end
    @(posedge clk); datai_valid <= 1'b0;

    // ---- read POINTS results when OUTP_READY, capture DATAO + SCALE_EXP ----
    wait (outp_ready);
    fo = $fopen(OUT_HEX, "w");
    read_outp <= 1'b1;
    nout = 0;
    while (nout < POINTS) begin
      @(posedge clk);
      if (datao_valid) begin
        $fwrite(fo, "%08x\n", {datao_re[15:0], datao_im[15:0]});
        nout = nout + 1;
      end
    end
    read_outp <= 1'b0;
    $fclose(fo);
    $display("CoreFFT done: wrote %s  SCALE_EXP=%0d (BFP_SHIFT)", OUT_HEX, scale_exp);
    $finish;
  end

  // safety timeout
  initial begin #5_000_000; $display("TIMEOUT"); $finish; end
endmodule
