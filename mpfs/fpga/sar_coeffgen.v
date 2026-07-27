// sar_coeffgen.v -- ON-FABRIC azimuth resample coefficient generator.
//
// WHY: silicon telemetry 2026-07-25 -- fft1_gather_pass() costs 15.15 s of a 36.6 s frame, of
// which 1499 us/row is CPU coefficient generation (sar_coeffs_pass2) against 0.53 us/row of
// residual fabric wait. The feeder/CoreFFT/unloader chain is ALREADY idle waiting on the CPU.
// The table cannot be precomputed (8192x8192 = ~768 MB), but tan_s[] and KC[] are ROW-INVARIANT:
// per row the kernel needs only the scalar KR[j]. So the whole thing fits on-chip and the 48 KB/row
// idx[] + 48 KB/row wq[] DDR round-trip (and its L2 flush) disappears with it.
//
// -----------------------------------------------------------------------------------------------
// THE ARITHMETIC DECISION -- integer hardware, IEEE-754 binary32 VALUES (and why not fixed point)
//
// sar_coeffs_pass2_range() is float32 and its ROUNDING is load-bearing, not incidental:
//   * the bracket test is `SRC(k+1) <= q` with SRC(k+1) = fl32(kr*tan_s[k+1]); rounding that
//     product moves the bracket edge by ~0.5 ulp, and a query inside that window takes the OTHER
//     bracket -- idx off by one, wq flipping between ~0 and ~32767.
//   * frac = fl32(fl32(q-x0)*inv) with x0 = fl32(kr*tan_s[k]); 0.5 ulp of x0 is ~1.7e-8 against a
//     bracket span of ~8.2e-4, i.e. ~0.67 Q15 LSB -- a "close enough" x0 moves wq by +-1 constantly.
// So a fixed-point REFORMULATION (u = q/kr bracketed against tan_s in a common Q format) cannot be
// bit-identical -- it is a different rounding sequence. MEASURED on real staged geometry by
// mpfs/host/check_coeffgen_fixed.py GATE 3: even at Q36 it moves wq on 49% of in-range outputs.
//
// What IS both cheap and bit-exact is to keep the float32 values and do them with integer logic:
//   * every multiply here has NORMALIZED operands, so the 24x24 significand product lands in
//     [2^46,2^48): normalization is ONE bit, decided by one bit. No leading-zero count, no barrel
//     shifter. sar_fp32_mul is a 24x24 multiply + a 1-bit shift + round-to-nearest-even.
//   * the ONLY divide in the line, 1.0f/kr, stays on the CPU (which already computes it) and
//     arrives as register RINV. No divider, no reciprocal ROM in fabric -- and it is the SAME
//     float expression the C uses, which is what keeps `inv` bit-exact.
//   * inv_tan[k] = 1/(tan_s[k+1]-tan_s[k]) is line-invariant, already built once by
//     sar_coeffs_init(), and is pushed in as a TABLE. Recomputing it in fabric would round
//     differently -- exactly the trap documented in sar_coeffs_pass2_range()'s header.
// Only fl32(q-x0) and the two small adds in emit() need a real aligner/normalizer; one 3-stage
// add/sub design covers all three uses.
//
// PROOF (board-free, non-negotiable per the project gate discipline):
//   mpfs/host/coeffgen_model.py is a pure-integer model of THIS datapath, op for op.
//   mpfs/host/check_coeffgen_fixed.py GATE 1 fuzzes the primitives against numpy float32 and
//   GATE 2 proves the model byte-identical to sar_coeffs_pass2_range() over the real staged
//   geometry (M=705, Mp=8192), ascending AND descending source (kr<0).
//   mpfs/fpga/tb/tb_sar_coeffgen.v then checks THIS RTL against vectors from that model.
//
// -----------------------------------------------------------------------------------------------
// STRUCTURE (all three engines run at 1 item/cycle; the row costs QN + (advances) cycles)
//
//   SRC producer   for k = 0..S-2 read tan_s[]/inv_tan[] and compute {SRC(k), INVSPAN(k)}, push
//                  into a short lookahead FIFO. Decoupled so the consumer never waits on the
//                  multiply latency.
//   KC prefetch    streams KC[qi] into its own short FIFO.
//   consumer       holds the moving bracket (k, x0, inv). Each cycle it either ADVANCES the
//                  bracket (pop the SRC FIFO) or ISSUES one output -- exactly the C while/for.
//   emit pipe      11 stages: fl32(q-x0) -> *inv -> (1-frac if kr<0) -> *32768 + 0.5f -> trunc,
//                  clamp. Free-running, with slots reserved in the output FIFO so it can never
//                  need to stall (same reservation pattern as fft_feeder_v.v's window stages).
//
// Control is an AXI4-Lite slave in the style of fft_feeder_v.v (one 32-bit write per cycle pair):
//   0x00 CTRL   W [0]=start row  [1]=rewind tan ptr  [2]=rewind itan ptr  [3]=rewind kc ptr
//               R [0]=busy
//   0x04 KR     RW float32 bits of KR[j]                (per row)
//   0x08 RINV   RW float32 bits of 1.0f/KR[j]           (per row, CPU-computed -- see above)
//   0x0c DIMS   RW [13:0]=S (=M source samples), [29:16]=QN (=Mp outputs)
//   0x10 TANW   W  tan_s[k]   fp32 bits, pointer auto-increments   R: fill level
//   0x14 ITANW  W  inv_tan[k] fp32 bits, pointer auto-increments   R: fill level
//   0x18 KCW    W  KC[qi]     fp32 bits, pointer auto-increments   R: fill level
//   0x1c STAT   R  [0]=busy [1]=err_fmt [2]=err_dims [3]=degenerate [31:16]=outputs emitted
//
// Output stream: {m_idx[31:0], m_wq[15:0]} with m_valid/m_ready, one entry per output qi, in qi
// order. m_idx = -1 and m_wq = 0 marks out-of-range (the FFT zero-pad), matching idx[]/wq[] as
// the feeder's gather engine reads them from DDR today.
//
// NOT SYNTHESIZED YET -- board-free deliverable. No Libero run, no bitstream, no board.
`timescale 1ns/1ps

// ================================================================================================
// sar_fp32_mul -- IEEE-754 binary32 multiply, round-to-nearest-even. Latency 2, 1/cycle.
// Operands are normalized (checked upstream by err_fmt), so the product is in [2^46,2^48) and the
// entire normalization is `if (p[47]) >>1`. That is what makes this ~1 MACC cluster + ~80 LUT.
// Denormal/zero operand -> signed zero (the C's inv_tan[k]==0 degenerate span relies on this).
// ================================================================================================
module sar_fp32_mul (
    input  wire        clk,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    reg        s1_s, s1_z;
    reg [8:0]  s1_e;
    reg [47:0] s1_p;
    always @(posedge clk) begin
        s1_s <= a[31] ^ b[31];
        s1_z <= (a[30:23] == 8'd0) | (b[30:23] == 8'd0);
        s1_e <= {1'b0, a[30:23]} + {1'b0, b[30:23]};
        s1_p <= {1'b1, a[22:0]} * {1'b1, b[22:0]};
    end

    wire        msb   = s1_p[47];
    wire [23:0] mant0 = msb ? s1_p[47:24] : s1_p[46:23];
    wire        g     = msb ? s1_p[23]    : s1_p[22];
    wire        st    = msb ? (|s1_p[22:0]) : (|s1_p[21:0]);
    wire [24:0] mr    = {1'b0, mant0} + {24'd0, (g & (st | mant0[0]))};
    wire        rovf  = mr[24];
    wire [23:0] mant  = rovf ? mr[24:1] : mr[23:0];
    // exponent = ea + eb - 127 + msb + round-overflow   (signed, may underflow past 0)
    wire signed [10:0] eo = $signed({2'b00, s1_e}) - 11'sd127
                          + {10'd0, msb} + {10'd0, rovf};
    always @(posedge clk) begin
        if (s1_z)                    y <= {s1_s, 31'd0};
        else if (eo <= 11'sd0)       y <= {s1_s, 31'd0};                 // underflow -> zero
        else if (eo >= 11'sd255)     y <= {s1_s, 8'hFE, 23'h7FFFFF};     // saturate, never hit here
        else                         y <= {s1_s, eo[7:0], mant[22:0]};
    end
endmodule

// ================================================================================================
// sar_fp32_add -- IEEE-754 binary32 add, round-to-nearest-even. Latency 3, 1/cycle.
// Stage 1 magnitude-order + align (with sticky), stage 2 add/sub + leading-zero count,
// stage 3 normalize + round. Subtraction is done by the caller flipping b's sign bit.
// This is the ONE unit that needs an aligner/normalizer; fl32(q-x0) cancels heavily by
// construction (q is inside the bracket [x0, x0+span)) so the full 24-bit LZC is required.
// ================================================================================================
module sar_fp32_add (
    input  wire        clk,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);
    // ---- stage 1: zero bypass, magnitude order, alignment ----
    wire a_z = (a[30:23] == 8'd0);
    wire b_z = (b[30:23] == 8'd0);
    wire byp = a_z | b_z;
    // IEEE round-to-nearest: (-0)+(-0) = -0, every other zero-zero sum is +0
    wire [31:0] byp_val = (a_z & b_z) ? ((a == b) ? a : 32'd0) : (a_z ? b : a);

    wire        swap = ({1'b0, a[30:0]} < {1'b0, b[30:0]});
    wire [31:0] xa   = swap ? b : a;                 // larger magnitude
    wire [31:0] xb   = swap ? a : b;
    wire [7:0]  dex  = xa[30:23] - xb[30:23];        // >= 0 by construction
    wire [7:0]  shn  = (dex > 8'd27) ? 8'd27 : dex;
    wire [26:0] bfull = {1'b1, xb[22:0], 3'b000};    // 24-bit significand + G,R,S
    wire [26:0] bsh   = bfull >> shn;
    wire        bstk  = |(bfull & ~({27{1'b1}} << shn));

    reg        s1_s, s1_sub, s1_byp;
    reg [7:0]  s1_e;
    reg [26:0] s1_x, s1_y;
    reg [31:0] s1_byp_val;
    always @(posedge clk) begin
        s1_s       <= xa[31];
        s1_sub     <= xa[31] ^ xb[31];
        s1_e       <= xa[30:23];
        s1_x       <= {1'b1, xa[22:0], 3'b000};
        s1_y       <= bsh | {26'd0, bstk};
        s1_byp     <= byp;
        s1_byp_val <= byp_val;
    end

    // ---- stage 2: add/sub, leading-zero count ----
    wire [27:0] rsum = s1_sub ? ({1'b0, s1_x} - {1'b0, s1_y})
                              : ({1'b0, s1_x} + {1'b0, s1_y});
    integer i;
    reg [4:0] lz;
    always @* begin
        lz = 5'd27;                                   // rsum[26:0] == 0 marker
        for (i = 0; i <= 26; i = i + 1)
            if (rsum[i]) lz = 5'd26 - i[4:0];         // highest set bit assigned last
    end

    reg         s2_s, s2_byp, s2_zero;
    reg  [27:0] s2_m;
    reg signed [10:0] s2_e;
    reg  [31:0] s2_byp_val;
    always @(posedge clk) begin
        s2_s       <= s1_s;
        s2_byp     <= s1_byp;
        s2_byp_val <= s1_byp_val;
        s2_zero    <= (rsum == 28'd0);
        if (rsum[27]) begin                           // carry out of the significand
            s2_m <= (rsum >> 1) | {27'd0, rsum[0]};   // sticky preserved
            s2_e <= $signed({3'b000, s1_e}) + 11'sd1;
        end else begin
            s2_m <= rsum << lz;
            s2_e <= $signed({3'b000, s1_e}) - $signed({6'd0, lz});
        end
    end

    // ---- stage 3: round-to-nearest-even ----
    wire [23:0] m0   = s2_m[26:3];
    wire        g3   = s2_m[2];
    wire        st3  = |s2_m[1:0];
    wire [24:0] mr3  = {1'b0, m0} + {24'd0, (g3 & (st3 | m0[0]))};
    wire        rovf3 = mr3[24];
    wire [23:0] mant3 = rovf3 ? mr3[24:1] : mr3[23:0];
    wire signed [10:0] e3 = s2_e + {10'd0, rovf3};
    always @(posedge clk) begin
        if (s2_byp)                 y <= s2_byp_val;
        else if (s2_zero)           y <= 32'd0;                       // exact cancellation -> +0
        else if (e3 <= 11'sd0)      y <= {s2_s, 31'd0};
        else if (e3 >= 11'sd255)    y <= {s2_s, 8'hFE, 23'h7FFFFF};
        else                        y <= {s2_s, e3[7:0], mant3[22:0]};
    end
endmodule

// ================================================================================================
// sar_coeffgen -- top
// ================================================================================================
module sar_coeffgen #(
    parameter integer TAN_AW = 13,      // tan_s / inv_tan table depth (8192 == SAR_COEFF_MAXS)
    parameter integer KC_AW  = 13,      // KC table depth (8192 == Mp)
    parameter integer SF_AW  = 4,       // SRC/INVSPAN lookahead FIFO (16)
    parameter integer QF_AW  = 3,       // KC prefetch FIFO (8)
    parameter integer OF_AW  = 5        // output FIFO (32)
)(
    input  wire        clk,
    input  wire        resetn,

    // ---- AXI4-Lite control slave ----
    input  wire [11:0] s_awaddr,
    input  wire        s_awvalid,
    output wire        s_awready,
    input  wire [31:0] s_wdata,
    input  wire        s_wvalid,
    output wire        s_wready,
    output reg         s_bvalid,
    input  wire        s_bready,
    output wire [1:0]  s_bresp,
    input  wire [11:0] s_araddr,
    input  wire        s_arvalid,
    output wire        s_arready,
    output reg  [31:0] s_rdata,
    output reg         s_rvalid,
    input  wire        s_rready,
    output wire [1:0]  s_rresp,

    // ---- coefficient stream to the gather engine ----
    output wire [31:0] m_idx,           // int32, -1 = out of range (zero fill)
    output wire [15:0] m_wq,            // Q15 weight
    output wire        m_valid,
    input  wire        m_ready
);
    // Issue -> output-FIFO write. Derived, not guessed:
    //   sub(3) -> mul(2) -> sub(3) -> add(3) = 11 cycles, result valid in cycle 11.
    localparam integer EMIT_LAT = 13;   // 11 for the pass-2 chain + 2 for pass-1's trunc/i2f.
                                        // Uniform across modes on purpose -- see the emit-pipeline
                                        // note below; a mode-dependent depth would let a mode or
                                        // kr-sign change corrupt the tail of a row.

    // ============================ float32 helpers (combinational) ============================
    // Ordered key for float32 compare: sign-magnitude -> monotone unsigned. Both zeros collapse to
    // the same key so `-0.0 < +0.0` is FALSE, matching C.
    function [31:0] fkey;
        input [31:0] v;
        reg   [31:0] z;
        begin
            z    = (v[30:0] == 31'd0) ? 32'd0 : v;
            fkey = z[31] ? ~z : (z | 32'h8000_0000);
        end
    endfunction

    // ---- PASS-1 helpers -------------------------------------------------------------------
    // t is known to be in [0, tmax) with tmax <= 8191 (the caller rejects out-of-range BEFORE
    // these are used), so both are small, exact, and need no rounding.

    // floor(t) for a non-negative float32 < 2^13.  Truncation toward zero == floor for t >= 0,
    // which is exactly what the C's (int32_t)t does.
    function [13:0] f2i_floor;
        input [31:0] v;
        reg   [8:0]  e;          // unbiased exponent
        reg   [23:0] m;          // 1.mantissa
        begin
            e = {1'b0, v[30:23]} - 9'd127;
            m = {1'b1, v[22:0]};
            if (v[30:23] < 8'd127) f2i_floor = 14'd0;               // |t| < 1
            else                   f2i_floor = m >> (6'd23 - e[5:0]);
        end
    endfunction

    // Exact int->float32 for a 14-bit unsigned. Values <= 8192 need at most 13 significand bits,
    // so the result is always exactly representable and there is nothing to round.
    function [31:0] i2f_small;
        input [13:0] u;
        reg   [3:0]  p;          // index of the most significant set bit
        reg   [23:0] mm;
        integer      i;
        begin
            p = 4'd0;
            for (i = 0; i < 14; i = i + 1) if (u[i]) p = i[3:0];
            if (u == 14'd0) i2f_small = 32'd0;
            else begin
                mm        = {10'd0, u} << (5'd23 - p);              // align MSB to bit23
                i2f_small = {1'b0, (8'd127 + {4'd0, p}), mm[22:0]};
            end
        end
    endfunction

    // NaN / Inf / denormal detector -- these have no path in this datapath, so they are LATCHED
    // rather than silently mis-evaluated.
    function fbad;
        input [31:0] v;
        begin
            fbad = (v[30:23] == 8'hFF) | ((v[30:23] == 8'd0) & (|v[22:0]));
        end
    endfunction

    // v * 32768.0f -- exact: a power-of-two scale only moves the exponent, no rounding.
    function [31:0] fscale15;
        input [31:0] v;
        reg   [8:0]  e;
        begin
            e = {1'b0, v[30:23]} + 9'd15;
            fscale15 = (v[30:23] == 8'd0) ? {v[31], 31'd0}
                     : (e >= 9'd255)      ? {v[31], 8'hFE, 23'h7FFFFF}
                                          : {v[31], e[7:0], v[22:0]};
        end
    endfunction

    // C's `int32_t wi = (int32_t)v; if (wi<0) wi=0; if (wi>32767) wi=32767;`
    // Truncation toward zero, so any negative input clamps to 0.
    function [15:0] fq15;
        input [31:0] v;
        reg   [7:0]  e;
        reg   [23:0] sig;
        begin
            e   = v[30:23];
            sig = {1'b1, v[22:0]};
            if (v[31])              fq15 = 16'd0;
            else if (e < 8'd127)    fq15 = 16'd0;          // |v| < 1
            else if (e >= 8'd142)   fq15 = 16'd32767;      // >= 32768
            else                    fq15 = (sig >> (8'd23 - (e - 8'd127)));
        end
    endfunction

    // ============================ AXI4-Lite control registers ============================
    /* PASS-1 (range) MODE. 0 = pass-2 azimuth (default, existing behaviour), 1 = pass-1 range.
     * Pass 1 inverts kr = 2*pr/C*(f0 + j*df) onto the uniform KR grid. kr is AFFINE in j, so it is
     * CLOSED FORM -- no bracket, no search, no tan/itan tables:
     *     t = (KR[q] - p1_x0) * p1_inv ;  idx = (int32)t ;  wq = q15(t - (float)idx)
     * KR lives in kcmem (which pass 2 uses for KC): the two passes never run concurrently -- the
     * resample finishes before FFT-1 starts -- so the firmware reloads the tables between them,
     * ~24k AXI4-Lite writes ~= 8 ms/frame against 5.8 s saved. Hence ZERO new LSRAM. */
    reg        p1_mode;
    reg [31:0] p1_x0, p1_inv, p1_tmax;

    reg [31:0]        r_kr, r_rinv;
    reg [TAN_AW:0]    dim_s;            // S == M source samples
    reg [KC_AW:0]     dim_qn;           // QN == Mp outputs
    reg               start_pulse;
    reg [TAN_AW:0]    tan_wptr, itan_wptr;
    reg [KC_AW:0]     kc_wptr;
    reg               tan_we, itan_we, kc_we;
    reg [TAN_AW-1:0]  tan_waddr, itan_waddr;
    reg [KC_AW-1:0]   kc_waddr;
    reg [31:0]        tab_wdata;
    reg               err_fmt, err_dims, degen;
    reg               busy;
    reg [KC_AW:0]     emitted;

    // Every address in the 4 KiB window decodes (unmapped -> read 0 / write ignored), so the
    // responses are constant OKAY. They exist as PORTS because CoreAXI4Interconnect's AXI4-Lite
    // target bif drives BRESP/RRESP: leaving ONE bif signal unassigned makes SmartDesign promote
    // the WHOLE interface to top-level I/O (measured on this design -- see the RSLICE_CIC LOCK
    // note in sartop_assembly.tcl), which then fails synthesis on the 144-pin limit.
    assign s_bresp = 2'b00;
    assign s_rresp = 2'b00;

    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;
    assign s_wready  = s_awready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            r_kr <= 32'd0; r_rinv <= 32'd0; dim_s <= 0; dim_qn <= 0;
            s_bvalid <= 1'b0; start_pulse <= 1'b0;
            tan_wptr <= 0; itan_wptr <= 0; kc_wptr <= 0;
            tan_we <= 1'b0; itan_we <= 1'b0; kc_we <= 1'b0;
            tan_waddr <= 0; itan_waddr <= 0; kc_waddr <= 0; tab_wdata <= 32'd0;
            err_fmt <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            tan_we <= 1'b0; itan_we <= 1'b0; kc_we <= 1'b0;
            if (s_awready) begin
                tab_wdata <= s_wdata;
                case (s_awaddr[11:0])
                    12'h000: begin
                        start_pulse <= s_wdata[0];
                        if (s_wdata[1]) tan_wptr  <= 0;
                        if (s_wdata[2]) itan_wptr <= 0;
                        if (s_wdata[3]) kc_wptr   <= 0;
                    end
                    12'h004: begin r_kr   <= s_wdata; if (fbad(s_wdata)) err_fmt <= 1'b1; end
                    12'h008: begin r_rinv <= s_wdata; if (fbad(s_wdata)) err_fmt <= 1'b1; end
                    12'h00c: begin dim_s  <= s_wdata[TAN_AW:0]; dim_qn <= s_wdata[16+KC_AW:16]; end
                    12'h010: begin
                        tan_waddr <= tan_wptr[TAN_AW-1:0]; tan_we <= 1'b1;
                        tan_wptr  <= tan_wptr + 1'b1;
                        if (fbad(s_wdata)) err_fmt <= 1'b1;
                    end
                    12'h014: begin
                        itan_waddr <= itan_wptr[TAN_AW-1:0]; itan_we <= 1'b1;
                        itan_wptr  <= itan_wptr + 1'b1;
                        if (fbad(s_wdata)) err_fmt <= 1'b1;
                    end
                    12'h018: begin
                        kc_waddr <= kc_wptr[KC_AW-1:0]; kc_we <= 1'b1;
                        kc_wptr  <= kc_wptr + 1'b1;
                        if (fbad(s_wdata)) err_fmt <= 1'b1;
                    end
                    12'h020: p1_mode <= s_wdata[0];
                    12'h024: begin p1_x0   <= s_wdata; if (fbad(s_wdata)) err_fmt <= 1'b1; end
                    12'h028: begin p1_inv  <= s_wdata; if (fbad(s_wdata)) err_fmt <= 1'b1; end
                    12'h02c: begin p1_tmax <= s_wdata; if (fbad(s_wdata)) err_fmt <= 1'b1; end
                    default: ;
                endcase
                s_bvalid <= 1'b1;
            end else if (s_bvalid & s_bready) begin
                s_bvalid <= 1'b0;
            end
        end
    end

    assign s_arready = s_arvalid & ~s_rvalid;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin s_rvalid <= 1'b0; s_rdata <= 32'd0; end
        else if (s_arready) begin
            s_rvalid <= 1'b1;
            case (s_araddr[11:0])
                12'h000: s_rdata <= {31'd0, busy};
                12'h004: s_rdata <= r_kr;
                12'h008: s_rdata <= r_rinv;
                12'h00c: s_rdata <= {{(15-KC_AW){1'b0}}, dim_qn, {(15-TAN_AW){1'b0}}, dim_s};
                12'h010: s_rdata <= {{(31-TAN_AW){1'b0}}, tan_wptr};
                12'h014: s_rdata <= {{(31-TAN_AW){1'b0}}, itan_wptr};
                12'h018: s_rdata <= {{(31-KC_AW){1'b0}}, kc_wptr};
                12'h01c: s_rdata <= {{(15-KC_AW){1'b0}}, emitted,
                                     12'd0, degen, err_dims, err_fmt, busy};
                12'h020: s_rdata <= {31'd0, p1_mode};
                12'h024: s_rdata <= p1_x0;
                12'h028: s_rdata <= p1_inv;
                12'h02c: s_rdata <= p1_tmax;
                default: s_rdata <= 32'd0;
            endcase
        end else if (s_rvalid & s_rready) begin
            s_rvalid <= 1'b0;
        end
    end

    // ============================ row-invariant tables (LSRAM) ============================
    // One write port (AXI4-Lite, idle only) + one read port -> simple dual port. Written ONCE per
    // scene; deliberately NOT a DMA, for the same reason fft_feeder_v.v loads its taper this way:
    // a second AXI read mode would have to arbitrate, and ~2 ms once is free against 12.3 s saved.
    (* syn_ramstyle = "lsram" *) reg [31:0] tanmem  [0:(1<<TAN_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] itanmem [0:(1<<TAN_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] kcmem   [0:(1<<KC_AW)-1];

    reg [31:0] tan_q, itan_q, kc_q;
    wire [TAN_AW-1:0] tan_raddr, itan_raddr;
    wire [KC_AW-1:0]  kc_raddr;
    always @(posedge clk) begin
        if (tan_we)  tanmem[tan_waddr]   <= tab_wdata;
        tan_q  <= tanmem[tan_raddr];
    end
    always @(posedge clk) begin
        if (itan_we) itanmem[itan_waddr] <= tab_wdata;
        itan_q <= itanmem[itan_raddr];
    end
    always @(posedge clk) begin
        if (kc_we)   kcmem[kc_waddr]     <= tab_wdata;
        kc_q   <= kcmem[kc_raddr];
    end

    // ============================ per-row latched parameters ============================
    // Latched at START so a late AXI4-Lite write cannot split a row (same rule as the feeder).

    // ============================ per-row latched parameters ============================
    // Latched at START so a late AXI4-Lite write cannot split a row (same rule as the feeder).
    reg [31:0]     j_kr, j_rr;
    reg            j_asc;
    reg [TAN_AW:0] j_s;
    reg [KC_AW:0]  j_qn;
    reg [31:0]     j_xlo, j_xhi;

    localparam C_IDLE=3'd0, C_EDGE=3'd1, C_PRIME=3'd2, C_RUN=3'd3, C_DEGEN=3'd4, C_DRAIN=3'd5;
    reg [2:0] cst;
    reg [3:0] ec;                      // edge-phase step counter
    wire run_ph = (cst == C_RUN) | (cst == C_PRIME);

    // ============================ SRC / INVSPAN producer ============================
    // SRC(kk)     = fl32(kr * tan_s[asc ? kk : S-1-kk])
    // INVSPAN(kk) = fl32(inv_tan[asc ? kk : S-2-kk] * rr),  rr = asc ? 1/kr : -(1/kr)
    // The sign flip in rr is the load-bearing subtlety called out in sar_resample_coeffs.c: for
    // kr<0 the ascending VIEW walks tan_s backwards, so the view span is -kr*(tan_s[t+1]-tan_s[t]).
    // Using r for both orders gives a negative weight on EVERY descending line -- tb cases `desc`
    // and `desc_edge` fail immediately if this is dropped.
    reg  [TAN_AW:0]   kp;              // next producer index (0 .. S-2)
    // Issue at T presents the RAM address; tan_q/itan_q are valid at T+1; the multiply samples
    // them during T+1 and its output is valid at T+3. So the push tap is pv[2], NOT pv[3] --
    // pv[3] would capture the NEXT issue's product and silently shift the whole SRC table by one
    // bracket (x0 = SRC(1) for bracket 0), which reads as "all bracket-0 weights clamp to 0".
    reg  [2:0]        pv;              // issue -> RAM(1) -> mul(2) -> push
    wire [TAN_AW:0]   kp_rev_t = j_s - 1'b1 - kp;
    wire [TAN_AW:0]   kp_rev_i = j_s - 2'd2 - kp;
    wire [TAN_AW-1:0] prod_tan_a  = j_asc ? kp[TAN_AW-1:0] : kp_rev_t[TAN_AW-1:0];
    wire [TAN_AW-1:0] prod_itan_a = j_asc ? kp[TAN_AW-1:0] : kp_rev_i[TAN_AW-1:0];
    // The edge phase borrows the same tan port: SRC(0) then SRC(S-1) in the ascending VIEW.
    wire [TAN_AW:0]   s_last = j_s - 1'b1;
    wire [TAN_AW-1:0] edge_tan_a = (ec < 4'd4) ? (j_asc ? {TAN_AW{1'b0}} : s_last[TAN_AW-1:0])
                                               : (j_asc ? s_last[TAN_AW-1:0] : {TAN_AW{1'b0}});
    assign tan_raddr  = (cst == C_EDGE) ? edge_tan_a : prod_tan_a;
    assign itan_raddr = prod_itan_a;

    // SRC lookahead FIFO {INVSPAN(k), SRC(k)}. Decouples the consumer from the multiply latency,
    // so a bracket advance costs ONE cycle and never a pipeline refill.
    reg  [63:0]    sf [0:(1<<SF_AW)-1];
    reg  [SF_AW:0] sf_w, sf_r;
    wire [SF_AW:0] sf_cnt   = sf_w - sf_r;
    wire           sf_empty = (sf_cnt == 0);
    wire [63:0]    sf_head  = sf[sf_r[SF_AW-1:0]];
    localparam integer SF_LIM = (1<<SF_AW) - 6;      // reserve the 4 in-flight producer stages
    reg  [2:0]     p_infl;
    wire p_issue = run_ph && (kp < (j_s - 1'b1)) &&
                   (({{(SF_AW-2){1'b0}}, p_infl} + sf_cnt) < SF_LIM[SF_AW:0]);

    wire [31:0] src_y, inv_y;
    sar_fp32_mul u_mul_src (.clk(clk), .a(j_kr),   .b(tan_q), .y(src_y));
    sar_fp32_mul u_mul_inv (.clk(clk), .a(itan_q), .b(j_rr),  .y(inv_y));
    wire sf_push = pv[2];

    always @(posedge clk or negedge resetn) begin
        if (!resetn)                begin kp <= 0; pv <= 3'd0; p_infl <= 3'd0; sf_w <= 0; end
        else if (cst == C_IDLE)     begin kp <= 0; pv <= 3'd0; p_infl <= 3'd0; sf_w <= 0; end
        else begin
            pv <= {pv[1:0], p_issue};
            if (p_issue) kp <= kp + 1'b1;
            case ({p_issue, sf_push})
                2'b10:   p_infl <= p_infl + 1'b1;
                2'b01:   p_infl <= p_infl - 1'b1;
                default: ;
            endcase
            if (sf_push) sf_w <= sf_w + 1'b1;
        end
    end
    always @(posedge clk) if (sf_push) sf[sf_w[SF_AW-1:0]] <= {inv_y, src_y};

    // ============================ KC prefetch ============================
    reg  [KC_AW:0] qp;                 // next KC index to fetch
    reg            qv;                 // issue -> RAM(1) -> push (kc_q is valid at T+1)
    reg  [31:0]    qf [0:(1<<QF_AW)-1];
    reg  [QF_AW:0] qf_w, qf_r;
    wire [QF_AW:0] qf_cnt   = qf_w - qf_r;
    wire           qf_empty = (qf_cnt == 0);
    wire [31:0]    qf_head  = qf[qf_r[QF_AW-1:0]];
    localparam integer QF_LIM = (1<<QF_AW) - 4;
    reg  [1:0]     q_infl;
    wire q_issue = run_ph && (qp < j_qn) &&
                   (({{(QF_AW-1){1'b0}}, q_infl} + qf_cnt) < QF_LIM[QF_AW:0]);
    assign kc_raddr = qp[KC_AW-1:0];
    wire qf_push = qv;

    always @(posedge clk or negedge resetn) begin
        if (!resetn)            begin qp <= 0; qv <= 1'b0; q_infl <= 2'd0; qf_w <= 0; end
        else if (cst == C_IDLE) begin qp <= 0; qv <= 1'b0; q_infl <= 2'd0; qf_w <= 0; end
        else begin
            qv <= q_issue;
            if (q_issue) qp <= qp + 1'b1;
            case ({q_issue, qf_push})
                2'b10:   q_infl <= q_infl + 1'b1;
                2'b01:   q_infl <= q_infl - 1'b1;
                default: ;
            endcase
            if (qf_push) qf_w <= qf_w + 1'b1;
        end
    end
    always @(posedge clk) if (qf_push) qf[qf_w[QF_AW-1:0]] <= kc_q;

    // ============================ output FIFO ============================
    // EMIT_LAT+2 slots are RESERVED so the free-running emit pipe can never find it full --
    // the same reservation pattern (and the same reason) as fft_feeder_v.v's PIPE_D/FIFO_CAP.
    localparam integer OFW = TAN_AW + 18;       // {oor, k[TAN_AW:0], wq[15:0]}
    reg  [OFW-1:0] of [0:(1<<OF_AW)-1];
    reg  [OF_AW:0] of_w, of_r;
    wire [OF_AW:0] of_cnt = of_w - of_r;
    localparam integer OF_LIM = (1<<OF_AW) - EMIT_LAT - 2;
    wire of_room = (of_cnt < OF_LIM[OF_AW:0]);

    // ============================ consumer (the moving bracket) ============================
    // One cycle = either ONE bracket advance or ONE output issue. That is exactly the C's
    // `while (...) k++;` / `for (qi...)` structure, so the row costs QN + advances cycles.
    reg  [TAN_AW:0] k_cur;
    reg  [31:0]     x0_cur, inv_cur;
    reg  [KC_AW:0]  qi;

    wire [31:0] q_now       = qf_head;
    // C: if (q < xlo || q >= xhi) { idx=-1; wq=0; continue; }   -- checked BEFORE any advance
    // Pass 1 cannot decide out-of-range at issue: it depends on t, known only at c5. p1_oor_c5
    // raises it there instead, so the issue-time flag is forced low.
    wire        q_oor       = p1_mode ? 1'b0
                                      : ((fkey(q_now) < fkey(j_xlo)) | ~(fkey(q_now) < fkey(j_xhi)));
    // No moving bracket in pass 1 -- the KR grid is uniform, so t is closed form and nothing
    // advances. With adv_allowed low, do_adv and adv_wait are both dead and do_emit == cons_ok.
    wire        adv_allowed = p1_mode ? 1'b0 : ((k_cur + 2'd2) < j_s);
    wire        adv_hit     = ~(fkey(q_now) < fkey(sf_head[31:0]));   // SRC(k+1) <= q
    wire        cons_ok     = (cst == C_RUN) && of_room && !qf_empty && (qi < j_qn);
    wire        do_adv      = cons_ok && !q_oor && adv_allowed && !sf_empty && adv_hit;
    wire        adv_wait    = cons_ok && !q_oor && adv_allowed &&  sf_empty;  // producer behind
    wire        do_emit     = cons_ok && !adv_wait && !do_adv;

    wire [TAN_AW:0] k_rev = j_s - 2'd2 - k_cur;
    wire [TAN_AW:0] e_k   = j_asc ? k_cur : k_rev;

    wire deg_push = (cst == C_DEGEN) && of_room && (qi < j_qn);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            k_cur <= 0; x0_cur <= 32'd0; inv_cur <= 32'd0; qi <= 0; sf_r <= 0; qf_r <= 0;
        end else if (cst == C_IDLE) begin
            k_cur <= 0; qi <= 0; sf_r <= 0; qf_r <= 0;
        end else if (cst == C_PRIME) begin
            if (p1_mode) begin                         // pass 1: row scalars, no bracket
                x0_cur  <= p1_x0;
                inv_cur <= p1_inv;
            end else if (!sf_empty) begin              // load the k=0 bracket
                x0_cur  <= sf_head[31:0];
                inv_cur <= sf_head[63:32];
                sf_r    <= sf_r + 1'b1;
            end
        end else if (cst == C_DEGEN) begin
            if (deg_push) qi <= qi + 1'b1;
        end else begin
            if (do_adv) begin
                k_cur   <= k_cur + 1'b1;
                x0_cur  <= sf_head[31:0];
                inv_cur <= sf_head[63:32];
                sf_r    <= sf_r + 1'b1;
            end
            if (do_emit) begin
                qi   <= qi + 1'b1;
                qf_r <= qf_r + 1'b1;
            end
        end
    end

    // ============================ emit pipeline (11 stages) ============================
    //   c0        issue: q, x0, inv, k, asc valid
    //   c0..c2    u_sub_qx    -> d    = fl32(q - x0)          valid c3
    //   c3..c4    u_mul_fr    -> frac = fl32(d * inv)         valid c5
    //   c5..c7    u_sub_one   -> fl32(1.0f - frac)            valid c8
    //   c8        w = asc ? frac : (1-frac) ; w*32768.0f is exponent-only, hence exact
    //   c8..c10   u_add_half  -> fl32(w*32768.0f + 0.5f)      valid c11
    //   c11       truncate toward zero, clamp to [0,32767], push
    // Delay LINES (not muxes) align inv/frac/asc, so the latency is identical in both source
    // orders -- a mode-dependent depth would let a kr sign change corrupt the tail of a row.
    wire [31:0] d_y, frac_y, one_y, half_y;
    reg  [31:0] inv_d0, inv_d1, inv_d2;
    reg  [31:0] frac_d0, frac_d1, frac_d2, frac_d3, frac_d4;
    reg  [EMIT_LAT-1:0] asc_d, vld_d, oor_d;
    reg  [TAN_AW:0]     kx_d [0:EMIT_LAT-1];
    wire [31:0] pd_inv = inv_d2;                       // inv aligned to d_y at c3

    /* ---- PASS-1 lane: t -> (floor(t), t - float(floor(t))) --------------------------------
     * frac_y IS t in pass-1 mode: u_sub_qx/u_mul_fr already compute (q - x0)*inv, and with the
     * KR table in kcmem and x0/inv the row scalars that is exactly t. So pass 1 reuses the whole
     * front of the pipe and only adds floor + int->float here.
     *   c5  t valid            -> p1_idx (floor), p1_t held
     *   c6  p1_fidx = i2f(idx) -> both registered
     *   c7  BOTH MODES feed u_sub_one, so the latency is mode-independent (pass 2 gains the two
     *       frac_d3/frac_d4 stages for exactly this reason -- see the EMIT_LAT note).
     * Out-of-range cannot be decided at issue in pass 1 the way pass 2 does it from xlo/xhi: it
     * depends on t, which is not known until c5. p1_oor is therefore raised HERE and carried in
     * its own short delay line to the push point. */
    reg  [13:0] p1_idx_c6;
    reg  [31:0] p1_t_c6, p1_t_c7, p1_fidx_c7;
    reg  [EMIT_LAT-6:0] p1oor_d;
    wire        p1_t_neg = frac_y[31] & (|frac_y[30:0]);            // t < 0 (-0.0 is not negative)
    wire        p1_oor_c5 = p1_mode & (p1_t_neg | ~(fkey(frac_y) < fkey(p1_tmax)));
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            p1_idx_c6 <= 14'd0; p1_t_c6 <= 32'd0; p1_t_c7 <= 32'd0;
            p1_fidx_c7 <= 32'd0; p1oor_d <= 0;
        end else begin
            p1_idx_c6  <= f2i_floor(frac_y);
            p1_t_c6    <= frac_y;
            p1_t_c7    <= p1_t_c6;
            p1_fidx_c7 <= i2f_small(p1_idx_c6);
            p1oor_d    <= {p1oor_d[EMIT_LAT-7:0], p1_oor_c5};
        end
    end

    // Shared subtractor: pass 2 computes 1.0 - frac, pass 1 computes t - float(floor(t)).
    wire [31:0] sub_a = p1_mode ? p1_t_c7    : 32'h3F800000;
    wire [31:0] sub_b = p1_mode ? (p1_fidx_c7 ^ 32'h8000_0000) : (frac_d1 ^ 32'h8000_0000);
    // c10 taps. Pass 1's weight is the subtract result itself -- there is no ascending/descending
    // source order to undo, because the KR grid is uniform and always ascending.
    wire [31:0] pw_w   = p1_mode ? one_y : (asc_d[9] ? frac_d4 : one_y);
    wire [31:0] pw_s   = fscale15(pw_w);

    sar_fp32_add u_sub_qx  (.clk(clk), .a(q_now),        .b(x0_cur ^ 32'h8000_0000), .y(d_y));
    sar_fp32_mul u_mul_fr  (.clk(clk), .a(d_y),          .b(pd_inv),                 .y(frac_y));
    sar_fp32_add u_sub_one (.clk(clk), .a(sub_a),        .b(sub_b),                  .y(one_y));
    sar_fp32_add u_add_half(.clk(clk), .a(pw_s),         .b(32'h3F000000),           .y(half_y));

    integer n;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            inv_d0 <= 32'd0; inv_d1 <= 32'd0; inv_d2 <= 32'd0;
            frac_d0 <= 32'd0; frac_d1 <= 32'd0; frac_d2 <= 32'd0;
            frac_d3 <= 32'd0; frac_d4 <= 32'd0;
            asc_d <= 0; vld_d <= 0; oor_d <= 0;
            for (n = 0; n < EMIT_LAT; n = n + 1) kx_d[n] <= 0;
        end else begin
            inv_d0  <= inv_cur; inv_d1  <= inv_d0;  inv_d2  <= inv_d1;
            frac_d0 <= frac_y;  frac_d1 <= frac_d0; frac_d2 <= frac_d1;
            frac_d3 <= frac_d2; frac_d4 <= frac_d3;
            asc_d <= {asc_d[EMIT_LAT-2:0], j_asc};
            vld_d <= {vld_d[EMIT_LAT-2:0], do_emit};
            oor_d <= {oor_d[EMIT_LAT-2:0], q_oor};
            kx_d[0] <= e_k;
            for (n = 1; n < EMIT_LAT; n = n + 1) kx_d[n] <= kx_d[n-1];
        end
    end

    /* PASS-1 carries its own idx (computed at c5, delayed to the push point) and its own
     * out-of-range flag; pass 2 uses the FSM bracket counter and the issue-time flag. */
    /* Depth EMIT_LAT-7, not EMIT_LAT-8. p1_idxd[0] is loaded at c7 (one cycle after p1_idx_c6),
     * so tapping [EMIT_LAT-8] delivered the index at c12 while the result is consumed at c13 --
     * where p1oor_d[EMIT_LAT-6] and the pass-2 taps already land. One stage short paired each
     * output's fraction with the NEXT output's integer part: wq came out bit-exact and idx was
     * uniformly +1 (+2 across a gap). Caught 2026-07-27 by the model-gated p1 vectors. */
    reg [13:0] p1_idxd [0:EMIT_LAT-7];
    integer    m;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) for (m = 0; m <= EMIT_LAT-7; m = m + 1) p1_idxd[m] <= 14'd0;
        else begin
            p1_idxd[0] <= p1_idx_c6;
            for (m = 1; m <= EMIT_LAT-7; m = m + 1) p1_idxd[m] <= p1_idxd[m-1];
        end
    end

    wire        res_v   = vld_d[EMIT_LAT-1];
    wire        res_oor = p1_mode ? p1oor_d[EMIT_LAT-6] : oor_d[EMIT_LAT-1];
    wire [13:0] res_idx = p1_mode ? p1_idxd[EMIT_LAT-7] : kx_d[EMIT_LAT-1];
    wire [15:0] res_wq  = res_oor ? 16'd0 : fq15(half_y);

    wire        of_push = res_v | deg_push;
    wire [OFW-1:0] of_wdat = deg_push ? {1'b1, {(TAN_AW+1){1'b0}}, 16'd0}
                                      : {res_oor, res_idx, res_wq};
    always @(posedge clk) if (of_push) of[of_w[OF_AW-1:0]] <= of_wdat;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)            of_w <= 0;
        else if (cst == C_IDLE) of_w <= 0;
        else if (of_push)       of_w <= of_w + 1'b1;
    end

    // show-ahead read -> {idx, wq} stream
    reg  [OFW-1:0] sreg;
    reg         sreg_v;
    wire        of_has     = (of_w != of_r);
    wire        of_consume = sreg_v & m_ready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)            begin of_r <= 0; sreg_v <= 1'b0; sreg <= 0; end
        else if (cst == C_IDLE) begin of_r <= 0; sreg_v <= 1'b0; end
        else begin
            if (of_consume) sreg_v <= 1'b0;
            if ((~sreg_v | of_consume) & of_has) begin
                sreg   <= of[of_r[OF_AW-1:0]];
                of_r   <= of_r + 1'b1;
                sreg_v <= 1'b1;
            end
        end
    end
    assign m_idx   = sreg[OFW-1] ? 32'hFFFF_FFFF : {{(31-TAN_AW){1'b0}}, sreg[OFW-2:16]};
    assign m_wq    = sreg[15:0];
    assign m_valid = sreg_v;

    // ============================ row sequencer ============================
    wire pipe_empty = ~(|vld_d);
    wire tables_ok  = (tan_wptr >= dim_s) && (itan_wptr >= (dim_s - 1'b1)) && (kc_wptr >= dim_qn);
    wire dims_ok    = (dim_s >= 2) && (dim_qn != 0) && tables_ok;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cst <= C_IDLE; busy <= 1'b0; ec <= 4'd0; degen <= 1'b0; err_dims <= 1'b0;
            j_kr <= 32'd0; j_rr <= 32'd0; j_asc <= 1'b1; j_s <= 0; j_qn <= 0;
            j_xlo <= 32'd0; j_xhi <= 32'd0; emitted <= 0;
        end else begin
            case (cst)
              C_IDLE: begin
                  if (start_pulse) begin
                      j_kr    <= r_kr;
                      j_asc   <= ~r_kr[31];                     // kr >= 0 (kr == 0 -> degenerate)
                      j_rr    <= r_kr[31] ? (r_rinv ^ 32'h8000_0000) : r_rinv;   // THE SIGN FLIP
                      j_s     <= dim_s;
                      j_qn    <= dim_qn;
                      busy    <= 1'b1;
                      emitted <= 0;
                      ec      <= 4'd0;
                      if (!dims_ok) err_dims <= 1'b1;
                      // C: S<2 || kr==0 || tables not initialised -> idx=-1, wq=0 for the line.
                      // The kr==0 half is a PASS-2 test only: kr is pass 2's per-row scalar, and in
                      // pass 1 the row scalars are X0/INV/TMAX while CGEN_KR is never written (the
                      // firmware and the vectors both leave it 0). Applying it unconditionally sent
                      // EVERY pass-1 row down C_DEGEN, so every output came back idx=-1/wq=0 with
                      // the degenerate flag set. Pass 1's own degeneracy is expressed through the
                      // t-range test (t >= 0 && t < tmax), which needs no separate guard.
                      if (!dims_ok || (!p1_mode && ((r_kr & 32'h7FFF_FFFF) == 32'd0))) begin
                          degen <= 1'b1; cst <= C_DEGEN;
                      end else begin
                          degen <= 1'b0; cst <= p1_mode ? C_PRIME : C_EDGE;
                      end
                  end
              end
              // 8 cycles: RAM(1) + mul(2) settle for xlo, then again for xhi. Nothing against a
              // ~14k-cycle row, and it keeps the tan address mux trivially correct.
              C_EDGE: begin
                  ec <= ec + 1'b1;
                  if (ec == 4'd3) j_xlo <= src_y;
                  if (ec == 4'd7) begin j_xhi <= src_y; cst <= C_PRIME; end
              end
              C_PRIME: if (p1_mode || !sf_empty) cst <= C_RUN;
              C_RUN:   if ((qi >= j_qn) && pipe_empty) cst <= C_DRAIN;
              C_DEGEN: if (qi >= j_qn) cst <= C_DRAIN;
              C_DRAIN: if ((of_w == of_r) && !sreg_v) begin busy <= 1'b0; cst <= C_IDLE; end
              default: cst <= C_IDLE;
            endcase
            if (of_push) emitted <= emitted + 1'b1;
        end
    end
endmodule
