// sar_resample_v.v -- hand-written replacement for the SmartHLS `resample` kernel, with
// COEFFICIENT GENERATION FUSED IN.
//
// WHY: silicon profiling (2026-07-21) split the resample stage into 19.94 s of CPU coefficient
// generation against 6.1 ms of fabric gather. Even after the CPU-side closed-form rewrite the
// coefficients cost ~760 us/line, and the irreducible remainder is pure DDR traffic to hand them
// to the fabric: 8192 idx (int32, 32 KB) + 8192 wq (int16, 16 KB) written per line, read back by
// the gather over FIC_0, plus ~768 CCACHE FLUSH64 stores per line to publish them (FIC_0 is
// non-coherent). Generating the coefficients HERE deletes all of it -- they never reach DDR, and
// the per-line flush_coef_bank_to_ddr() disappears with them.
//
// This is Verilog and not SmartHLS on purpose: the coefficient math is sign-sensitive fixed point
// and this kernel is a mem<->mem feeder, i.e. exactly the two things SmartHLS has miscompiled on
// this part (see SMARTHLS_ANTIPATTERNS.md, the (int16_t)(x>>16) detect bug, and the dead
// mem->stream fft_feeder). Conventions follow fft_feeder_v.v: AXI4-Lite control slave, elastic
// FIFO with reserved slots, sticky AXI protocol-violation latches, WHY comments.
//
// =====================================================================================
// OUTPUT CONTRACT -- UNCHANGED from resample.cpp / sar_resample_coeffs.h. Bit-identical:
//     out[i] = in[idx[i]] + (in[idx[i]+1] - in[idx[i]]) * wq[i]/32768      (Q15, truncating)
//     idx in the SOURCE's NATURAL order; idx out of [0, SN-2] -> zero fill
//     32-bit word = {I[31:16], Q[15:0]}
// The lerp below reproduces resample.cpp's lerp()/pk() exactly, including the int16 truncation.
//
// =====================================================================================
// THE MATH (validated on the real Umbra NDSU CPHD by mpfs/host/check_coeff_ndsu.py)
//
// Both passes reduce to the SAME two steps, which is why one datapath serves both:
//     (1) an AFFINE map of a FIXED on-chip query table:   v[i] = QTAB[i]*A + B
//     (2) turning v into (idx, wq).
//
// PASS 1 (range), MODE=0. Source is xp[j] = a*(f0 + j*df) = x0 + j*dx -- UNIFORMLY SPACED, so
//   sar_resample_coeffs.c's closed form applies:
//       t = (q - x0)/dx , k = floor(t) , frac = t - k , in-range iff 0 <= t < SN-1
//   With q = KR[i] that is exactly v = KR[i]*A + B for A = 1/dx, B = -x0/dx. So v IS t, and
//   k/frac are just the integer and fractional fields of v. No divider, no search, one multiply.
//   dx < 0 needs no special case: floor(t) is already the NATURAL index and frac is already the
//   weight toward index+1 (the .c file's comment; it carries over unchanged).
//
// PASS 2 (azimuth), MODE=1. Source is xp[k] = KR[j]*tan_s[k] -- NOT uniform, so a monotonic
//   merge scan over tan_s is required. Instead of scaling the SOURCE by kr=KR[j] per line, this
//   divides the QUERY (the "reformed (scale query)" variant scored in check_coeff_ndsu.py):
//       u = KC[i]/kr , bracket u in tan_s , frac = (u - tan_s[k]) * inv_tan[k]
//   because  (q - kr*tan_s[k]) / (kr*(tan_s[k+1]-tan_s[k])) == (q/kr - tan_s[k]) * inv_tan[k].
//   Then BOTH the source table (tan_s) and the reciprocal table (inv_tan) are line-invariant and
//   live on chip; the only per-line scalars are A ~ 1/kr and B. u = KC[i]*A + B is the same
//   affine map as pass 1.
//
//   *** DELIBERATE DEVIATION from sar_resample_coeffs.c, please read ***
//   The .c file works in an ASCENDING VIEW of the source (macro XA), which reverses the array for
//   kr<0 and therefore needs BOTH an index reversal (S-2-k) and a SIGN FLIP on the reciprocal
//   (`rr = asc ? r : -r`) -- the bug called out in the task brief. In QUERY space that whole
//   family of cases evaporates: tan_s ascends unconditionally, so the bracket k found against
//   tan_s is ALREADY the natural index and frac is ALREADY the weight toward k+1, for either
//   sign of kr. The sign of kr survives only as the sign of A, which makes u DESCEND with i --
//   handled by walking the query index backwards (DIR below), not by negating anything.
//   Net: no `-r`, no `S-2-k`, no `1-frac`. Same math, fewer places to get the sign wrong.
//   One consequence to be aware of: the half-open edge (`>=` vs `>`) attaches to the opposite
//   endpoint for kr<0 than it does in the .c ascending view, so a query landing EXACTLY on an
//   endpoint can differ by one sample between the two implementations. Interior samples are
//   unaffected.
//
// =====================================================================================
// NUMERIC FORMAT -- FIXED POINT, NOT FLOAT (measured, do not "simplify" back to float32)
// On real NDSU data at deci-1 the shipping float32 path puts 1484 of ~108k taps (1.4%) in the
// WRONG bracket; fixed point at Q32 gives 181 and Q36 gives 86. float32's 24-bit mantissa is
// squandered on the ~1e7-1e8 absolute magnitude of these k-space coordinates, while all the
// information is in the low bits. So every table here is a SCALED INTEGER and there is no float
// anywhere -- no soft-float core, no float divider.
//
// HOST/CPU-SIDE TABLE CONTRACT (the CPU does this once per scene, in double, then writes ints):
//     KR_i[i]  = round( (KR[i]    - KR_OFF) * KR_SCALE )      int32
//     KC_i[i]  = round( (KC[i]    - KC_OFF) * KC_SCALE )      int32
//     TS_i[k]  = round( (tan_s[k] - TS_OFF) * TS_SCALE )      int32
//     INV_i[k] = round( 2^INVQ / (TS_i[k+1] - TS_i[k]) )      int32, >0 (tan_s ascends)
// The *_OFF are line-invariant offsets and the *_SCALE are chosen so the table spans about
// +/-2^30 -- i.e. ~Q31 of resolution across the grid span, which is the regime the model scored,
// and INVQ is chosen so the LARGEST INV_i still fits in int32 (the tightest tan_s spacing sets
// it). Offsets are what let a 32-bit table hold 1e8-magnitude values at full resolution; they
// cancel in the affine map because the CPU folds them into B.
//
// PER-LINE SCALARS (the ONLY per-line input -- no arrays, hence no DDR coefficient traffic):
//     v = ((QTAB[i] * A) >>> SH) + B                       48-bit signed
//   MODE=0: v is Q24 in SOURCE SAMPLES.  A,SH,B chosen so v = (KR[i]-x0)/dx * 2^24.
//              idx  = v[37:24]            (integer part)
//              wq   = round(v[23:0] / 2^9)  = v[23:9] + v[8], clamped to 32767
//              valid iff 0 <= v < (SN-1)*2^24
//   MODE=1: v is Q12 in TS_i COUNTS.     A,SH,B chosen so v = (KC[i]/kr - TS_OFF)*TS_SCALE*2^12.
//              merge-scan v against TS_i[k]*2^12 ; idx = k
//              wq   = (v - TS_i[k]*2^12) * INV_i[k] >>> FSH , clamped to [0,32767]
//              with FSH = INVQ + 12 - 15 = INVQ - 3   (product Q is INVQ+12, target is Q15)
//              valid iff TS_i[0]*2^12 <= v < TS_i[SN-1]*2^12
//   A is a signed 32-bit MANTISSA with a per-line right shift SH, i.e. the CPU normalizes A per
//   line the way CoreFFT normalizes a block. That keeps all 31 mantissa bits useful whatever dx
//   or kr happen to be, WITHOUT a floating-point format or an exponent datapath in fabric.
//   The 64-bit product is checked for loss on the >>>SH and on the +B: an overflow marks that
//   sample OUT OF RANGE (zero fill) and latches err_sat, because a silently WRAPPED v would
//   produce a plausible in-range index pointing at the wrong sample -- a corruption that survives
//   a correlation check.
//
// =====================================================================================
// AXI4-LITE REGISTER MAP (0x08 START/STATUS keeps the SmartHLS convention in sar_kernels.h, so
// sar_k_start()/sar_k_wait() are unchanged)
//   0x08 CTRL/STATUS  W: bit0=1 -> start.   R: bit0 = busy (0 = idle/done)
//   0x0c IN_BASE      source line byte address (4-byte aligned; odd word offset handled)
//   0x10 OUT_BASE     destination line byte address (8-byte aligned)
//   0x14 STATUS2 (RO) sticky error latches, see below
//   0x18 DIMS         [15:0]=QN outputs (even), [31:16]=SN source samples (>=2)
//   0x1c LCFG         [5:0]=SH, [13:8]=FSH, [16]=MODE (0=pass1 closed form, 1=pass2 scan)
//   0x20 COEF_A       signed 32-bit affine mantissa A
//   0x24 COEF_BLO     B[31:0]
//   0x28 COEF_BHI     B[47:32]
//   0x2c TAB_CTRL     [1:0]=table select (0=KR, 1=KC, 2=TS, 3=INV), [2]=rewind pointer
//   0x30 TAB_DATA     table word; the shared pointer auto-increments (fft_feeder_v.v 0x1c pattern)
// TABLE LOAD is AXI4-Lite and DELIBERATELY NOT A DMA, for the same reason the window taper is
// not: a second mode in the read FSM would have to arbitrate for AR/R against the row feed. The
// tables are line-invariant, so this is 4 x 8192 word writes ONCE per scene (~a few ms) against
// the ~20 s being removed.
//
// STATUS2 bits: [0]=err_extra  R beat outside a burst we asked for
//               [1]=err_rlast  RLAST disagreed with our own beat count
//               [2]=err_bresp  a write response was not OKAY/EXOKAY
//               [3]=err_align  IN_BASE/OUT_BASE/QN/SN violated an alignment or range rule
//               [4]=err_sat    an affine result overflowed 48 bits (sample forced out of range)
// The R-beat accounting is NOT optional: AXI IDs are narrowed by sar_axi_idconv.v on this path,
// so a stray or misrouted R beat lands here and would otherwise be accepted, shifting the whole
// remainder of the source line by one sample -- a smooth, plausible error that looks nothing
// like an AXI fault. Count what we asked for; latch anything else. (Same finding that added
// these latches to fft_feeder_v.v.)
//
// =====================================================================================
// SCHEDULE / THROUGHPUT
//   phase RUN    : AXI read of SN samples into on-chip `buf`, CONCURRENT with the coefficient
//                  engine (which touches no AXI at all). ~max(SN/2, coef) cycles.
//                  coef = QN cycles (MODE=0) or up to QN+SN cycles (MODE=1: the merge is one
//                  event per cycle -- advance the bracket OR emit -- never both).
//   phase GATHER : QN cycles, 1 output/cycle, packed 2 per 64-bit write beat.
//   pass 1 ~ max(N/2, 8192) + 8192 = 16.4 k cycles = 262 us @62.5 MHz
//   pass 2 ~ max(4096, 16384) + 8192 = 24.6 k cycles = 393 us @62.5 MHz
// The measured BARE gather is ~880 us/line, so the AXI path -- not this coefficient logic -- is
// the limit, exactly as the brief predicted. Hence the deliberately simple two-phase structure:
// GATHER is not overlapped with the coefficient engine even though MODE=0 emits i ascending and
// could feed it directly, because that would buy nothing against an 880 us AXI bound. See the
// note at the coef RAM.
//
// TIMING: 62.5 MHz / 16 ns. Every multiply is 16x-wide-max per stage and registered on both
// sides, and no two multiplies are chained in a cycle -- a chained multiply measured ~14 ns on
// this part and would not close. The 32x32 products are split into two 16-bit partial products
// (registered) plus a shift-add (registered).
`timescale 1ns/1ps
module sar_resample_v #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 64,
    parameter integer AXI_ID_W   = 4,
    parameter integer MAX_BURST  = 64,   // beats per AR/AW (<=256 for AXI4 INCR)
    parameter integer TAB_AW     = 13,   // 8192-entry query/source tables
    parameter integer BUF_AW     = 12,   // 4096 per bank x 2 banks = 8192 source samples
    parameter integer WF_AW      = 8     // write FIFO = 256 beats (> MAX_BURST)
)(
    input  wire                     clk,
    input  wire                     resetn,

    // ---- AXI4-Lite control slave ----
    input  wire [11:0]              s_awaddr,
    input  wire                     s_awvalid,
    output wire                     s_awready,
    input  wire [31:0]              s_wdata,
    input  wire                     s_wvalid,
    output wire                     s_wready,
    output reg                      s_bvalid,
    input  wire                     s_bready,
    input  wire [11:0]              s_araddr,
    input  wire                     s_arvalid,
    output wire                     s_arready,
    output reg  [31:0]              s_rdata,
    output reg                      s_rvalid,
    input  wire                     s_rready,

    // ---- AXI4 read master to DDR (FIC_0) : source line ----
    output wire [AXI_ID_W-1:0]      m_arid,
    output reg  [AXI_ADDR_W-1:0]    m_araddr,
    output reg  [7:0]               m_arlen,
    output wire [2:0]               m_arsize,
    output wire [1:0]               m_arburst,
    output reg                      m_arvalid,
    input  wire                     m_arready,
    input  wire [AXI_DATA_W-1:0]    m_rdata,
    input  wire                     m_rlast,
    input  wire                     m_rvalid,
    output wire                     m_rready,

    // ---- AXI4 write master to DDR (FIC_0) : destination line ----
    output wire [AXI_ID_W-1:0]      m_awid,
    output reg  [AXI_ADDR_W-1:0]    m_awaddr,
    output reg  [7:0]               m_awlen,
    output wire [2:0]               m_awsize,
    output wire [1:0]               m_awburst,
    output reg                      m_awvalid,
    input  wire                     m_awready,
    output wire [AXI_DATA_W-1:0]    m_wdata,
    output wire [(AXI_DATA_W/8)-1:0] m_wstrb,
    output wire                     m_wlast,
    output wire                     m_wvalid,
    input  wire                     m_wready,
    input  wire [1:0]               m_bresp,
    input  wire                     m_bvalid,
    output wire                     m_bready
);
    // ---------------------------------------------------------------------------------
    // constants
    // ---------------------------------------------------------------------------------
    localparam integer V_W   = 48;      // affine result width (signed)
    localparam integer IDX_W = 14;      // source index, 0..8190
    localparam integer WQ_W  = 15;      // Q15 weight
    localparam integer CF_W  = 30;      // coef RAM word = {valid, idx[13:0], wq[14:0]}

    localparam T_IDLE   = 3'd0,
               T_PREP   = 3'd1,
               T_RUN    = 3'd2,
               T_GATHER = 3'd3,
               T_DRAIN  = 3'd4;

    // ---------------------------------------------------------------------------------
    // control registers
    // ---------------------------------------------------------------------------------
    reg  [AXI_ADDR_W-1:0] in_base;
    reg  [AXI_ADDR_W-1:0] out_base;
    reg  [15:0]           qn;              // outputs this line
    reg  [15:0]           sn;              // source samples this line
    reg  [5:0]            sh;              // affine product right-shift
    reg  [5:0]            fsh;             // MODE=1 frac right-shift (= INVQ-3)
    reg                   mode;            // 0 = pass1 closed form, 1 = pass2 merge scan
    reg  signed [31:0]    coef_a;
    reg  [31:0]           coef_blo;
    reg  [15:0]           coef_bhi;
    reg  [1:0]            tab_sel;
    reg  [TAB_AW-1:0]     tab_wptr;
    reg  [TAB_AW-1:0]     tab_waddr;       // captured WITH the data (tab_wptr has moved on)
    reg  [31:0]           tab_wdata;
    reg  [3:0]            tab_we;          // one-hot per table

    reg                   start_pulse;
    reg                   busy;
    reg  [2:0]            state;

    reg                   err_extra, err_rlast, err_bresp, err_align, err_sat;

    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;
    assign s_wready  = s_awready;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            in_base <= 0; out_base <= 0; qn <= 0; sn <= 0;
            sh <= 0; fsh <= 0; mode <= 1'b0;
            coef_a <= 32'sd0; coef_blo <= 32'd0; coef_bhi <= 16'd0;
            tab_sel <= 2'd0; tab_wptr <= 0; tab_waddr <= 0; tab_wdata <= 32'd0; tab_we <= 4'd0;
            s_bvalid <= 1'b0; start_pulse <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            tab_we      <= 4'd0;
            if (s_awready) begin
                case (s_awaddr[11:0])
                    12'h008: start_pulse <= s_wdata[0];
                    12'h00c: in_base     <= s_wdata[AXI_ADDR_W-1:0];
                    12'h010: out_base    <= s_wdata[AXI_ADDR_W-1:0];
                    12'h018: begin qn <= s_wdata[15:0]; sn <= s_wdata[31:16]; end
                    12'h01c: begin sh <= s_wdata[5:0]; fsh <= s_wdata[13:8]; mode <= s_wdata[16]; end
                    12'h020: coef_a      <= s_wdata;
                    12'h024: coef_blo    <= s_wdata;
                    12'h028: coef_bhi    <= s_wdata[15:0];
                    12'h02c: begin
                        tab_sel <= s_wdata[1:0];
                        if (s_wdata[2]) tab_wptr <= 0;
                    end
                    12'h030: begin
                        tab_wdata <= s_wdata;
                        tab_waddr <= tab_wptr;
                        tab_we    <= (4'd1 << tab_sel);
                        tab_wptr  <= tab_wptr + 1'b1;
                    end
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
                12'h008: s_rdata <= {31'd0, busy};
                12'h00c: s_rdata <= in_base;
                12'h010: s_rdata <= out_base;
                12'h014: s_rdata <= {27'd0, err_sat, err_align, err_bresp, err_rlast, err_extra};
                12'h018: s_rdata <= {sn, qn};
                12'h01c: s_rdata <= {15'd0, mode, 2'd0, fsh, 2'd0, sh};
                12'h020: s_rdata <= coef_a;
                12'h024: s_rdata <= coef_blo;
                12'h028: s_rdata <= {16'd0, coef_bhi};
                12'h02c: s_rdata <= {29'd0, 1'b0, tab_sel};
                12'h030: s_rdata <= {{(32-TAB_AW){1'b0}}, tab_wptr};
                default: s_rdata <= 32'd0;
            endcase
        end else if (s_rvalid & s_rready) begin
            s_rvalid <= 1'b0;
        end
    end

    // per-line values latched at START so a late AXI4-Lite write cannot split a line
    reg  [15:0]        r_qn, r_sn;
    reg  [5:0]         r_sh, r_fsh;
    reg                r_mode;
    reg  signed [31:0] r_a;
    reg  signed [V_W-1:0] r_b;
    reg                r_dir;           // 1 = walk the query index DOWNWARDS (kr<0 in pass 2)
    wire [15:0]        sn_m1 = r_sn - 16'd1;

    // ---------------------------------------------------------------------------------
    // on-chip tables. All four are line-invariant and loaded once per scene over AXI4-Lite.
    // Simple dual-port form (one write, one synchronous read) so Synplify infers LSRAM.
    // ---------------------------------------------------------------------------------
    (* syn_ramstyle = "lsram" *) reg [31:0] kr_mem  [0:(1<<TAB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] kc_mem  [0:(1<<TAB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] ts_mem  [0:(1<<TAB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] inv_mem [0:(1<<TAB_AW)-1];

    reg  [31:0]       kr_q, kc_q, ts_q, inv_q;
    wire [TAB_AW-1:0] q_addr;            // query table address (KR or KC)
    wire [TAB_AW-1:0] ts_addr;
    wire [TAB_AW-1:0] inv_addr;
    wire              fen;               // front-end pipeline clock enable (declared below)

    // ---------------------------------------------------------------------------------
    // coefficient front end: v = ((QTAB[i]*A) >>> SH) + B
    //
    // Four registered stages, one query per cycle, stalled as a unit by `fen` when the MODE=1
    // merge scan spends a cycle advancing the bracket instead of consuming a query. Freezing
    // every stage together loses nothing, so no skid FIFO is needed.
    // ---------------------------------------------------------------------------------
    reg  [TAB_AW-1:0] qi;                // query index being ISSUED
    reg  [15:0]       q_left;            // queries still to issue
    wire              q_issue;           // qi is valid to issue THIS cycle

    assign q_addr   = qi;

    // stage A: table read result
    reg               vA;
    reg [TAB_AW-1:0]  qiA;
    // stage B: partial products
    reg signed [47:0] pH;
    reg signed [48:0] pL;
    reg               vB;
    reg [TAB_AW-1:0]  qiB;
    // stage C: full product
    reg signed [63:0] pC;
    reg               vC;
    reg [TAB_AW-1:0]  qiC;
    // stage D: v
    reg signed [V_W-1:0] vD_val;
    reg               vD;
    reg               satD;
    reg [TAB_AW-1:0]  qiD;

    wire signed [31:0] qtab_q  = r_mode ? kc_q : kr_q;
    wire signed [16:0] a_hi    = {r_a[31], r_a[31:16]};      // signed high half
    wire        [15:0] a_lo    = r_a[15:0];                  // unsigned low half
    wire signed [63:0] p_sum   = ({{16{pH[47]}}, pH} <<< 16) + {{15{1'b0}}, pL};
    wire signed [63:0] p_shift = pC >>> r_sh;
    // loss on the shift: everything above bit 47 must be a pure sign extension of bit 47
    wire               sat_sh  = (p_shift[63:48] != {16{p_shift[47]}});
    wire signed [V_W:0]  v_sum = {p_shift[47], p_shift[47:0]} + {r_b[V_W-1], r_b};
    wire               sat_add = (v_sum[V_W] != v_sum[V_W-1]);

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            vA <= 1'b0; vB <= 1'b0; vC <= 1'b0; vD <= 1'b0;
            qiA <= 0; qiB <= 0; qiC <= 0; qiD <= 0;
            pH <= 48'sd0; pL <= 49'sd0; pC <= 64'sd0;
            vD_val <= {V_W{1'b0}}; satD <= 1'b0;
        end else if (fen) begin
            vA  <= q_issue;                  qiA <= qi;
            pH  <= $signed(qtab_q) * a_hi;
            pL  <= $signed(qtab_q) * $signed({1'b0, a_lo});
            vB  <= vA;                       qiB <= qiA;
            pC  <= p_sum;
            vC  <= vB;                       qiC <= qiB;
            vD_val <= v_sum[V_W-1:0];
            satD   <= sat_sh | sat_add;
            vD  <= vC;                       qiD <= qiC;
        end
    end

    // ---------------------------------------------------------------------------------
    // MODE=0 decode: v is Q24 in source samples. idx/wq are just its two fields.
    // ---------------------------------------------------------------------------------
    wire signed [V_W-1:0] tmax1 = {{(V_W-37){1'b0}}, sn_m1[12:0], 24'd0};   // (SN-1) * 2^24
    wire               m0_inr   = ~satD & ~vD_val[V_W-1] & (vD_val < tmax1);
    wire [IDX_W-1:0]   m0_idx   = vD_val[37:24];
    wire [15:0]        m0_wraw  = {1'b0, vD_val[23:9]} + {15'd0, vD_val[8]};  // round-to-nearest
    // clamp exactly like sar_resample_coeffs.c's emit(): wi>32767 -> 32767
    wire [WQ_W-1:0]    m0_wq    = m0_wraw[15] ? 15'd32767 : m0_wraw[14:0];

    // ---------------------------------------------------------------------------------
    // MODE=1 merge scan over TS_i. One EVENT per cycle: advance the bracket OR emit.
    //
    // ts_k / ts_k1 / inv_k mirror the .c loop's x0 / SRC(k+1) / INVSPAN(k). They are held in
    // registers rather than re-read, and the table addresses are driven COMBINATIONALLY one
    // bracket AHEAD (k+2 / k+1) so that if this cycle advances, next cycle's ts_k1 and inv_k
    // have already landed. Without that speculation an advance would cost 2 cycles (RAM read
    // latency) and the line would cost QN+2*SN instead of QN+SN.
    // ---------------------------------------------------------------------------------
    reg  [IDX_W-1:0]      k;
    reg  signed [31:0]    ts_k, ts_k1, ts_lo, ts_hi;
    reg  [31:0]           inv_k;
    reg  [1:0]            prep_cnt;
    reg                   prep_act;

    wire signed [V_W-1:0] ts_k_ext  = {{(V_W-44){ts_k[31]}},  ts_k,  12'd0};
    wire signed [V_W-1:0] ts_k1_ext = {{(V_W-44){ts_k1[31]}}, ts_k1, 12'd0};
    wire signed [V_W-1:0] ts_lo_ext = {{(V_W-44){ts_lo[31]}}, ts_lo, 12'd0};
    wire signed [V_W-1:0] ts_hi_ext = {{(V_W-44){ts_hi[31]}}, ts_hi, 12'd0};

    wire m1_inr = ~satD & (vD_val >= ts_lo_ext) & (vD_val < ts_hi_ext);
    // .c: while (k + 2u < S && SRC(k+1) <= q) k++;
    wire m1_adv = vD & m1_inr & (({2'd0, k} + 16'd2) < r_sn) & (ts_k1_ext <= vD_val);

    wire consume = vD & (r_mode ? ~m1_adv : 1'b1);
    assign fen   = ~vD | consume;

    // delta = v - TS_i[k]*2^12, saturated into 32 bits. In range it is one bracket span wide.
    wire signed [V_W-1:0] dlt_full = vD_val - ts_k_ext;
    wire                  dlt_ovf  = dlt_full[V_W-1] | (|dlt_full[V_W-2:32]);
    wire [31:0]           dlt_sat  = dlt_ovf ? 32'd0 : dlt_full[31:0];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            k <= 0; ts_k <= 32'sd0; ts_k1 <= 32'sd0; ts_lo <= 32'sd0; ts_hi <= 32'sd0;
            inv_k <= 32'd0; prep_cnt <= 2'd0; prep_act <= 1'b0;
        end else if (state == T_PREP) begin
            prep_act <= 1'b1;
            prep_cnt <= prep_cnt + 2'd1;
            // ts_addr walks 0,1,SN-1 (see the mux below); each result lands one cycle later
            case (prep_cnt)
                2'd1: begin ts_k <= ts_q; ts_lo <= ts_q; inv_k <= inv_q; end
                2'd2: ts_k1 <= ts_q;
                2'd3: ts_hi <= ts_q;
                default: ;
            endcase
        end else begin
            prep_act <= 1'b0;
            prep_cnt <= 2'd0;
            if (state == T_IDLE) k <= 0;
            else if (r_mode & m1_adv) begin
                k     <= k + 1'b1;
                ts_k  <= ts_k1;
                ts_k1 <= ts_q;               // = TS_i[k+2], speculated last cycle
                inv_k <= inv_q;              // = INV_i[k+1]
            end
        end
    end

    // PREP addresses 0,1,SN-1; from prep_cnt==3 onward the scan's k+2 / k+1 speculation takes
    // over, so that the FIRST scan cycle (k=0) has already issued TS_i[2] and INV_i[1].
    wire prep_sel = (state == T_PREP) && (prep_cnt != 2'd3);
    assign ts_addr  = !prep_sel ? ({{(TAB_AW-IDX_W){1'b0}}, k} + {{(TAB_AW-2){1'b0}}, 2'd2}) :
                      (prep_cnt == 2'd0) ? {TAB_AW{1'b0}} :
                      (prep_cnt == 2'd1) ? {{(TAB_AW-1){1'b0}}, 1'b1}
                                         : sn_m1[TAB_AW-1:0];
    assign inv_addr = (prep_sel && prep_cnt == 2'd0)
                          ? {TAB_AW{1'b0}}
                          : ({{(TAB_AW-IDX_W){1'b0}}, k} + {{(TAB_AW-1){1'b0}}, 1'b1});

    // table RAMs (write from the AXI4-Lite loader, synchronous read)
    always @(posedge clk) begin
        if (tab_we[0]) kr_mem[tab_waddr] <= tab_wdata;
        if (fen) kr_q <= kr_mem[q_addr];
    end
    always @(posedge clk) begin
        if (tab_we[1]) kc_mem[tab_waddr] <= tab_wdata;
        if (fen) kc_q <= kc_mem[q_addr];
    end
    always @(posedge clk) begin
        if (tab_we[2]) ts_mem[tab_waddr] <= tab_wdata;
        ts_q <= ts_mem[ts_addr];
    end
    always @(posedge clk) begin
        if (tab_we[3]) inv_mem[tab_waddr] <= tab_wdata;
        inv_q <= inv_mem[inv_addr];
    end

    // ---------------------------------------------------------------------------------
    // emit pipeline -> coefficient RAM. MODE=0 carries a finished wq through; MODE=1 runs the
    // (v - TS_i[k]) * INV_i[k] multiply here, downstream of the scan, so its latency costs
    // throughput nothing.
    // ---------------------------------------------------------------------------------
    reg               e0_v, e1_v, e2_v, e3_v;
    reg               e0_val, e1_val, e2_val, e3_val;
    reg [TAB_AW-1:0]  e0_qi, e1_qi, e2_qi, e3_qi;
    reg [IDX_W-1:0]   e0_idx, e1_idx, e2_idx, e3_idx;
    reg [WQ_W-1:0]    e0_w0, e1_w0, e2_w0;        // MODE=0 weight, carried
    reg [31:0]        e0_dlt;
    reg signed [49:0] fH;
    reg signed [49:0] fL;
    reg signed [65:0] fP;
    reg [WQ_W-1:0]    e3_wq;

    wire signed [32:0] dlt_s = {1'b0, e0_dlt};
    wire signed [65:0] f_sum = ({{16{fH[49]}}, fH} <<< 16) + {{16{1'b0}}, fL};
    wire signed [65:0] f_shr = fP >>> r_fsh;
    // clamp to [0,32767] -- frac must be in [0,1) and a boundary case must not wrap
    wire [WQ_W-1:0]    f_wq  = f_shr[65]                        ? 15'd0     :
                               (|f_shr[65:15])                  ? 15'd32767 :
                                                                  f_shr[14:0];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            e0_v <= 1'b0; e1_v <= 1'b0; e2_v <= 1'b0; e3_v <= 1'b0;
            e0_val <= 1'b0; e1_val <= 1'b0; e2_val <= 1'b0; e3_val <= 1'b0;
            e0_qi <= 0; e1_qi <= 0; e2_qi <= 0; e3_qi <= 0;
            e0_idx <= 0; e1_idx <= 0; e2_idx <= 0; e3_idx <= 0;
            e0_w0 <= 0; e1_w0 <= 0; e2_w0 <= 0; e3_wq <= 0;
            e0_dlt <= 32'd0; fH <= 50'sd0; fL <= 50'sd0; fP <= 66'sd0;
        end else begin
            e0_v   <= consume;
            e0_qi  <= qiD;
            e0_val <= r_mode ? m1_inr : m0_inr;
            e0_idx <= r_mode ? k : m0_idx;
            e0_w0  <= m0_wq;
            e0_dlt <= dlt_sat;

            e1_v <= e0_v; e1_val <= e0_val; e1_qi <= e0_qi; e1_idx <= e0_idx; e1_w0 <= e0_w0;
            fH   <= dlt_s * $signed({1'b0, inv_k[31:16]});
            fL   <= dlt_s * $signed({1'b0, inv_k[15:0]});

            e2_v <= e1_v; e2_val <= e1_val; e2_qi <= e1_qi; e2_idx <= e1_idx; e2_w0 <= e1_w0;
            fP   <= f_sum;

            e3_v <= e2_v; e3_val <= e2_val; e3_qi <= e2_qi; e3_idx <= e2_idx;
            e3_wq <= r_mode ? f_wq : e2_w0;
        end
    end

    // Coefficient RAM. It exists because MODE=1 with kr<0 emits the query index DESCENDING
    // (u = KC[i]/kr descends), so the gather cannot simply consume the emit stream and still
    // write `out` in ascending, burstable order. Buffering (idx,wq) here and running the gather
    // as a separate ascending phase costs QN extra cycles per line and keeps the write side a
    // clean sequential burst -- cheap against the ~880 us AXI bound.
    (* syn_ramstyle = "lsram" *) reg [CF_W-1:0] cf_mem [0:(1<<TAB_AW)-1];
    reg  [CF_W-1:0]   cf_q;
    wire [TAB_AW-1:0] cf_raddr;
    wire [IDX_W-1:0]  cf_idx = cf_q[CF_W-2 -: IDX_W];
    always @(posedge clk) begin
        if (e3_v) cf_mem[e3_qi] <= {e3_val, e3_idx, e3_wq};
        cf_q <= cf_mem[cf_raddr];
    end

    reg [15:0] emit_cnt;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)                emit_cnt <= 16'd0;
        else if (state == T_IDLE)   emit_cnt <= 16'd0;
        else if (e3_v)              emit_cnt <= emit_cnt + 1'b1;
    end
    wire coef_done = (emit_cnt == r_qn);

    // Query issue: ascending, or DESCENDING when pass 2 sees kr<0 (u = KC[i]/kr then descends
    // with i, and the merge scan requires an ascending query sequence).
    // q_issue is COMBINATIONAL so that it pairs with the qi actually presented to the table this
    // cycle: the table read is synchronous, so a registered q_issue would arrive alongside the
    // NEXT qi and shift every query by one (query 0 dropped, query QN fabricated).
    assign q_issue = (state == T_RUN) && (q_left != 16'd0);
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin qi <= 0; q_left <= 16'd0; end
        else if (state == T_IDLE) begin
            qi     <= (mode & coef_a[31]) ? (qn[TAB_AW-1:0] - 1'b1) : {TAB_AW{1'b0}};
            q_left <= qn;
        end else if (q_issue && fen) begin
            q_left <= q_left - 1'b1;
            qi     <= r_dir ? (qi - 1'b1) : (qi + 1'b1);
        end
    end

    // ---------------------------------------------------------------------------------
    // source line -> on-chip buf, as two banks split by sample PARITY.
    //
    // The gather needs buf[j] and buf[j+1] in the SAME cycle. j and j+1 always have opposite
    // parity, so an even bank and an odd bank give both with one read port each -- no dual-read
    // RAM, no second copy of the line.
    //
    // IN_BASE is only 4-byte aligned in pass 1 (row base = BUF_SIG + i*N*4 with N odd), which is
    // exactly why resample.cpp had to leave `in` unpacked at ar_size=2 and waste half of the
    // 64-bit FIC_0 bus. Here the read is always full-width 64-bit beats from (IN_BASE & ~7) and
    // the odd leading 32-bit word is simply discarded, so pass 1 gets the full bus too.
    // ---------------------------------------------------------------------------------
    (* syn_ramstyle = "lsram" *) reg [31:0] buf_e [0:(1<<BUF_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] buf_o [0:(1<<BUF_AW)-1];
    reg  [31:0]       buf_e_q, buf_o_q;
    wire [BUF_AW-1:0] be_addr, bo_addr;
    wire              be_we,   bo_we;
    wire [31:0]       be_data, bo_data;

    reg               rd_odd;              // IN_BASE[2]: line starts in the UPPER half of a beat
    reg  [15:0]       rd_beat;             // beat index within the line
    reg  [15:0]       rd_beats_left;       // beats still to request
    reg  [AXI_ADDR_W-1:0] rd_addr;
    reg  [8:0]        burst_rem;
    reg  [15:0]       rd_cur_len;
    reg  [1:0]        rstate;
    reg               rd_done;

    localparam R_IDLE = 2'd0, R_ADDR = 2'd1, R_DATA = 2'd2, R_DONE = 2'd3;

    wire       beat_ok = (rstate == R_DATA) && (burst_rem != 9'd0);
    wire       rbeat   = m_rvalid & m_rready;
    wire       rstore  = rbeat & beat_ok;
    assign     m_rready = 1'b1;            // buf always has room: the line is sized to fit

    // sample indices carried by this beat: low = 2*rd_beat - rd_odd, high = low + 1
    wire [16:0] n_lo = {rd_beat, 1'b0} - {16'd0, rd_odd};
    wire [16:0] n_hi = n_lo + 17'd1;
    wire        lo_ok = rstore & ~(rd_odd & (rd_beat == 16'd0)) & (n_lo < {1'b0, r_sn});
    wire        hi_ok = rstore & (n_hi < {1'b0, r_sn});

    // rd_odd=0: low sample is EVEN -> buf_e[rd_beat],   high is ODD  -> buf_o[rd_beat]
    // rd_odd=1: low sample is ODD  -> buf_o[rd_beat-1], high is EVEN -> buf_e[rd_beat]
    assign be_we   = rd_odd ? hi_ok : lo_ok;
    assign bo_we   = rd_odd ? lo_ok : hi_ok;
    assign be_data = rd_odd ? m_rdata[63:32] : m_rdata[31:0];
    assign bo_data = rd_odd ? m_rdata[31:0]  : m_rdata[63:32];

    // Gather-side bank addresses. They are driven from cf_q (the coefficient RAM output)
    // COMBINATIONALLY, i.e. one cycle before the parity register g1_idx exists: buf_e/buf_o are
    // synchronous, so an address taken from g1_idx would deliver its data one cycle after the
    // stage that consumes it. (This was an off-by-one on first write -- every output would have
    // used the PREVIOUS coefficient's samples.)
    reg  [IDX_W-1:0]  g1_idx;
    wire [BUF_AW-1:0] ge_ra = cf_idx[0] ? (cf_idx[IDX_W-1:1] + 1'b1) : cf_idx[IDX_W-1:1];
    wire [BUF_AW-1:0] go_ra = cf_idx[IDX_W-1:1];

    assign be_addr = (state == T_GATHER) ? ge_ra : rd_beat[BUF_AW-1:0];
    assign bo_addr = (state == T_GATHER) ? go_ra
                                         : (rd_odd ? (rd_beat[BUF_AW-1:0] - 1'b1)
                                                   : rd_beat[BUF_AW-1:0]);

    always @(posedge clk) begin
        if (be_we) buf_e[be_addr] <= be_data;
        buf_e_q <= buf_e[be_addr];
    end
    always @(posedge clk) begin
        if (bo_we) buf_o[bo_addr] <= bo_data;
        buf_o_q <= buf_o[bo_addr];
    end

    // read burst master
    assign m_arid    = {AXI_ID_W{1'b0}};
    assign m_arsize  = 3'b011;             // 8 bytes/beat
    assign m_arburst = 2'b01;              // INCR

    wire [15:0] r_blk4k = (16'd4096 - {4'd0, rd_addr[11:0]}) >> 3;
    wire [15:0] r_cap   = (rd_beats_left < MAX_BURST) ? rd_beats_left : MAX_BURST[15:0];
    wire [15:0] r_raw   = (r_blk4k < r_cap) ? r_blk4k : r_cap;
    // Clamp to >=1. rd_addr is 8-byte aligned by construction so r_blk4k is never 0 today, but a
    // 0 here would encode arlen=0xFF (a 256-beat burst) AND subtract 0 from rd_beats_left, so the
    // FSM would never terminate and `busy` would never drop. Same clamp, same reason, as
    // fft_feeder_v.v -- simulation cannot reach it and it is one firmware edit away.
    wire [15:0] r_len   = (r_raw == 16'd0) ? 16'd1 : r_raw;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            rstate <= R_IDLE; m_arvalid <= 1'b0; m_araddr <= 0; m_arlen <= 8'd0;
            rd_beats_left <= 16'd0; rd_addr <= 0; burst_rem <= 9'd0; rd_cur_len <= 16'd0;
            rd_beat <= 16'd0; rd_odd <= 1'b0; rd_done <= 1'b0;
            err_extra <= 1'b0; err_rlast <= 1'b0;
        end else begin
            if (rbeat && !beat_ok) err_extra <= 1'b1;
            if (rstore) rd_beat <= rd_beat + 1'b1;
            case (rstate)
              R_IDLE: begin
                  m_arvalid <= 1'b0;
                  if (state == T_RUN && !rd_done) begin
                      rd_odd        <= in_base[2];
                      rd_addr       <= {in_base[AXI_ADDR_W-1:3], 3'b000};
                      // beats = ceil((SN + odd)/2) = (SN + odd + 1) >> 1
                      rd_beats_left <= (r_sn + {15'd0, in_base[2]} + 16'd1) >> 1;
                      rd_beat       <= 16'd0;
                      rstate        <= R_ADDR;
                  end
              end
              R_ADDR: begin
                  if (rd_beats_left == 16'd0) begin
                      rd_done <= 1'b1;
                      rstate  <= R_DONE;
                  end else if (!m_arvalid) begin
                      m_araddr   <= rd_addr;
                      m_arlen    <= r_len[7:0] - 8'd1;
                      rd_cur_len <= r_len;
                      m_arvalid  <= 1'b1;
                  end else if (m_arvalid && m_arready) begin
                      m_arvalid <= 1'b0;
                      burst_rem <= rd_cur_len[8:0];
                      rstate    <= R_DATA;
                  end
              end
              R_DATA: begin
                  if (rstore) begin
                      burst_rem <= burst_rem - 9'd1;
                      if (m_rlast != (burst_rem == 9'd1)) err_rlast <= 1'b1;
                      if (burst_rem == 9'd1) begin
                          rd_beats_left <= rd_beats_left - rd_cur_len;
                          rd_addr       <= rd_addr + {rd_cur_len, 3'b000};
                          rstate        <= R_ADDR;
                      end
                  end
              end
              R_DONE: begin
                  if (state == T_IDLE) begin rd_done <= 1'b0; rstate <= R_IDLE; end
              end
              default: rstate <= R_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------------------
    // gather + lerp. Bit-identical to resample.cpp:
    //     lerp(a,b,w) = (int16)( a + (((int32)(b-a) * w) >> 15) )
    //     out = { lerp(hi(A),hi(B),w), lerp(lo(A),lo(B),w) }
    // The subtract, the multiply and the final add each get their own cycle -- a sub feeding a
    // multiply in one 16 ns cycle is the chained-arithmetic case that would not close.
    // ---------------------------------------------------------------------------------
    reg  [TAB_AW-1:0] gi;                 // coef/output index being issued
    reg  [15:0]       g_left;
    reg               g0_v, g1_v, g2_v, g3_v, g4_v;
    reg               g1_val, g2_val, g3_val, g4_val;
    reg  [WQ_W-1:0]   g1_wq, g2_wq, g3_wq;
    reg  signed [16:0] d_hi, d_lo;
    reg  signed [15:0] a_hi_s, a_lo_s;
    reg  signed [32:0] mh, ml;
    reg  signed [15:0] ah2, al2;
    reg  [31:0]       g_word;
    reg               g_word_v;
    wire              gen;                // gather pipeline enable (write FIFO backpressure)

    assign cf_raddr = gi;

    wire [31:0] bufA = g1_idx[0] ? buf_o_q : buf_e_q;   // buf[j]
    wire [31:0] bufB = g1_idx[0] ? buf_e_q : buf_o_q;   // buf[j+1]

    wire signed [32:0] sh_hi = {{16{d_hi[16]}}, d_hi} * $signed({1'b0, g2_wq});
    wire signed [32:0] sh_lo = {{16{d_lo[16]}}, d_lo} * $signed({1'b0, g2_wq});
    wire signed [17:0] r_hi  = {{2{ah2[15]}}, ah2} + mh[32:15];
    wire signed [17:0] r_lo  = {{2{al2[15]}}, al2} + ml[32:15];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            g0_v <= 1'b0; g1_v <= 1'b0; g2_v <= 1'b0; g3_v <= 1'b0; g4_v <= 1'b0;
            g1_val <= 1'b0; g2_val <= 1'b0; g3_val <= 1'b0; g4_val <= 1'b0;
            g1_idx <= 0; g1_wq <= 0; g2_wq <= 0; g3_wq <= 0;
            d_hi <= 17'sd0; d_lo <= 17'sd0; a_hi_s <= 16'sd0; a_lo_s <= 16'sd0;
            mh <= 33'sd0; ml <= 33'sd0; ah2 <= 16'sd0; al2 <= 16'sd0;
        end else if (gen) begin
            g0_v <= (state == T_GATHER) && (g_left != 16'd0);
            // stage 1: coef word out of cf_mem
            g1_v   <= g0_v;
            g1_val <= cf_q[CF_W-1];
            g1_idx <= cf_idx;
            g1_wq  <= cf_q[WQ_W-1:0];
            // stage 2: bank data out of buf_e/buf_o
            g2_v <= g1_v; g2_val <= g1_val; g2_wq <= g1_wq;
            d_hi   <= $signed({bufB[31], bufB[31:16]}) - $signed({bufA[31], bufA[31:16]});
            d_lo   <= $signed({bufB[15], bufB[15:0]})  - $signed({bufA[15], bufA[15:0]});
            a_hi_s <= bufA[31:16];
            a_lo_s <= bufA[15:0];
            // stage 3: the two multiplies
            g3_v <= g2_v; g3_val <= g2_val; g3_wq <= g2_wq;
            mh <= sh_hi; ml <= sh_lo; ah2 <= a_hi_s; al2 <= a_lo_s;
            // stage 4: add + int16 truncation + pack
            g4_v <= g3_v; g4_val <= g3_val;
        end
    end

    wire [31:0] g_out = g4_val ? {r_hi[15:0], r_lo[15:0]} : 32'd0;   // idx<0 -> zero fill

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin gi <= 0; g_left <= 16'd0; end
        // load from the CONTROL register qn, not r_qn: at the start_pulse cycle state is still
        // T_IDLE and r_qn has not been updated yet (nonblocking), so r_qn would be last line's.
        else if (state == T_IDLE) begin gi <= 0; g_left <= qn; end
        else if (gen && state == T_GATHER && g_left != 16'd0) begin
            gi     <= gi + 1'b1;
            g_left <= g_left - 1'b1;
        end
    end

    // pack two 32-bit outputs into one 64-bit beat (little-endian: output 2n in the LOW half,
    // matching resample.cpp's uint32_t* out over a 64-bit bus)
    reg [WF_AW:0] wf_wptr, wf_rptr;
    (* syn_ramstyle = "lsram" *) reg [AXI_DATA_W-1:0] wf_mem [0:(1<<WF_AW)-1];
    wire [WF_AW:0] wf_cnt  = wf_wptr - wf_rptr;
    localparam integer WF_CAP = (1<<WF_AW) - 8;
    wire           wf_full  = (wf_cnt >= WF_CAP);
    wire           wf_empty = (wf_cnt == 0);
    assign gen = ~wf_full;

    // The push must be evaluated in the SAME cycle as the second output of the pair -- a
    // registered push flag would write one cycle later, when g_out has already moved on.
    wire wf_do = gen & g4_v & g_word_v;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)              begin g_word <= 32'd0; g_word_v <= 1'b0; end
        else if (state == T_IDLE) begin g_word_v <= 1'b0; end
        else if (gen && g4_v) begin
            if (!g_word_v) begin g_word <= g_out; g_word_v <= 1'b1; end
            else                 g_word_v <= 1'b0;
        end
    end
    always @(posedge clk) if (wf_do) wf_mem[wf_wptr[WF_AW-1:0]] <= {g_out, g_word};
    always @(posedge clk or negedge resetn) begin
        if (!resetn)                    wf_wptr <= 0;
        else if (state == T_IDLE)       wf_wptr <= 0;
        else if (wf_do)                 wf_wptr <= wf_wptr + 1'b1;
    end

    // Show-ahead FIFO read (fft_feeder_v.v pattern). wf_mem MUST be read synchronously or it
    // synthesizes to LUT RAM/registers (256 x 64 = 16 Kb) instead of LSRAM.
    reg [AXI_DATA_W-1:0] wsd;
    reg                  wsv;
    wire                 wf_has = (wf_wptr != wf_rptr);
    wire                 w_fire;               // qualified W beat, declared with the FSM below
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin wf_rptr <= 0; wsv <= 1'b0; wsd <= {AXI_DATA_W{1'b0}}; end
        else if (state == T_IDLE) begin wf_rptr <= 0; wsv <= 1'b0; end
        else begin
            if (w_fire) wsv <= 1'b0;
            if ((~wsv | w_fire) & wf_has) begin
                wsd     <= wf_mem[wf_rptr[WF_AW-1:0]];
                wf_rptr <= wf_rptr + 1'b1;
                wsv     <= 1'b1;
            end
        end
    end

    // ---------------------------------------------------------------------------------
    // write burst master
    // ---------------------------------------------------------------------------------
    reg [1:0]             wstate;
    reg [15:0]            wr_beats_left;
    reg [AXI_ADDR_W-1:0]  wr_addr;
    reg [15:0]            wr_cur_len;
    reg [8:0]             wbeat_rem;
    reg [15:0]            bresp_left;
    reg                   wr_done;

    localparam W_IDLE = 2'd0, W_ADDR = 2'd1, W_DATA = 2'd2, W_DONE = 2'd3;

    assign m_awid    = {AXI_ID_W{1'b0}};
    assign m_awsize  = 3'b011;
    assign m_awburst = 2'b01;
    assign m_wstrb   = {(AXI_DATA_W/8){1'b1}};
    assign m_wdata   = wsd;
    assign m_wvalid  = (wstate == W_DATA) && wsv && (wbeat_rem != 9'd0);
    assign m_wlast   = (wbeat_rem == 9'd1);
    assign m_bready  = 1'b1;
    assign w_fire    = m_wvalid & m_wready;
    // Beats available to a burst = FIFO occupancy PLUS the one already prefetched into wsd.
    // Counting only wf_cnt would deadlock on a final 1-beat burst whose single beat is sitting
    // in the show-ahead register.
    wire [WF_AW:0] wf_avail = wf_cnt + {{WF_AW{1'b0}}, wsv};

    wire [15:0] w_blk4k = (16'd4096 - {4'd0, wr_addr[11:0]}) >> 3;
    wire [15:0] w_cap   = (wr_beats_left < MAX_BURST) ? wr_beats_left : MAX_BURST[15:0];
    wire [15:0] w_raw   = (w_blk4k < w_cap) ? w_blk4k : w_cap;
    wire [15:0] w_len   = (w_raw == 16'd0) ? 16'd1 : w_raw;   // see r_len clamp

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            wstate <= W_IDLE; m_awvalid <= 1'b0; m_awaddr <= 0; m_awlen <= 8'd0;
            wr_beats_left <= 16'd0; wr_addr <= 0; wr_cur_len <= 16'd0; wbeat_rem <= 9'd0;
            bresp_left <= 16'd0; wr_done <= 1'b0; err_bresp <= 1'b0;
        end else begin
            if (m_bvalid && m_bready) begin
                if (m_bresp[1]) err_bresp <= 1'b1;         // SLVERR/DECERR
                if (bresp_left != 16'd0) bresp_left <= bresp_left - 1'b1;
            end
            case (wstate)
              W_IDLE: begin
                  m_awvalid <= 1'b0;
                  if (state == T_GATHER && !wr_done) begin
                      wr_addr       <= out_base;
                      wr_beats_left <= {1'b0, r_qn[15:1]};   // 2 outputs per 64-bit beat
                      bresp_left    <= 16'd0;
                      wstate        <= W_ADDR;
                  end
              end
              W_ADDR: begin
                  if (wr_beats_left == 16'd0) begin
                      wr_done <= 1'b1;
                      wstate  <= W_DONE;
                  end else if (!m_awvalid && (wf_avail >= {1'b0, w_len[WF_AW-1:0]})) begin
                      // Issue AW only once the FIFO already HOLDS the whole burst. W has no way
                      // to back off mid-burst without stalling the slave, and w_len <= MAX_BURST
                      // < WF_CAP, so this can never deadlock against the gather.
                      m_awaddr   <= wr_addr;
                      m_awlen    <= w_len[7:0] - 8'd1;
                      wr_cur_len <= w_len;
                      m_awvalid  <= 1'b1;
                  end else if (m_awvalid && m_awready) begin
                      m_awvalid  <= 1'b0;
                      wbeat_rem  <= wr_cur_len[8:0];
                      bresp_left <= bresp_left + 1'b1;
                      wstate     <= W_DATA;
                  end
              end
              W_DATA: begin
                  if (w_fire) begin
                      wbeat_rem <= wbeat_rem - 9'd1;
                      if (wbeat_rem == 9'd1) begin
                          wr_beats_left <= wr_beats_left - wr_cur_len;
                          wr_addr       <= wr_addr + {wr_cur_len, 3'b000};
                          wstate        <= W_ADDR;
                      end
                  end
              end
              W_DONE: begin
                  if (state == T_IDLE) begin wr_done <= 1'b0; wstate <= W_IDLE; end
              end
              default: wstate <= W_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------------------
    // top-level sequencer
    // ---------------------------------------------------------------------------------
    wire gather_drained = (g_left == 16'd0) && !g0_v && !g1_v && !g2_v && !g3_v && !g4_v
                          && !g_word_v && wf_empty && !wsv;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= T_IDLE; busy <= 1'b0; err_align <= 1'b0; err_sat <= 1'b0;
            r_qn <= 16'd0; r_sn <= 16'd0; r_sh <= 6'd0; r_fsh <= 6'd0; r_mode <= 1'b0;
            r_a <= 32'sd0; r_b <= {V_W{1'b0}}; r_dir <= 1'b0;
        end else begin
            if (vD && satD) err_sat <= 1'b1;
            case (state)
              T_IDLE: begin
                  if (start_pulse) begin
                      r_qn   <= qn;
                      r_sn   <= sn;
                      r_sh   <= sh;
                      r_fsh  <= fsh;
                      r_mode <= mode;
                      r_a    <= coef_a;
                      r_b    <= {coef_bhi, coef_blo};
                      r_dir  <= mode & coef_a[31];   // pass 2, kr<0 -> u descends with i
                      busy   <= 1'b1;
                      if (in_base[1:0] != 2'd0 || out_base[2:0] != 3'd0 ||
                          qn[0] || qn == 16'd0 || sn < 16'd2 ||
                          qn > 16'd8192 || sn > 16'd8192) err_align <= 1'b1;
                      state  <= mode ? T_PREP : T_RUN;
                  end
              end
              T_PREP:   if (prep_cnt == 2'd3) state <= T_RUN;
              T_RUN:    if (rd_done && coef_done) state <= T_GATHER;
              T_GATHER: if (gather_drained && wr_done && bresp_left == 16'd0) state <= T_DRAIN;
              T_DRAIN: begin
                  busy  <= 1'b0;
                  state <= T_IDLE;
              end
              default: state <= T_IDLE;
            endcase
        end
    end
endmodule
