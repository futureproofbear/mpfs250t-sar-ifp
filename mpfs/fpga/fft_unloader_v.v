// fft_unloader_v.v -- hand-written replacement for the SmartHLS `fft_unloader`,
// with the magnitude-DETECT stage optionally FUSED into the write path.
//
// WHY (replace the HLS kernel at all): the HLS unloader itself works, but the fused detect
// CANNOT be expressed in SmartHLS on this silicon. The fabric detect kernel (hls_detect) was
// abandoned because SmartHLS mis-synthesizes the signed narrowing `(int16_t)(x >> 16)` as
// UNSIGNED -- it saturated ~50% of the image while PASSING cosim AND a correlation check
// (sar_sequencer.c:119-121, 547-550). So the arithmetic that must be sign-correct is written
// here in explicit `signed` Verilog, and the whole unloader comes with it rather than
// straddling two toolchains. Same reasoning that moved the feeder to fft_feeder_v.v.
//
// WHY (fuse detect): measured on silicon 2026-07-21, detect is 20.6 s of a 79.8 s pipeline --
// the largest single stage and the only one left on the CPU. It reads 512 MB (complex int32)
// and writes 128 MB (uint16). The AZIMUTH FFT's unloader already holds every one of those
// samples as it streams them to DDR, so computing |z| here deletes the entire separate pass,
// exactly as the Hamming window fusion deleted the 6.0 s window pass (fft_feeder_v.v).
//
// Function (identical to fft_unloader when detect is disabled): consume `nbeats` 64-bit beats
// from the gearbox AXI4-Stream and write them to DDR at `dst_base` through an AXI4 write
// master. Beat layout unchanged: 64-bit beat = two complex int32 samples, sample0 = beat[31:0]
// = {I[31:16], Q[15:0]}, sample0 at the LOWER address.
//
// Control is a tiny AXI4-Lite slave that PRESERVES the HLS register contract (sar_kernels.h):
//   +0x08 START/STATUS (W:1=start, R:0=idle/done)   +0x0c ARG0=dst_base   +0x10 ARG1=nbeats
// and adds two registers in the HLS ARG2/ARG3 slots, which the HLS unloader never used:
//   +0x14 STATUS2 (RO, sticky AXI/protocol violation latches)   +0x18 DET_CTRL   +0x1c OBEATS (RO)
//
// ---------------------------------------------------------------------------------------
// FUSED MAGNITUDE DETECT (optional, runtime-enabled -- reg 0x18 bit0)
//
// ARITHMETIC is bit-identical to cpu_detect()/cpu_isqrt() in sar_sequencer.c:463-484:
//     re = SIGNED int16 beat[31:16],  im = SIGNED int16 beat[15:0]
//     mag = floor(sqrt(re*re + im*im)) , clamped to 0xFFFF
// `re`/`im` are declared `wire signed [15:0]` and sliced explicitly -- NOTHING here relies on
// sign inference, because inferred sign is precisely what SmartHLS got wrong. The sqrt is the
// same restoring digit-by-digit algorithm as cpu_isqrt (one = 1<<30, 16 iterations), unrolled
// into 16 FIXED pipeline stages -- no variable-latency loop, one add + one compare/subtract
// per stage so nothing approaches the 16 ns fabric clock (a chained multiply measured ~14 ns
// on this device, so the multiplies are registered separately from the adds too).
//
// Two sqrt pipelines run in parallel (one per sample in the beat) so detect sustains the full
// 1 beat/cycle stream rate; a single shared engine would halve CoreFFT's drain rate.
//
// WHY THE MAGNITUDE IS NOT FINAL -- THE GLOBAL BLOCK EXPONENT:
// fft_fabric_pass() (sar_sequencer.c:188) arms the FFT PER ROW, reads that row's CoreFFT
// SCALE_EXP from feeder reg 0x14, and only AFTER all 8192 rows computes emax = max(exp_i) to
// renormalize every row by >>(emax - exp_i). That maximum does not exist while the rows are
// streaming, so this unloader CANNOT emit final-scale values. It writes each magnitude at its
// row's NATIVE exponent and firmware applies >>(emax - exp_i + headroom) afterwards -- but now
// over 128 MB of uint16 instead of 512 MB of complex int32, and with no sqrt.
// The reordering (magnitude BEFORE the shift, instead of after) is modelled in
// mpfs/host/model_detect_fusion.py: it is never worse than the shipping order (it takes the
// magnitude at full internal precision instead of after an int16 truncate+saturate) and
// diverges by at most 2 LSB. It DOES change the pipeline CRC, so 0xd596c9eb cannot gate it.
//
// OUTPUT WIDTH CHANGES WITH THE MODE. Passthrough: 1 input beat -> 1 output beat (4 B/sample).
// Detect: 2 input beats -> 1 output beat (2 B/sample, four uint16 packed little-endian as
// {m1B, m0B, m1A, m0A} with beat A the earlier/lower-address beat). So the output byte count,
// the per-row dst stride and the burst count all halve; the unloader derives that itself from
// DET_CTRL so ARG1 keeps its ONE meaning -- STREAM beats consumed, always equal to the
// feeder's nbeats. Firmware only changes the dst BASE stride. See the note in the commit.
//
//   +0x18 DET_CTRL  [0]=detect enable (0 = bit-exact legacy passthrough)
`timescale 1ns/1ps

// ---------------------------------------------------------------------------------------
// 16-stage pipelined integer sqrt. floor(sqrt(v)) for v <= 2^32-1, bit-identical to
// cpu_isqrt() in sar_sequencer.c. Latency 16 cycles, II=1, no variable-latency loop.
// Full 34-bit `res` is exported so the caller can apply the same 0xFFFF clamp the CPU does.
// ---------------------------------------------------------------------------------------
module fft_unl_isqrt (
    input  wire        clk,
    input  wire [31:0] v,
    output wire [33:0] res_out
);
    localparam integer W   = 34;      // headroom over the 2^31 worst-case operand
    localparam integer NIT = 16;

    reg [W-1:0] op  [0:NIT];
    reg [W-1:0] res [0:NIT];

    // stage 0 inputs are combinational (op[0]/res[0] are not clocked), so latency == NIT
    always @* begin
        op[0]  = {2'b00, v};
        res[0] = {W{1'b0}};
    end

    genvar i;
    generate
        for (i = 0; i < NIT; i = i + 1) begin : sq
            // `one` = 1 << (30 - 2i), a compile-time constant per stage -> the "adder" is
            // res + constant, i.e. a bit-OR in practice. Declared before first use.
            wire [W-1:0] onec = {{(W-1){1'b0}}, 1'b1} << (30 - 2*i);
            wire [W-1:0] sum  = res[i] + onec;
            wire         ge   = (op[i] >= sum);
            always @(posedge clk) begin
                op[i+1]  <= ge ? (op[i] - sum)              : op[i];
                res[i+1] <= ge ? ((res[i] >> 1) + onec)     : (res[i] >> 1);
            end
        end
    endgenerate

    assign res_out = res[NIT];
endmodule

// ---------------------------------------------------------------------------------------
module fft_unloader_v #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 64,
    parameter integer AXI_ID_W   = 4,
    parameter integer MAX_BURST  = 64,       // beats per AW (<=256 for AXI4 INCR)
    parameter integer FIFO_AW    = 9,        // write-data FIFO depth = 512 beats (> MAX_BURST)
    parameter integer OUTSTAND   = 4         // max AW bursts awaiting a B response
)(
    input  wire                     clk,
    input  wire                     resetn,

    // ---- AXI4-Lite control slave (CPU writes ARG0/ARG1/DET_CTRL/START, polls STATUS) ----
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

    // ---- AXI4-Stream slave from the gearbox (CoreFFT output) ----
    input  wire [AXI_DATA_W-1:0]    s_axis_tdata,
    input  wire                     s_axis_tvalid,
    output wire                     s_axis_tready,

    // ---- AXI4 write master to DDR (FIC0) ----
    output reg  [AXI_ID_W-1:0]      m_awid,
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
    input  wire [AXI_ID_W-1:0]      m_bid,
    input  wire [1:0]               m_bresp,
    input  wire                     m_bvalid,
    output wire                     m_bready
);
    // ===================== forward declarations (ModelSim will not hoist) =====================
    localparam S_IDLE=2'd0, S_ADDR=2'd1, S_WDAT=2'd2, S_DRAIN=2'd3;
    reg  [1:0]              state;
    reg                     busy;
    reg                     start_pulse;
    reg  [AXI_ADDR_W-1:0]   dst_base;      // ARG0 @0x0c
    reg  [31:0]             nbeats;        // ARG1 @0x10 -- INPUT stream beats, both modes
    reg                     det_en;        // DET_CTRL[0] @0x18
    reg  [31:0]             obeats_done;   // output beats actually handed to W (RO @0x1c)
    reg                     err_align;     // dst_base was not 8-byte aligned at START
    reg                     err_bresp;     // a write response was not OKAY/EXOKAY
    reg                     err_bextra;    // a B response arrived with no AW outstanding
    reg                     err_odd;       // detect mode with an odd nbeats -> zero-padded tail
    reg                     err_ovf;       // FIFO push found the FIFO full (reservation bug)
    reg                     err_extra;     // stream beat offered after our count was satisfied

    // ===================== AXI4-Lite control registers =====================
    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;   // latch when both present
    assign s_wready  = s_awready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            dst_base <= 0; nbeats <= 0; s_bvalid <= 0; start_pulse <= 0; det_en <= 1'b0;
        end else begin
            start_pulse <= 1'b0;
            if (s_awready) begin
                case (s_awaddr[11:0])
                    12'h008: start_pulse <= s_wdata[0];     // write 1 -> start
                    12'h00c: dst_base    <= s_wdata[AXI_ADDR_W-1:0];
                    12'h010: nbeats      <= s_wdata;
                    12'h018: det_en      <= s_wdata[0];
                    default: ;
                endcase
                s_bvalid <= 1'b1;
            end else if (s_bvalid & s_bready) begin
                s_bvalid <= 1'b0;
            end
        end
    end
    // read side (STATUS / args / sticky error readback)
    assign s_arready = s_arvalid & ~s_rvalid;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin s_rvalid <= 0; s_rdata <= 0; end
        else if (s_arready) begin
            s_rvalid <= 1'b1;
            case (s_araddr[11:0])
                12'h008: s_rdata <= {31'd0, busy};
                12'h00c: s_rdata <= dst_base;
                12'h010: s_rdata <= nbeats;
                // Sticky protocol/consistency latches. fft_fabric_pass() already polls this
                // kernel once per row, so surfacing them here costs no extra bus traffic --
                // same trick the feeder uses at its 0x14.
                12'h014: s_rdata <= {26'd0, err_extra, err_ovf, err_odd,
                                     err_bextra, err_bresp, err_align};
                12'h018: s_rdata <= {31'd0, det_en};
                12'h01c: s_rdata <= obeats_done;
                default: s_rdata <= 32'd0;
            endcase
        end else if (s_rvalid & s_rready) begin
            s_rvalid <= 1'b0;
        end
    end

    // ===================== output-beat elastic FIFO =====================
    // Holds 64-bit beats already in their FINAL DDR form (passthrough beat, or four packed
    // uint16 magnitudes). The AXI write master drains it.
    (* syn_ramstyle = "lsram" *)
    reg  [AXI_DATA_W-1:0] fifo [0:(1<<FIFO_AW)-1];
    reg  [FIFO_AW:0]      wptr, rptr;
    wire [FIFO_AW:0]      fcount = wptr - rptr;

    // The detect pipeline keeps DET_VLEN input beats in flight between the stream handshake
    // and the FIFO push. Reserve that many slots (+1 margin) so a push can NEVER find the FIFO
    // full -- the stages are free-running and have no handshake to stall them. In detect mode
    // those in-flight beats become at most DET_VLEN/2 output beats, so this is conservative;
    // the reservation is applied in BOTH modes to keep FIFO accounting mode-independent.
    localparam integer DET_VLEN = 19;                    // 1 latch + 1 mul + 1 add + 16 sqrt
    localparam integer FIFO_CAP = (1<<FIFO_AW) - DET_VLEN - 2;
    wire fifo_full  = (fcount >= FIFO_CAP);
    wire fifo_empty = (fcount == 0);
    // TRUE fullness, i.e. actual data loss. Distinct from `fifo_full`, which is only the
    // admission threshold: when the write master is backpressured fcount LEGITIMATELY runs
    // past FIFO_CAP by the in-flight pipeline residue -- that is what the reservation is for,
    // and testing err_ovf against fifo_full made the flag fire on correct behaviour.
    wire fifo_ram_full = (fcount == {1'b1, {FIFO_AW{1'b0}}});

    // ===================== stream acceptance =====================
    reg  [31:0] ibeats_left;                             // stream beats still expected
    wire        want_beat  = busy & (ibeats_left != 32'd0);
    assign s_axis_tready = want_beat & ~fifo_full;
    wire        accept    = s_axis_tvalid & s_axis_tready;

    // Never consume a beat we did not ask for. TREADY is low outside a run, so an extra beat
    // is BACKPRESSURED rather than swallowed -- but it would then silently become beat 0 of
    // the NEXT row, shifting the whole row. Latch it so the sim/HIL gate can see it.
    always @(posedge clk or negedge resetn)
        if (!resetn)                                       err_extra <= 1'b0;
        else if (busy && (ibeats_left == 32'd0) && s_axis_tvalid) err_extra <= 1'b1;

    always @(posedge clk or negedge resetn)
        if (!resetn)          ibeats_left <= 32'd0;
        else if (start_pulse) ibeats_left <= nbeats;
        else if (accept)      ibeats_left <= ibeats_left - 32'd1;

    // valid shift register spanning the detect pipeline; shifted in BOTH modes so the
    // "pipeline empty" test used by S_DRAIN does not depend on det_en.
    reg [DET_VLEN-1:0] vpipe;
    always @(posedge clk or negedge resetn)
        if (!resetn) vpipe <= {DET_VLEN{1'b0}};
        else         vpipe <= {vpipe[DET_VLEN-2:0], accept};
    wire mag_valid = vpipe[DET_VLEN-1];

    // ---- passthrough path: one register stage, pushed directly ----
    reg [AXI_DATA_W-1:0] dP;
    reg                  vP;
    always @(posedge clk) dP <= s_axis_tdata;
    always @(posedge clk or negedge resetn) if (!resetn) vP <= 1'b0; else vP <= accept;

    // ---- detect stage 0: latch the beat ----
    reg [AXI_DATA_W-1:0] dS0;
    always @(posedge clk) dS0 <= s_axis_tdata;

    // ---- detect stage 1: the four squares. EXPLICITLY SIGNED -- this is the exact slice the
    // SmartHLS detect kernel got wrong (it treated the high half as unsigned, saturating ~50%
    // of the image while passing cosim). Do not remove the `signed` qualifiers. ----
    wire signed [15:0] re0 = dS0[31:16];    // sample0 I  (lower DDR address)
    wire signed [15:0] im0 = dS0[15:0];     // sample0 Q
    wire signed [15:0] re1 = dS0[63:48];    // sample1 I
    wire signed [15:0] im1 = dS0[47:32];    // sample1 Q
    reg  [31:0] rr0, ii0, rr1, ii1;         // squares are non-negative; max 2^30
    always @(posedge clk) begin
        rr0 <= re0 * re0;  ii0 <= im0 * im0;
        rr1 <= re1 * re1;  ii1 <= im1 * im1;
    end

    // ---- detect stage 2: the sums (registered SEPARATELY from the multiplies: a chained
    // multiply-add measured ~14 ns here against a 16 ns budget) ----
    reg [31:0] v0, v1;                      // max 2^31, fits unsigned 32
    always @(posedge clk) begin
        v0 <= rr0 + ii0;
        v1 <= rr1 + ii1;
    end

    // ---- detect stages 3..18: two 16-stage sqrt pipelines ----
    wire [33:0] root0, root1;
    fft_unl_isqrt u_sq0 (.clk(clk), .v(v0), .res_out(root0));
    fft_unl_isqrt u_sq1 (.clk(clk), .v(v1), .res_out(root1));

    // same clamp cpu_detect() applies: (m > 0xFFFF) ? 0xFFFF : m. Unreachable for int16
    // operands (max root is 46340) but kept so the two paths are provably identical.
    wire [15:0] mag0 = (|root0[33:16]) ? 16'hFFFF : root0[15:0];
    wire [15:0] mag1 = (|root1[33:16]) ? 16'hFFFF : root1[15:0];

    // ---- detect pack: two input beats -> one 64-bit output beat, little-endian ----
    // beat A (earlier, lower address) supplies [31:0]; beat B supplies [63:32].
    reg [31:0] half_lo;
    reg        obit;                        // 0 = next magnitude pair is the LOW half
    wire       tail_flush = busy && (ibeats_left == 32'd0) && (vpipe == {DET_VLEN{1'b0}})
                            && obit && det_en;
    wire       push_det   = det_en & ((mag_valid & obit) | tail_flush);
    wire [AXI_DATA_W-1:0] det_word = tail_flush ? {32'd0, half_lo}
                                                : {mag1, mag0, half_lo};
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin obit <= 1'b0; half_lo <= 32'd0; err_odd <= 1'b0; end
        else if (start_pulse) begin obit <= 1'b0; end
        else if (det_en && mag_valid) begin
            if (!obit) half_lo <= {mag1, mag0};
            obit <= ~obit;
        end else if (tail_flush) begin
            // nbeats was ODD in detect mode: the last output beat is half real, half zero.
            // Never happens with SAR_ROW_BEATS=4096, but pad deterministically and say so.
            obit    <= 1'b0;
            err_odd <= 1'b1;
        end
    end

    // ---- FIFO push (exactly one of the two paths is live; det_en is static during a run) ----
    wire                  push  = det_en ? push_det : vP;
    wire [AXI_DATA_W-1:0] pdata = det_en ? det_word : dP;
    always @(posedge clk) if (push) fifo[wptr[FIFO_AW-1:0]] <= pdata;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin wptr <= 0; err_ovf <= 1'b0; end
        else begin
            if (push) wptr <= wptr + 1'b1;
            if (push && fifo_ram_full) err_ovf <= 1'b1;   // reservation broken -- data WAS lost
        end
    end

    // ===================== AXI4 write-burst master =====================
    assign m_awsize  = (AXI_DATA_W==64) ? 3'b011 : 3'b010;   // 8 bytes/beat
    assign m_awburst = 2'b01;                                // INCR
    assign m_wstrb   = {(AXI_DATA_W/8){1'b1}};               // always full beats
    assign m_bready  = 1'b1;

    reg  [31:0]           obeats_left;      // output beats still to request
    reg  [AXI_ADDR_W-1:0] next_addr;
    reg  [31:0]           cur_len;          // length of the burst actually issued
    reg  [8:0]            wrem;             // W beats still owed for the burst in flight
    reg  [8:0]            load_rem;         // beats still to pop from the FIFO into `sdata`
    reg  [3:0]            b_out;            // AW bursts awaiting a B response
    localparam [3:0]      OUTSTAND_MAX = OUTSTAND;   // truncated to the b_out counter width

    // total output beats: detect packs 2 input beats into 1 output beat
    wire [31:0] otot = det_en ? ((nbeats + 32'd1) >> 1) : nbeats;

    // next burst length: min(MAX_BURST, obeats_left, beats to the next 4 KB boundary)
    wire [31:0] blk_to_4k = (32'd4096 - {20'd0, next_addr[11:0]}) >> 3;
    wire [31:0] cap_burst = (obeats_left < MAX_BURST) ? obeats_left : MAX_BURST;
    wire [31:0] len_raw   = (blk_to_4k < cap_burst) ? blk_to_4k : cap_burst;
    // Same clamp as fft_feeder_v: if next_addr[11:0] > 4088 then blk_to_4k == 0, which would
    // encode m_awlen = 0-1 = 0xFF (a 256-beat burst that blows past the FIFO) and subtract 0
    // from obeats_left, so the FSM would never terminate and `busy` would never drop.
    // Unreachable today (every dst row base is 4 KB-aligned) but one firmware edit away.
    wire [31:0] this_len  = (len_raw == 32'd0) ? 32'd1 : len_raw;

    // Issue AW only once the WHOLE burst is already in the FIFO, so W can never underrun and
    // we never hold AW open against data the stream has not produced yet.
    wire have_burst = ({{(31-FIFO_AW){1'b0}}, fcount} >= this_len);

    // FIFO -> W show-ahead register. Loading is gated on `load_rem`, which is only non-zero
    // after an AW has been accepted for those beats -- otherwise a beat parked in `sdata`
    // would be missing from `fcount` and the final short burst would never be admitted.
    reg  [AXI_DATA_W-1:0] sdata;
    reg                   svalid;
    wire ram_has   = (wptr != rptr);
    assign m_wvalid = (state == S_WDAT) & svalid;
    assign m_wdata  = sdata;
    assign m_wlast  = (wrem == 9'd1);
    wire wconsume  = m_wvalid & m_wready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin rptr <= 0; svalid <= 1'b0; end
        else begin
            if (wconsume) svalid <= 1'b0;
            if ((~svalid | wconsume) & ram_has & (load_rem != 9'd0)) begin
                sdata  <= fifo[rptr[FIFO_AW-1:0]];
                rptr   <= rptr + 1'b1;
                svalid <= 1'b1;
            end
        end
    end

    // ---- B channel: count what we ISSUED, do not assume ordering or a bounded slave --------
    // FIC0 IDs are narrowed by sar_axi_idconv.v, so B responses can arrive out of order and a
    // misrouted one can land here. Track outstanding count only; never key completion off a
    // particular BID, and latch a sticky flag on a response we did not earn or a non-OKAY resp.
    wire aw_accept = m_awvalid & m_awready;
    wire b_accept  = m_bvalid  & m_bready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            b_out <= 4'd0; err_bresp <= 1'b0; err_bextra <= 1'b0;
        end else begin
            case ({aw_accept, b_accept})
                2'b10: b_out <= b_out + 4'd1;
                2'b01: b_out <= b_out - 4'd1;
                default: ;
            endcase
            if (b_accept && (b_out == 4'd0) && !aw_accept) err_bextra <= 1'b1;
            if (b_accept && (m_bresp[1] == 1'b1))          err_bresp  <= 1'b1;
        end
    end

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= S_IDLE; busy <= 1'b0; m_awvalid <= 1'b0; m_awaddr <= 0; m_awlen <= 0;
            m_awid <= {AXI_ID_W{1'b0}};
            obeats_left <= 32'd0; next_addr <= 0; cur_len <= 32'd0;
            wrem <= 9'd0; load_rem <= 9'd0; obeats_done <= 32'd0; err_align <= 1'b0;
        end else begin
            case (state)
              S_IDLE: begin
                  m_awvalid <= 1'b0;
                  if (start_pulse && nbeats != 32'd0) begin
                      obeats_left <= otot;
                      next_addr   <= dst_base;
                      obeats_done <= 32'd0;
                      busy        <= 1'b1;
                      state       <= S_ADDR;
                      if (dst_base[2:0] != 3'd0) err_align <= 1'b1;   // see the this_len clamp
                  end
              end
              S_ADDR: begin
                  if (obeats_left == 32'd0) begin
                      state <= S_DRAIN;
                  end else if (!m_awvalid && have_burst && (b_out < OUTSTAND_MAX)) begin
                      m_awaddr  <= next_addr;
                      m_awlen   <= this_len[7:0] - 8'd1;    // AXI len = beats-1
                      cur_len   <= this_len;
                      m_awvalid <= 1'b1;
                  end else if (m_awvalid && m_awready) begin
                      m_awvalid <= 1'b0;
                      wrem      <= cur_len[8:0];
                      load_rem  <= cur_len[8:0];
                      state     <= S_WDAT;
                  end
              end
              S_WDAT: begin
                  if (wconsume) begin
                      obeats_done <= obeats_done + 32'd1;
                      wrem        <= wrem - 9'd1;
                      if (wrem == 9'd1) begin
                          obeats_left <= obeats_left - cur_len;
                          next_addr   <= next_addr + (cur_len << 3);   // *8 bytes/beat
                          state       <= S_ADDR;
                      end
                  end
                  if ((~svalid | wconsume) & ram_has & (load_rem != 9'd0))
                      load_rem <= load_rem - 9'd1;
              end
              S_DRAIN: begin
                  // Do NOT drop `busy` until the detect stages have emptied, the FIFO has
                  // drained AND every B response is home. fft_fabric_pass() reads SCALE_EXP
                  // and arms the next row the moment both kernels report idle; reporting done
                  // with writes still in flight would let the next row's feed overtake this
                  // row's data on a non-coherent FIC0.
                  if (fifo_empty && !svalid && !vP && (vpipe == {DET_VLEN{1'b0}})
                      && !obit && (b_out == 4'd0) && (ibeats_left == 32'd0)) begin
                      busy  <= 1'b0;
                      state <= S_IDLE;
                  end
              end
              default: state <= S_IDLE;
            endcase
        end
    end
endmodule
