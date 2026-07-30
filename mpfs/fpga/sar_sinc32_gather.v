// sar_sinc32_gather.v -- 32-tap polyphase-sinc gather core.
//
// STANDALONE ON PURPOSE. sar_resample_v.v ships and is silicon-verified (14.92 s frame, image
// corr 0.977). This is written and elaborated BESIDE it so the working core is untouched until
// this one is proven -- the same "add, do not replace" rule that cost us a fallback path when
// sar_resample_v took the SmartHLS resample's CIC target.
//
// WHAT IT REPLACES. The shipping gather is a 2-tap linear lerp. Measured 2026-07-29, that
// scallops 29.2 dB at the scene's 0.978-Nyquist band edge -- the classic linear-interpolation
// null, gain |cos(pi f/2)| -> 0.034 at mu = 0.5 -- so a scatterer's brightness depends on where
// it lands between samples by up to 29 dB. 32 taps brings that to 3.46 dB.
// Reference model: mpfs/fpga/tb/gen_resample_vectors.py, sinc_table_q15()/gather_sinc().
//
// ---------------------------------------------------------------------------------------------
// BANKING. The window is taps at idx-15 .. idx+16, i.e. exactly 32 CONSECUTIVE samples, and the
// banks are sample-index mod 32. A width-32 window over mod-32 banks therefore hits every bank
// EXACTLY ONCE, so single-port RAMs are enough -- no dual-port, no second copy of the line. Let
//
//     base = idx - 15,   r = base[4:0],   A = base >> 5
//
// NOTE the bank DEPTH must exceed ceil(N/32) by at least one row, because the window reaches
// past the end of the line and A+1 is issued for banks below the rotation point. Headroom does
// NOT remove the edge fallback: that exists because the SAMPLES do not exist outside [0, N-1],
// which no amount of buffer fixes.
//
// then bank b holds the window sample at address A + (b < r), and the tap that sample belongs to
// is t = (b - r) mod 32. So the read is a per-bank address that is one of two values, and the
// tap ordering is a BARREL ROTATION of the bank outputs by r. Both are cheap; the rotation is
// the only structural cost versus the parity split it replaces.
//
// COEFFICIENTS. 256 phases x 32 taps, Q15, DC-normalised and forced to sum to exactly 2^15 (the
// residual of independent rounding is pushed onto the largest tap: at 32 taps it otherwise left
// some phases off unity, which is a per-phase GAIN RIPPLE, i.e. amplitude modulation across the
// image). The table is SCENE-INDEPENDENT -- it depends only on the fractional delay -- so it is
// loaded once at init, never per line, and needs no coefficient arithmetic in the datapath. That
// matters here: the 100 MHz domain has 0.255 ns of setup slack, so keeping logic OUT of the path
// is worth more than saving the LSRAM a Farrow form would avoid.
// ---------------------------------------------------------------------------------------------
`default_nettype none

module sar_sinc32_gather #(
    parameter integer TAPS    = 32,        // window width; the mod-TAPS banking assumes a power of 2
    parameter integer LOG2T   = 5,         // log2(TAPS)
    parameter integer PHASES  = 256,
    parameter integer LOG2P   = 8,
    parameter integer BANK_AW = 9,         // 512 entries/bank x 32 banks = 16384 samples
                                           // HEADROOM, and it costs nothing. A PolarFire LSRAM is
                                           // 20 kbit, so 512x32 = 16 kbit still fits ONE block per
                                           // bank -- the same 32 blocks as 256x32. Sized at 8192
                                           // it exactly fitted NDSU's N=8192 line with zero slack,
                                           // and the window (idx-15 .. idx+16) then computes a
                                           // read address of baseA+1 = 256, one past an 8-bit bank
                                           // address, which WRAPS to row 0. It was harmless only
                                           // because g_edge gates the output -- an implicit
                                           // invariant no one had written down. With 9 bits the
                                           // address cannot wrap for any N <= 16352.
    parameter integer IDX_W   = 14,
    parameter integer WQ_W    = 15
)(
    input  wire                 clk,
    input  wire                 resetn,

    // ---- coefficient table load (sequential: phase-major, tap-minor) ----
    input  wire                 ct_we,     // one 16-bit Q15 tap per strobe
    input  wire signed [15:0]   ct_data,
    input  wire                 ct_rewind, // reset the write pointer

    // ---- source line write, TWO ports ----
    // A 64-bit FIC_0 beat carries TWO samples, so a single write port would halve the fill rate
    // and make the line load the bottleneck. The two samples of a beat are at CONSECUTIVE indices,
    // and banks are index mod 32, so they always land in DIFFERENT banks -- the two ports can
    // never collide and no arbitration is needed.
    input  wire                 sw_we,
    input  wire [IDX_W-1:0]     sw_idx,    // sample index within the line
    input  wire [31:0]          sw_data,   // {I[31:16], Q[15:0]}
    input  wire                 sw2_we,
    input  wire [IDX_W-1:0]     sw2_idx,
    input  wire [31:0]          sw2_data,

    // ---- gather request ----
    // Pipeline enable / BACKPRESSURE. Low freezes the whole gather -- bank reads, multiply,
    // adder tree and output register all hold. This is a FIXED-LATENCY pipeline with no elastic
    // buffering, so the caller must hold g_v/g_idx/g_wq/g_edge stable while en is low, exactly
    // as the shipping gather's `gen` works. Without it the core free-runs and overruns the write
    // FIFO the moment DDR backs up.
    input  wire                 en,
    input  wire                 g_v,
    input  wire [IDX_W-1:0]     g_idx,     // centre: taps span g_idx-15 .. g_idx+16
    input  wire [WQ_W-1:0]      g_wq,      // Q15 fraction; phase = top LOG2P bits
    input  wire                 g_edge,    // 1 = window not fully in range -> caller supplies lerp

    // ---- result, 9 cycles after g_v (a0, sq, mult, 5 adder levels, out) ----
    output reg                  o_v,
    output reg  [31:0]          o_data,

    // High while ANY stage holds a live request. The caller must not declare a line finished until
    // this clears. Exported rather than left for the caller to infer from o_v, because o_v only
    // covers the last stage: when the address generation gained its own stage the caller's
    // hand-written drain condition silently went stale and re-armed lines stalled.
    output wire                 o_busy
);
    localparam integer HALF = TAPS/2 - 1;      // 15: taps span idx-HALF .. idx-HALF+TAPS-1

    // ============================ coefficient table ============================
    // 32 parallel memories, one per TAP, each PHASES deep. All 32 taps of a phase are read in
    // one cycle, which is why it is 32 memories and not one wide one.
    reg signed [15:0] ctab [0:TAPS-1][0:PHASES-1];
    reg [LOG2P+LOG2T-1:0] ct_ptr;
    integer ci;

    always @(posedge clk or negedge resetn) begin
        if (!resetn)      ct_ptr <= 0;
        else if (ct_rewind) ct_ptr <= 0;
        else if (ct_we)   ct_ptr <= ct_ptr + 1'b1;
    end
    // phase-major, tap-minor: ptr[LOG2T-1:0] = tap, ptr[..:LOG2T] = phase
    always @(posedge clk) begin
        if (ct_we) ctab[ct_ptr[LOG2T-1:0]][ct_ptr[LOG2P+LOG2T-1:LOG2T]] <= ct_data;
    end

    // ============================ source banks ============================
    // bank b holds samples with index[LOG2T-1:0] == b, at address index >> LOG2T
    // syn_ramstyle is not decoration: without it, and without the single-write-port form below,
    // synthesis built these 32 x 512 x 32-bit banks out of LUTs -- 985,998 of them -- and the
    // resulting 512:1 mux per bank cost -6.061 ns on the 100 MHz domain (2026-07-30).
    (* syn_ramstyle = "lsram" *) reg [31:0] sbank [0:TAPS-1][0:(1<<BANK_AW)-1];

    wire [LOG2T-1:0]   sw_bank  = sw_idx[LOG2T-1:0];
    wire [BANK_AW-1:0] sw_addr  = sw_idx[LOG2T+BANK_AW-1:LOG2T];
    wire [LOG2T-1:0]   sw2_bank = sw2_idx[LOG2T-1:0];
    wire [BANK_AW-1:0] sw2_addr = sw2_idx[LOG2T+BANK_AW-1:LOG2T];

    // Window base and rotation -- REGISTERED into their own stage (a0) before the bank reads.
    //
    // WHY A WHOLE STAGE FOR AN ADD. Combinationally this is base = g_idx-15, then a compare and an
    // increment per bank. Cheap in isolation: the standalone trial synthesis closed at +1.083 ns.
    // But standalone, g_idx is a top-level INPUT, so the tool assumes a registered boundary. Inside
    // sar_resample_v it comes from the coefficient RAM OUTPUT, and the path becomes
    //     cf_mem read -> cf_idx -> base -> rot/baseA -> 32 comparators -> 32 RAM address inputs
    // i.e. RAM output to 32 RAM address inputs in one cycle. That measured -11.302 ns on the
    // 100 MHz domain (46.9 MHz achieved) when the integrated design was synthesised. Registering
    // here makes every bank address a register output, which is what a RAM address wants.
    wire signed [IDX_W:0] base_c = {1'b0, g_idx} - HALF;

    reg  [LOG2T-1:0]   rot0;
    reg  [BANK_AW-1:0] baseA0;
    reg                v0;
    reg  [LOG2P-1:0]   ph0;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin v0 <= 1'b0; rot0 <= 0; baseA0 <= 0; ph0 <= 0; end
        else if (en) begin
            v0     <= g_v & ~g_edge;
            rot0   <= base_c[LOG2T-1:0];
            baseA0 <= base_c[LOG2T+BANK_AW-1:LOG2T];
            ph0    <= g_wq[WQ_W-1 -: LOG2P];
        end
    end

    wire [LOG2T-1:0]   rot   = rot0;
    wire [BANK_AW-1:0] baseA = baseA0;

    reg  [31:0]        sq   [0:TAPS-1];    // bank read data, registered
    reg  [LOG2T-1:0]   rot1;               // rotation, aligned with sq
    reg                v1;
    reg  [LOG2P-1:0]   ph1;

    genvar b;
    generate
        for (b = 0; b < TAPS; b = b + 1) begin : g_bank
            // b < rot -> this bank's window sample lives in the NEXT row of the bank
            wire [BANK_AW-1:0] ra = baseA + ((b < rot) ? 1'b1 : 1'b0);
            // ONE write port per bank. The two fill ports are muxed into a SINGLE
            // enable/address/data triple before the memory, because two distinct write-address
            // expressions on one array defeats RAM inference -- the tool cannot give a RAM two
            // write addresses, so it builds registers instead. Writing it as if/else inside the
            // always block looks equivalent and is not.
            wire               wsel = sw_we && (sw_bank == b[LOG2T-1:0]);
            wire               wen  = wsel || (sw2_we && (sw2_bank == b[LOG2T-1:0]));
            wire [BANK_AW-1:0] wadr = wsel ? sw_addr : sw2_addr;
            wire [31:0]        wdat = wsel ? sw_data : sw2_data;

            // NO READ/WRITE CONFLICT CHECK (synthesis FX107). Sim and hardware would disagree
            // if the same bank address were written and read in the SAME cycle. They never are:
            // the caller fills the line, then gathers from it -- the phases do not overlap, and
            // the bench drives them in that order. If a future caller ever overlaps them, this
            // memory needs syn_ramstyle = rw_check and the mismatch becomes a real risk.
            always @(posedge clk) begin
                // the source WRITE is not part of the gather pipeline: it runs while the core is
                // idle between lines, so it is deliberately NOT gated by en.
                if (wen) sbank[b][wadr] <= wdat;
                if (en)  sq[b] <= sbank[b][ra];
            end
        end
    endgenerate

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin v1 <= 1'b0; rot1 <= 0; ph1 <= 0; end
        else if (en) begin
            v1   <= v0;                          // stage 0 already applied g_edge
            rot1 <= rot0;
            ph1  <= ph0;
        end
    end

    // ============================ multiply ============================
    // tap t takes bank (rot + t) mod TAPS -- the barrel rotation.
    reg signed [31:0] p_hi [0:TAPS-1];
    reg signed [31:0] p_lo [0:TAPS-1];
    reg               v2;
    integer t;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            v2 <= 1'b0;
            for (t = 0; t < TAPS; t = t + 1) begin p_hi[t] <= 0; p_lo[t] <= 0; end
        end else if (en) begin
            v2 <= v1;
            for (t = 0; t < TAPS; t = t + 1) begin
                p_hi[t] <= $signed(sq[(rot1 + t[LOG2T-1:0])][31:16]) * ctab[t][ph1];
                p_lo[t] <= $signed(sq[(rot1 + t[LOG2T-1:0])][15:0])  * ctab[t][ph1];
            end
        end
    end

    // ============================ adder tree ============================
    // 32 -> 16 -> 8 -> 4 -> 2 -> 1 across 5 registered levels, so no level carries more than a
    // 2-input add. At 100 MHz with 0.255 ns of slack a flat sum would not close.
    reg signed [35:0] s1_hi [0:15], s1_lo [0:15];
    reg signed [35:0] s2_hi [0:7],  s2_lo [0:7];
    reg signed [35:0] s3_hi [0:3],  s3_lo [0:3];
    reg signed [35:0] s4_hi [0:1],  s4_lo [0:1];
    reg signed [35:0] s5_hi,        s5_lo;
    reg [4:0] vv;
    integer k;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) vv <= 5'd0;
        else if (en) begin
            vv <= {vv[3:0], v2};
            for (k = 0; k < 16; k = k + 1) begin
                s1_hi[k] <= p_hi[2*k] + p_hi[2*k+1];
                s1_lo[k] <= p_lo[2*k] + p_lo[2*k+1];
            end
            for (k = 0; k < 8; k = k + 1) begin
                s2_hi[k] <= s1_hi[2*k] + s1_hi[2*k+1];
                s2_lo[k] <= s1_lo[2*k] + s1_lo[2*k+1];
            end
            for (k = 0; k < 4; k = k + 1) begin
                s3_hi[k] <= s2_hi[2*k] + s2_hi[2*k+1];
                s3_lo[k] <= s2_lo[2*k] + s2_lo[2*k+1];
            end
            for (k = 0; k < 2; k = k + 1) begin
                s4_hi[k] <= s3_hi[2*k] + s3_hi[2*k+1];
                s4_lo[k] <= s3_lo[2*k] + s3_lo[2*k+1];
            end
            s5_hi <= s4_hi[0] + s4_hi[1];
            s5_lo <= s4_lo[0] + s4_lo[1];
        end
    end

    assign o_busy = v0 | v1 | v2 | (|vv) | o_v;

    // ============================ round, saturate, pack ============================
    // >>> 15 to undo Q15, with round-to-nearest, then clamp to int16. Saturation is REQUIRED:
    // sinc taps overshoot (Gibbs), so a full-scale input can exceed int16 even though the taps
    // sum to unity -- truncating instead of clamping would wrap and produce a black speckle.
    wire signed [36:0] r_hi = s5_hi + 37'sd16384;
    wire signed [36:0] r_lo = s5_lo + 37'sd16384;
    wire signed [21:0] q_hi = r_hi[36:15];
    wire signed [21:0] q_lo = r_lo[36:15];

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin o_v <= 1'b0; o_data <= 32'd0; end
        else if (en) begin
            o_v <= vv[4];
            o_data[31:16] <= (q_hi >  22'sd32767) ? 16'sd32767 :
                             (q_hi < -22'sd32768) ? -16'sd32768 : q_hi[15:0];
            o_data[15:0]  <= (q_lo >  22'sd32767) ? 16'sd32767 :
                             (q_lo < -22'sd32768) ? -16'sd32768 : q_lo[15:0];
        end
    end
endmodule

`default_nettype wire
