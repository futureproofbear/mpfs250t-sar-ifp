// fft_feeder_v.v -- hand-written replacement for the SmartHLS `fft_feeder`.
//
// WHY: the SmartHLS 2026 mem->STREAM kernel (axi_initiator read -> hls::FIFO AXI4-Stream
// master) synthesizes to DEAD RTL on silicon -- the read master issues ZERO reads
// (rd_cnt=0, arvalid=0) despite correct config. Root-caused via SmartDebug 2026-07-08
// (see SILICON_ISO_TEST_RUNBOOK.md §8). Every WORKING kernel (corner_turn/resample) is
// mem->mem; fft_feeder is the only mem->stream one -- the AXI4-Stream master output is
// the SmartHLS-broken piece. So we do exactly that piece in plain Verilog.
//
// Function (identical to fft_feeder): read `nbeats` 64-bit beats from DDR starting at
// `src_base` via an AXI4 read master, and emit them on an AXI4-Stream master to the
// gearbox. Word layout unchanged: 64-bit beat = two 32-bit complex samples {I<<16|Q}.
//
// Control is a tiny AXI4-Lite slave matching the HLS reg map (sar_kernels.h):
//   +0x08 START/STATUS (W:1=start, R:0=idle/done)   +0x0c ARG0=src_base   +0x10 ARG1=nbeats
//
// Read master: INCR bursts of up to MAX_BURST 64-bit beats, up to OUTSTANDING in flight,
// data pushed into an elastic FIFO that the AXI4-Stream drains with TREADY backpressure
// (so the CoreFFT/gearbox rate-matches the feed, exactly like the HLS version intended).
//
// ---------------------------------------------------------------------------------------
// FUSED 2-D HAMMING WINDOW (optional, runtime-enabled -- reg 0x18 bit16)
//
// WHY: the window was a separate full-frame fabric pass (SCRATCH->SCRATCH, 512 MB read +
// 512 MB write, 6.0 s of an 87.6 s pipeline). It is a pure element-wise multiply on data
// this feeder ALREADY reads, so folding it into the feed path deletes the pass outright.
// MEASURED on silicon 2026-07-21: window stage 6.0 -> 0.000 s, pipeline -> 79.79 s, ROI crc
// 0xd596c9eb UNCHANGED, and the FFT passes did not slow down (25.06 s vs 25.07 s) -- the
// multiplies are genuinely free. err_extra/err_rlast/err_align all 0 over 16,384 row arms.
// It lives here (Verilog) and NOT in the HLS resample kernel because fusing it there was
// tried and hit two distinct SmartHLS silicon miscompiles -- see SMARTHLS_ANTIPATTERNS.md.
//
// ARITHMETIC is bit-identical to hls_window/window.cpp (so the pipeline CRC is unchanged):
//     cw = (int16)((hamr[row] * hamc[k]) >> 15)      Q15, truncating (arithmetic) shift
//     re = (int16)((I * cw) >> 15) ,  im = (int16)((Q * cw) >> 15)
// hamr indexes the ROW (range) and is loop-invariant across a row -> the CPU writes it as a
// scalar in the same 0x18 write that arms the row. hamc indexes the COLUMN (cross) and is
// held on-chip in `wtab`. Zero-pad is handled for free: both tapers are zero there.
//
// TAPER LOAD: the CPU pushes 4096 packed words {hamc[2i+1],hamc[2i]} to 0x1c against an
// auto-incrementing pointer (rewound by 0x18 bit17). A 64-bit beat carries 2 samples and a
// table word carries 2 taps, so table entry n serves beat n 1:1 -- one RAM read per beat,
// no mux, depth == beats/row. Deliberately NOT a DMA: a second mode in the read FSM would
// have to arbitrate for AR/R against the row feed, and the one-time ~1.3 ms of AXI4-Lite
// writes is free against the 6.0 s saved.
//
// PLACEMENT: the multiply sits on the FIFO WRITE side (3 registered stages between rbeat
// and the FIFO push), not between the FIFO and the stream output. The write side has no
// handshake to disturb: the stages are free-running and gated only by their own valid
// flags, and PIPE_D slots are reserved in the FIFO so a push can never find it full. (They
// do NOT rely on the burst never stalling -- RREADY may legally deassert mid-burst once the
// in-flight residue pushes fcount to the cap.) The stream-side show-ahead logic is untouched.
// The stages run in BOTH modes (bypassing the multiply when disabled) so FIFO accounting and
// drain latency are mode-independent.
//
//   +0x18 WIN_CTRL  [15:0]=hamr[row] Q15 signed, [16]=window enable, [17]=rewind tab pointer
//   +0x1c WIN_TAB   [31:0]={hamc[2i+1], hamc[2i]}, written 4096x, pointer auto-increments
//
// ---------------------------------------------------------------------------------------
// ON-FABRIC COEFFICIENTS (optional, runtime-enabled -- reg 0x20 bit1)
//
// WHY: silicon 2026-07-25 decomposes FFT-1 (11.46 s of a 32.97 s frame) as RPROF[6] azimuth
// coefficient generation 4.170 s + [7] arm 0.011 s + [8] renormalize epilogue 2.933 s +
// [9] residual fabric wait 4.344 s. sar_coeffgen.v generates the SAME coefficients in fabric at
// ~147 us/row vs 1499 us/row single-hart on the CPU, and streaming them straight in here also
// deletes the G_IDX + G_WQ load passes -- 6144 of this row's 8961 read beats (68.6%) -- and the
// CPU's per-row coefficient-bank L2 flush along with them.
//
// THE DDR PATH IS KEPT AND IS THE DEFAULT. Bit1 selects the source at RUNTIME because a fabric
// build costs hours: if the fused path misbehaves on silicon we must be able to A/B against the
// DDR path in the SAME bitstream. IDX_BASE/WQ_BASE and the six idx/wq banks therefore stay.
// Bit1 == 0 out of reset, so this build is behaviour-neutral until deliberately switched.
//
// VALUE-NEUTRALITY is the property the A/B rests on, and it is structural: the stream entry is
// captured at ISSUE into c_idx_r/c_wq_r, i.e. exactly where the registered bank reads land, so
// stage 1 sees the same numbers on the same cycle and every stage after it is untouched.
// Proven in simulation by tb/tb_fft_feeder_gather.v's A/B cases (same row, both settings,
// beat-for-beat compare).
//
//   +0x20 GATHER_CTRL [0]=gather enable, [1]=coefficients from STREAM (0 = from DDR, default)
`timescale 1ns/1ps
module fft_feeder_v #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 64,
    parameter integer AXI_ID_W   = 4,
    parameter integer MAX_BURST   = 64,      // beats per AR (<=256 for AXI4 INCR)
    parameter integer FIFO_AW      = 9,       // read-data FIFO depth = 512 beats (> MAX_BURST*OUTSTANDING)
    parameter integer TAB_AW       = 12,      // window taper: 4096 words x 2 taps = 8192 taps = one row
    // ---- fused azimuth-resample GATHER (runtime-enabled -- reg 0x20 bit0) ----
    parameter integer G_BUF_AW     = 12,      // source-row bank depth: 4096 x 2 banks = 8192 samples
    parameter integer G_TAB_AW     = 13,      // idx/wq entries per row (8192); idx banks 2^12, wq banks 2^11
    parameter integer G_SFIFO_AW   = 9        // gather stream FIFO depth = 512 beats
)(
    input  wire                     clk,
    input  wire                     resetn,

    // ---- AXI4-Lite control slave (CPU writes ARG0/ARG1/START, polls STATUS) ----
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

    // ---- AXI4 read master to DDR (FIC0) ----
    // AR outputs are muxed at the port between the legacy window-feed master (l_*) and the
    // gather load master (g_*); both are plain regs inside, the port is a wire.
    output wire [AXI_ID_W-1:0]      m_arid,
    output wire [AXI_ADDR_W-1:0]    m_araddr,
    output wire [7:0]               m_arlen,
    output wire [2:0]               m_arsize,
    output wire [1:0]               m_arburst,
    output wire                     m_arvalid,
    input  wire                     m_arready,
    input  wire [AXI_ID_W-1:0]      m_rid,
    input  wire [AXI_DATA_W-1:0]    m_rdata,
    input  wire                     m_rlast,
    input  wire                     m_rvalid,
    output wire                     m_rready,

    // ---- AXI4-Stream master to the gearbox ----
    output wire [AXI_DATA_W-1:0]    m_axis_tdata,
    output wire                     m_axis_tvalid,
    input  wire                     m_axis_tready,

    // ---- coefficient stream from sar_coeffgen (fused gather, reg 0x20 bit1) ----------------
    // One {idx, wq} entry per output qi, strictly in qi order, QN entries per row -- byte-for-byte
    // what the G_IDX/G_WQ DDR passes load today. c_ready is independent of c_valid (a slot is
    // "wanted" purely from gstate/g_left/gen), so there is no valid<-ready dependency.
    // When GATHER_CTRL[1] == 0 these are UNUSED and the feeder is bit-unchanged from today.
    input  wire signed [31:0]       c_idx,
    input  wire [15:0]              c_wq,
    input  wire                     c_valid,
    output wire                     c_ready,

    // ---- CoreFFT block-floating-point exponent capture (for the pipeline's global-block-
    // exponent renormalize; see sar_sequencer.c fft_fabric_pass). CoreFFT drives SCALE_EXP
    // (valid while OUTP_READY asserted, per the UG); we latch it at each frame boundary
    // (OUTP_READY falling edge) and expose the last frame's exponent at control reg 0x14.
    // With PER-ROW arming the CPU reads reg 0x14 after each row -> that row's exp_i. ----
    input  wire [3:0]               scale_exp_in,
    input  wire                     outp_ready_in
);
    localparam integer BYTES_PER_BEAT = AXI_DATA_W/8;      // 8

    // ---- read-master state + R-channel acceptance qualifier -------------------------
    // Declared here (ahead of the datapath) because the window pipeline and the control
    // register readback both reference them. Semantics documented at the FSM below.
    localparam S_IDLE=2'd0, S_ADDR=2'd1, S_DATA=2'd2, S_DRAIN=2'd3;
    reg [1:0] state;
    reg [8:0] burst_rem;                  // beats still expected in the burst in flight
    reg       err_extra;                  // R beat arrived outside an expected burst
    reg       err_rlast;                  // RLAST disagreed with our own beat count
    reg       err_align;                  // src_base was not 8-byte aligned at START
    wire      beat_ok = (state == S_DATA) && (burst_rem != 9'd0);

    // ---- forward declarations for the fused azimuth-resample GATHER engine ----------
    // (full datapath at the bottom of the module; declared here because the AR/stream/status
    // port muxes and the control readback reference them.) gmode==1 means the gather load
    // master owns the AXI read + stream ports; when 0 the feeder is BIT-UNCHANGED from today.
    reg                    gath_busy;
    reg                    g_err_extra, g_err_rlast, g_err_align;
    wire                   gmode;
    wire                   g_rready;
    reg  [AXI_ADDR_W-1:0]  g_araddr;
    reg  [7:0]             g_arlen;
    reg                    g_arvalid;
    reg  [AXI_DATA_W-1:0]  g_sdata;
    reg                    g_svalid;

    // ---- SCALE_EXP latch: capture on OUTP_READY falling edge, hold until next frame ----
    reg [3:0] scale_exp_latched;
    reg       outp_ready_d;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin scale_exp_latched <= 4'd0; outp_ready_d <= 1'b0; end
        else begin
            outp_ready_d <= outp_ready_in;
            if (outp_ready_d & ~outp_ready_in) scale_exp_latched <= scale_exp_in;  // falling edge
        end
    end

    // ===================== AXI4-Lite control registers =====================
    reg [AXI_ADDR_W-1:0] src_base;      // ARG0 @0x0c
    reg [31:0]           nbeats;        // ARG1 @0x10
    reg                  busy;          // STATUS @0x08 (1 while running)
    reg                  start_pulse;
    reg signed [15:0]    win_scale;     // WIN_CTRL[15:0] @0x18 -- hamr[row], Q15
    reg                  win_en;        // WIN_CTRL[16]
    reg [TAB_AW-1:0]     tab_wptr;      // auto-incrementing WIN_TAB write pointer
    reg                  tab_we;
    reg [TAB_AW-1:0]     tab_waddr;     // address captured WITH the data (tab_wptr has moved on)
    reg [31:0]           tab_wdata;
    // ---- gather control (all above 0x1c; wrapper addr decode widened to 6 bits, see top.v) ----
    reg                  gath_en;       // GATHER_CTRL[0]  @0x20
    // GATHER_CTRL[1]: coefficient SOURCE select. 0 (reset default) = the DDR G_IDX/G_WQ load
    // passes below, exactly as shipped; 1 = the {c_idx,c_wq} stream from sar_coeffgen. Runtime,
    // NOT a rebuild: a fabric build takes hours, so both coefficient paths stay in the SAME
    // bitstream and can be A/B'd on silicon. IDX_BASE/WQ_BASE keep their decode for that reason.
    reg                  cstream_en;    // GATHER_CTRL[1]  @0x20
    // GATHER_CTRL[2]: 32-tap polyphase-sinc gather instead of the 2-tap lerp. Same "add beside,
    // never replace" rule as pass 1 -- both kernels are in the bitstream, this resets LOW, so a
    // cold boot gets exactly today's silicon-verified 2-tap behaviour and the two can be A/B'd on
    // one board run. GATHER_CTRL[3] rewinds the sinc coefficient-table write pointer.
    reg                  sinc_en;       // GATHER_CTRL[2]  @0x20
    reg                  sct_rewind;    // GATHER_CTRL[3]  @0x20 (one-shot)
    reg                  sct_we;        // SINC_TAB        @0x30 (one-shot)
    reg [15:0]           sct_data;
    reg [AXI_ADDR_W-1:0] idx_base;      // IDX_BASE        @0x24  DDR byte addr of this row's idx[]
    reg [AXI_ADDR_W-1:0] wq_base;       // WQ_BASE         @0x28  DDR byte addr of this row's wq[]
    reg [15:0]           src_len;       // GATHER_DIMS[15:0] @0x2c  S = source SAMPLE count
    reg [15:0]           q_n;           // GATHER_DIMS[31:16]@0x2c  QN = output SAMPLE count (even)

    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;   // simple: latch when both present
    assign s_wready  = s_awready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            src_base <= 0; nbeats <= 0; s_bvalid <= 0; start_pulse <= 0;
            win_scale <= 16'sd0; win_en <= 1'b0; tab_wptr <= 0; tab_we <= 1'b0;
            gath_en <= 1'b0; cstream_en <= 1'b0;
            sinc_en <= 1'b0; sct_rewind <= 1'b0; sct_we <= 1'b0; sct_data <= 16'd0;
            idx_base <= 0; wq_base <= 0; src_len <= 16'd0; q_n <= 16'd0;
        end else begin
            start_pulse <= 0;
            tab_we      <= 1'b0;
            sct_rewind  <= 1'b0;
            sct_we      <= 1'b0;
            if (s_awready) begin
                case (s_awaddr[11:0])
                    12'h008: start_pulse <= s_wdata[0];    // write 1 -> start
                    12'h00c: src_base    <= s_wdata[AXI_ADDR_W-1:0];
                    12'h010: nbeats      <= s_wdata;
                    12'h018: begin
                        win_scale <= s_wdata[15:0];
                        win_en    <= s_wdata[16];
                        if (s_wdata[17]) tab_wptr <= 0;    // rewind taper write pointer
                    end
                    12'h01c: begin                          // taper word, pointer auto-increments
                        tab_wdata <= s_wdata;
                        tab_waddr <= tab_wptr;              // write lands next cycle at THIS addr
                        tab_we    <= 1'b1;
                        tab_wptr  <= tab_wptr + 1'b1;
                    end
                    12'h020: begin                          // GATHER_CTRL
                        gath_en    <= s_wdata[0];
                        cstream_en <= s_wdata[1];
                        sinc_en    <= s_wdata[2];
                        sct_rewind <= s_wdata[3];
                    end
                    12'h024: idx_base <= s_wdata[AXI_ADDR_W-1:0];
                    12'h028: wq_base  <= s_wdata[AXI_ADDR_W-1:0];
                    12'h02c: begin src_len <= s_wdata[15:0]; q_n <= s_wdata[31:16]; end
                    12'h030: begin                          // SINC_TAB, pointer auto-increments
                        sct_data <= s_wdata[15:0];
                        sct_we   <= 1'b1;
                    end
                    default: ;
                endcase
                s_bvalid <= 1'b1;
            end else if (s_bvalid & s_bready) begin
                s_bvalid <= 1'b0;
            end
        end
    end
    // read side of the control slave (STATUS/args readback)
    assign s_arready = s_arvalid & ~s_rvalid;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin s_rvalid <= 0; s_rdata <= 0; end
        else if (s_arready) begin
            s_rvalid <= 1'b1;
            case (s_araddr[11:0])
                12'h008: s_rdata <= {31'd0, busy | gath_busy};
                12'h00c: s_rdata <= src_base;
                12'h010: s_rdata <= nbeats;
                // [3:0] SCALE_EXP; [18:16] sticky AXI protocol-violation flags (legacy OR gather).
                // The firmware already reads this register once per row, so a violation is visible
                // without any extra bus traffic -- see fft_fabric_pass().
                12'h014: s_rdata <= {13'd0, err_align | g_err_align, err_rlast | g_err_rlast,
                                     err_extra | g_err_extra, 12'd0, scale_exp_latched};
                12'h018: s_rdata <= {15'd0, win_en, win_scale};  // window ctrl readback
                12'h01c: s_rdata <= {{(32-TAB_AW){1'b0}}, tab_wptr};  // taper fill level
                12'h020: s_rdata <= {30'd0, cstream_en, gath_en};
                12'h024: s_rdata <= idx_base;
                12'h028: s_rdata <= wq_base;
                12'h02c: s_rdata <= {q_n, src_len};
                default: s_rdata <= 32'd0;
            endcase
        end else if (s_rvalid & s_rready) begin
            s_rvalid <= 1'b0;
        end
    end

    // ===================== read-data elastic FIFO =====================
    (* syn_ramstyle = "lsram" *)
    reg  [AXI_DATA_W-1:0] fifo [0:(1<<FIFO_AW)-1];
    reg  [FIFO_AW:0]      wptr, rptr;
    wire [FIFO_AW:0]      fcount = wptr - rptr;
    // The window stages put PIPE_D beats in flight between rbeat and the FIFO push, so `fcount`
    // understates true occupancy by up to PIPE_D. Reserve that many slots (+1 margin) in BOTH
    // the full flag and the burst-room test, or a burst could be admitted that no longer fits.
    localparam integer PIPE_D   = 3;
    localparam integer FIFO_CAP = (1<<FIFO_AW) - PIPE_D - 1;
    wire fifo_full  = (fcount >= FIFO_CAP);
    wire [FIFO_AW:0]      fifo_room = fifo_full ? {(FIFO_AW+1){1'b0}}
                                                : (FIFO_CAP[FIFO_AW:0] - fcount);
    wire fifo_empty = (fcount == 0);

    // Legacy R acceptance. When the gather engine owns the bus (gmode) the legacy master is idle
    // and MUST NOT see the gather's R beats (they would spuriously latch err_extra), so gate with
    // ~gmode. m_rready itself is muxed to whichever master is active (see the port muxes below).
    wire l_rready = ~fifo_full;
    wire rbeat    = ~gmode & m_rvalid & l_rready;

    // ---- window taper: 4096 words, each {hamc[2i+1], hamc[2i]} in Q15 ----
    (* syn_ramstyle = "lsram" *)
    reg [31:0] wtab [0:(1<<TAB_AW)-1];
    always @(posedge clk) if (tab_we) wtab[tab_waddr] <= tab_wdata;

    // Beat index within the current row IS the taper word index (2 samples/beat, 2 taps/word).
    // Advanced only by beats we actually asked for (`beat_ok`), so a stray R beat cannot
    // shift the taper alignment for the rest of the row.
    reg [TAB_AW-1:0] beat_idx;
    always @(posedge clk or negedge resetn)
        if (!resetn)              beat_idx <= 0;
        else if (start_pulse)     beat_idx <= 0;
        else if (rbeat & beat_ok) beat_idx <= beat_idx + 1'b1;

    // ---- stage A: latch the beat, issue the taper read (RAM read latency 1) ----
    reg [AXI_DATA_W-1:0] dA; reg vA; reg [31:0] tapA;
    always @(posedge clk) begin
        dA   <= m_rdata;
        tapA <= wtab[beat_idx];        // beat_idx increments on this same edge -> reads THIS beat
    end
    always @(posedge clk or negedge resetn) if (!resetn) vA <= 1'b0; else vA <= rbeat & beat_ok;

    // ---- stage B: cw = (int16)((hamr[row] * hamc[k]) >> 15). p[30:15] == (p>>>15)[15:0] ----
    reg [AXI_DATA_W-1:0] dB; reg vB; reg signed [15:0] cw0B, cw1B;
    wire signed [15:0] t0 = tapA[15:0];      // hamc[2i]   -> sample 0 (lower address)
    wire signed [15:0] t1 = tapA[31:16];     // hamc[2i+1] -> sample 1
    wire signed [31:0] p0 = win_scale * t0;
    wire signed [31:0] p1 = win_scale * t1;
    always @(posedge clk) begin
        dB <= dA; cw0B <= p0[30:15]; cw1B <= p1[30:15];
    end
    always @(posedge clk or negedge resetn) if (!resetn) vB <= 1'b0; else vB <= vA;

    // ---- stage C: out = (int16)((sample * cw) >> 15), then push ----
    wire signed [15:0] i0 = dB[31:16], q0 = dB[15:0];    // sample 0 = beat[31:0],  {I,Q}
    wire signed [15:0] i1 = dB[63:48], q1 = dB[47:32];   // sample 1 = beat[63:32], {I,Q}
    wire signed [31:0] mi0 = i0 * cw0B, mq0 = q0 * cw0B;
    wire signed [31:0] mi1 = i1 * cw1B, mq1 = q1 * cw1B;
    wire [AXI_DATA_W-1:0] windowed = {mi1[30:15], mq1[30:15], mi0[30:15], mq0[30:15]};
    reg [AXI_DATA_W-1:0] dC; reg vC;
    // win_en is only rewritten while the feeder is idle (CPU writes 0x18 before START, and
    // S_DRAIN has flushed the stages), so sampling it here cannot split a row.
    always @(posedge clk) dC <= win_en ? windowed : dB;
    always @(posedge clk or negedge resetn) if (!resetn) vC <= 1'b0; else vC <= vB;

    always @(posedge clk) if (vC) fifo[wptr[FIFO_AW-1:0]] <= dC;
    always @(posedge clk or negedge resetn)
        if (!resetn)  wptr <= 0;
        else if (vC)  wptr <= wptr + 1'b1;

    // show-ahead read -> AXI4-Stream out
    reg  [AXI_DATA_W-1:0] sdata;
    reg                   svalid;
    wire ram_has = (wptr != rptr);
    wire s_consume = svalid & m_axis_tready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin rptr <= 0; svalid <= 0; end
        else begin
            if (s_consume) svalid <= 1'b0;
            if ((~svalid | s_consume) & ram_has) begin
                sdata  <= fifo[rptr[FIFO_AW-1:0]];
                rptr   <= rptr + 1'b1;
                svalid <= 1'b1;
            end
        end
    end
    // Stream output is muxed: legacy window-feed (sdata/svalid) vs gather (g_sdata/g_svalid).
    assign m_axis_tdata  = gmode ? g_sdata  : sdata;
    assign m_axis_tvalid = gmode ? g_svalid : svalid;

    // ===================== AXI4 read-burst master (LEGACY window feed) =====================
    // AR is muxed with the gather load master at the port. m_arsize/m_arburst/m_arid are the same
    // constants for both, so they are driven unconditionally.
    reg [AXI_ADDR_W-1:0] l_araddr;    // legacy AR address (port is a wire)
    reg [7:0]            l_arlen;     // legacy AR len
    reg                  l_arvalid;   // legacy AR valid
    assign m_arsize  = (AXI_DATA_W==64) ? 3'b011 : 3'b010; // 8 bytes/beat
    assign m_arburst = 2'b01;                              // INCR
    assign m_arid    = {AXI_ID_W{1'b0}};
    assign m_araddr  = gmode ? g_araddr  : l_araddr;
    assign m_arlen   = gmode ? g_arlen   : l_arlen;
    assign m_arvalid = gmode ? g_arvalid : l_arvalid;
    assign m_rready  = gmode ? g_rready  : l_rready;

    reg [31:0] beats_left;        // beats still to request
    reg [AXI_ADDR_W-1:0] next_addr;
    reg [31:0] cur_len;           // length of the burst actually issued (latched at AR accept)

    // next burst length: min(MAX_BURST, beats_left, and don't cross a 4KB boundary)
    wire [31:0] blk_to_4k = (32'd4096 - {20'd0, next_addr[11:0]}) >> 3;  // 64-bit beats to next 4KB
    wire [31:0] cap_burst = (beats_left < MAX_BURST) ? beats_left : MAX_BURST;
    wire [31:0] len_raw   = (blk_to_4k < cap_burst) ? blk_to_4k : cap_burst;
    // Clamp to >=1. If next_addr[11:0] > 4088 then blk_to_4k == 0, which would encode
    // m_arlen = 0-1 = 0xFF -- a 256-BEAT burst that blows past the FIFO reservation (the
    // admission test `fifo_room >= 0` is trivially true) -- and subtract 0 from beats_left,
    // so the FSM never terminates and `busy` never drops. Unreachable today because every
    // row base is BUF_SCRATCH + row*32768 (4KB-aligned), but it is one firmware edit away
    // (a debug byte offset, a non-power-of-two stride) and simulation cannot reach it.
    wire [31:0] this_len  = (len_raw == 32'd0) ? 32'd1 : len_raw;

    // SINGLE outstanding burst: issue AR, receive the whole burst, repeat.
    // CoreFFT consumes at <=1 sample/cyc so one burst in flight is ample.
    //
    // ---- R-channel acceptance qualifier + protocol-violation latches ----------------
    // Do NOT treat the slave's RLAST as the sole authority on how many beats belong to this
    // burst. AXI IDs are narrowed on this path (sar_axi_idconv.v) and m_arid is assigned
    // downstream, so a stray or misrouted R beat lands here and is accepted unconditionally.
    // Before the window was fused that corrupted one beat; NOW it also shifts beat_idx for
    // the entire remainder of the row, so every later sample is multiplied by the wrong
    // taper -- a smooth, plausible amplitude error that survives a correlation check and
    // looks nothing like an AXI fault. So count what we asked for, admit only that into the
    // pipeline, and latch a sticky flag on any discrepancy.
    // Extra beats are ACCEPTED-AND-DISCARDED rather than stalled: deasserting RREADY at a
    // slave that still believes it owes us data deadlocks the interconnect.
    // (burst_rem / err_* / beat_ok are declared at the top of the module.)

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= S_IDLE; l_arvalid <= 0; l_araddr <= 0; l_arlen <= 0;
            beats_left <= 0; next_addr <= 0; busy <= 0; cur_len <= 0; burst_rem <= 0;
            err_extra <= 1'b0; err_rlast <= 1'b0; err_align <= 1'b0;
        end else begin
            // sticky: an R beat that does not belong to a burst we asked for
            if (rbeat && !beat_ok) err_extra <= 1'b1;
            case (state)
              S_IDLE: begin
                  l_arvalid <= 1'b0;
                  // In gather mode the load master owns the bus; the legacy feed stays idle.
                  if (start_pulse && nbeats != 0 && !gath_en) begin
                      beats_left <= nbeats;
                      next_addr  <= src_base;
                      busy       <= 1'b1;
                      state      <= S_ADDR;
                      if (src_base[2:0] != 3'd0) err_align <= 1'b1;   // see this_len clamp
                  end
              end
              S_ADDR: begin
                  if (beats_left == 0) begin
                      state <= S_DRAIN;
                  end else if (!l_arvalid && (fifo_room >= this_len)) begin
                      // Issue only when the FIFO can hold the whole burst. NOTE: this is a
                      // throughput optimisation, not the safety property -- `fifo_full`
                      // gating m_rready is the independent guard, and with the window stages
                      // in flight fcount CAN reach the cap mid-burst, so RREADY may legally
                      // deassert part-way through a burst. That is harmless.
                      l_araddr  <= next_addr;
                      l_arlen   <= this_len[7:0] - 8'd1;   // AXI len = beats-1
                      cur_len   <= this_len;               // latch what we actually asked for
                      l_arvalid <= 1'b1;
                  end else if (l_arvalid && m_arready) begin
                      l_arvalid  <= 1'b0;
                      burst_rem  <= cur_len[8:0];
                      state      <= S_DATA;
                  end
              end
              S_DATA: begin
                  if (rbeat && beat_ok) begin
                      burst_rem <= burst_rem - 9'd1;
                      // RLAST must coincide with OUR last expected beat, in both directions
                      if (m_rlast != (burst_rem == 9'd1)) err_rlast <= 1'b1;
                      // terminate on our own count, NOT on the slave's RLAST
                      if (burst_rem == 9'd1) begin
                          beats_left <= beats_left - cur_len;
                          next_addr  <= next_addr + (cur_len << 3);   // *8 bytes/beat
                          state      <= S_ADDR;
                      end
                  end
              end
              S_DRAIN: begin
                  // must also wait for the window stages, or DONE could be reported with beats
                  // still in flight -> the CPU reads SCALE_EXP / arms the next row too early
                  if (fifo_empty && !svalid && !vA && !vB && !vC) begin
                      busy  <= 1'b0;
                      state <= S_IDLE;
                  end
              end
              default: state <= S_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // FUSED AZIMUTH-RESAMPLE GATHER  (optional, runtime-enabled -- reg 0x20 bit0)
    //
    // WHY: the azimuth resample was a separate fabric pass -- a per-row linear-interpolation
    // GATHER that wrote a 128 MB frame to SCRATCH which THIS feeder (FFT-1) then read back
    // (~1.65 ms/line, DDR-round-trip bound). CoreFFT consumes at ~1 sample / 8 SLOWCLK, so the
    // feeder has ample slack to DO the gather as it streams, deleting the separate stage AND the
    // SCRATCH round-trip. Same fuse-into-the-feed pattern as the window (above) and the detect
    // (in the unloader).
    //
    // PER ROW: (1) burst-read the source row into on-chip banks, (2) burst-read this row's idx[]
    // and wq[] coefficient tables into on-chip banks, (3) for i in 0..QN-1 gather+lerp
    //   out[i] = lerp(src[idx[i]], src[idx[i]+1], wq[i])   (Q15, idx<0||idx>=S-1 -> zero fill)
    // then apply the EXISTING 2-D Hamming window multiply (hamr=win_scale, hamc=wtab[i]) and push
    // to the stream FIFO. Reads are three SEQUENTIAL bursts; the gather/stream phase is
    // CoreFFT-rate-limited, so a serial load-then-stream per row still hides under the FFT.
    //
    // ARITHMETIC is bit-identical to hls_resample/resample.cpp (lerp) followed by
    // hls_window/window.cpp (window), so an A/B against a gather-then-window reference validates.
    // All fixed-point multiplies are EXPLICIT `signed`; no two multiplies are chained in a cycle.
    // =====================================================================================
    localparam integer IDXB_AW = G_TAB_AW - 1;   // idx bank depth (2 banks, 2 int32/beat)
    localparam integer WQB_AW  = G_TAB_AW - 2;   // wq  bank depth (4 banks, 4 int16/beat)

    localparam G_IDLE=3'd0, G_SRC=3'd1, G_IDX=3'd2, G_WQ=3'd3, G_GATHER=3'd4, G_DRAIN=3'd5;
    localparam GA_IDLE=2'd0, GA_ADDR=2'd1, GA_DATA=2'd2;
    reg [2:0] gstate;
    reg [1:0] grstate;
    reg [1:0] gpass;                  // 0=SRC 1=IDX 2=WQ

    // latched-at-start per-row parameters (a late AXI4-Lite write cannot split a row)
    reg [15:0]           gr_srclen, gr_qn;
    reg [AXI_ADDR_W-1:0] gr_srcbase, gr_idxbase, gr_wqbase;
    reg                  gr_cstream;    // GATHER_CTRL[1] latched at START (same rule)
    // Latched for a HARDER reason than the others: sinc_en changes the gather pipeline DEPTH
    // (9 vs 4). A mid-row change would leave results from two different latencies interleaved in
    // the output FIFO -- a misordered row, not a wrong sample, and it would not look like a
    // coefficient bug at all.
    reg                  gr_sinc;

    // gather load master (own copy; the legacy feed master stays idle while gath_busy)
    reg [31:0]           g_beats_left;
    reg [AXI_ADDR_W-1:0] g_next_addr;
    reg [31:0]           g_cur_len;
    reg [8:0]            g_burst_rem;
    reg [15:0]           g_wn;         // beat index within the CURRENT pass (write address)

    assign gmode    = gath_busy;
    // rready is asserted across the WHOLE load pass (not just GA_DATA) so a stray/misrouted R beat
    // arriving between bursts is ACCEPTED-AND-DISCARDED and latches err_extra -- rather than
    // stalling the interconnect -- exactly as the legacy master does. Banks always have room.
    assign g_rready = (gstate==G_SRC) || (gstate==G_IDX) || (gstate==G_WQ);
    wire g_beat_ok  = (grstate == GA_DATA) && (g_burst_rem != 9'd0);
    wire g_rbeat    = gmode & m_rvalid & g_rready;
    wire g_store    = g_rbeat & g_beat_ok;

    // pass beat counts: IDX 2 int32/beat, WQ 4 int16/beat. SRC uses live src_len at start (below).
    wire [31:0] idx_beats = ({16'd0, gr_qn} + 32'd1) >> 1;
    wire [31:0] wq_beats  = ({16'd0, gr_qn} + 32'd3) >> 2;

    // burst length: min(MAX_BURST, beats_left, distance-to-4KB), clamped >=1 (see legacy this_len)
    wire [31:0] g_blk4k    = (32'd4096 - {20'd0, g_next_addr[11:0]}) >> 3;
    wire [31:0] g_cap      = (g_beats_left < MAX_BURST) ? g_beats_left : MAX_BURST;
    wire [31:0] g_lenraw   = (g_blk4k < g_cap) ? g_blk4k : g_cap;
    wire [31:0] g_this_len = (g_lenraw == 32'd0) ? 32'd1 : g_lenraw;

    // ---- on-chip banks -------------------------------------------------------------------
    // srcbuf split by sample parity (even/odd) so buf[j] and buf[j+1] read in one cycle.
    // idxbuf 2 banks (entry i in bank i&1 @ i>>1); wqbuf 4 banks (entry i in bank i&3 @ i>>2).
    (* syn_ramstyle = "lsram" *) reg [31:0] buf_e   [0:(1<<G_BUF_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] buf_o   [0:(1<<G_BUF_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] idxbuf0 [0:(1<<IDXB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [31:0] idxbuf1 [0:(1<<IDXB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [15:0] wqbuf0  [0:(1<<WQB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [15:0] wqbuf1  [0:(1<<WQB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [15:0] wqbuf2  [0:(1<<WQB_AW)-1];
    (* syn_ramstyle = "lsram" *) reg [15:0] wqbuf3  [0:(1<<WQB_AW)-1];
    reg [31:0] buf_e_q, buf_o_q, idxbuf0_q, idxbuf1_q;
    reg [15:0] wqbuf0_q, wqbuf1_q, wqbuf2_q, wqbuf3_q;
    reg [31:0] g_wtab_q;                          // 2 hamc taps {tap[2m+1],tap[2m]}

    // output-index issue
    reg [G_TAB_AW-1:0] gi;
    reg [15:0]         g_left;
    wire gen;                                     // pipeline enable (gather stream FIFO room)
    // g_want = an output slot is wanted this cycle. In DDR-coefficient mode that IS the issue
    // (the banks are already loaded); in stream mode the issue additionally needs a coefficient.
    // c_ready is derived from g_want, NOT from g_issue, so READY never depends on VALID.
    wire g_want  = (gstate == G_GATHER) && (g_left != 16'd0);
    wire g_issue = g_want && (!gr_cstream || c_valid);
    assign c_ready = gen & g_want & gr_cstream;

    // ---- gather pipeline stage registers -------------------------------------------------
    reg               g0_v;
    reg               g0_sel0;                    // gi[0]   (idx bank + tap half)
    reg [1:0]         g0_sel;                     // gi[1:0] (wq bank)
    // Stream coefficients captured AT ISSUE, so they are presented to stage 1 on exactly the same
    // cycle the bank outputs (registered RAM reads addressed by gi) would be -- the two sources
    // are latency-matched by construction, which is what makes the runtime select value-neutral.
    reg signed [31:0] c_idx_r;
    reg        [15:0] c_wq_r;
    reg               g1_v, g1_val, g1_idx0;
    reg [15:0]        g1_wq;
    reg signed [31:0] g1_cwp;                     // win_scale*tap  (window 1st multiply)
    reg               g2_v, g2_val;
    reg [15:0]        g2_wq;
    reg signed [16:0] g2_dhi, g2_dlo;
    reg signed [15:0] g2_ahi, g2_alo, g2_cw;
    reg               g3_v, g3_val;
    reg signed [32:0] g3_mh, g3_ml;
    reg signed [15:0] g3_ahi, g3_alo, g3_cw;
    reg               g4_v;
    reg signed [15:0] g4_hi, g4_lo, g4_cw;
    reg               g5_v;
    reg [31:0]        g5_samp;

    // combinational bank-read address for the source banks (declared here, used by the RAM procs)
    wire [G_BUF_AW-1:0] ge_ra, go_ra;

    // ---- RAM read/write address muxes (load phase writes @g_wn; gather phase reads) --------
    wire [G_BUF_AW-1:0] be_addr = (gstate==G_GATHER) ? ge_ra : g_wn[G_BUF_AW-1:0];
    wire [G_BUF_AW-1:0] bo_addr = (gstate==G_GATHER) ? go_ra : g_wn[G_BUF_AW-1:0];
    wire buf_we = g_store & (gpass==2'd0);
    always @(posedge clk) begin
        if (buf_we) buf_e[be_addr] <= m_rdata[31:0];
        buf_e_q <= buf_e[be_addr];
    end
    always @(posedge clk) begin
        if (buf_we) buf_o[bo_addr] <= m_rdata[63:32];
        buf_o_q <= buf_o[bo_addr];
    end

    wire [IDXB_AW-1:0] idx_addr = (gstate==G_GATHER) ? gi[G_TAB_AW-1:1] : g_wn[IDXB_AW-1:0];
    wire idx_we = g_store & (gpass==2'd1);
    always @(posedge clk) begin
        if (idx_we) idxbuf0[idx_addr] <= m_rdata[31:0];
        idxbuf0_q <= idxbuf0[idx_addr];
    end
    always @(posedge clk) begin
        if (idx_we) idxbuf1[idx_addr] <= m_rdata[63:32];
        idxbuf1_q <= idxbuf1[idx_addr];
    end

    wire [WQB_AW-1:0] wq_addr = (gstate==G_GATHER) ? gi[G_TAB_AW-1:2] : g_wn[WQB_AW-1:0];
    wire wq_we = g_store & (gpass==2'd2);
    always @(posedge clk) begin
        if (wq_we) wqbuf0[wq_addr] <= m_rdata[15:0];
        wqbuf0_q <= wqbuf0[wq_addr];
    end
    always @(posedge clk) begin
        if (wq_we) wqbuf1[wq_addr] <= m_rdata[31:16];
        wqbuf1_q <= wqbuf1[wq_addr];
    end
    always @(posedge clk) begin
        if (wq_we) wqbuf2[wq_addr] <= m_rdata[47:32];
        wqbuf2_q <= wqbuf2[wq_addr];
    end
    always @(posedge clk) begin
        if (wq_we) wqbuf3[wq_addr] <= m_rdata[63:48];
        wqbuf3_q <= wqbuf3[wq_addr];
    end

    // Second reader of the window taper (wtab). The legacy stage-A read is untouched; synthesis
    // replicates wtab for this independent read port. Output sample i -> hamc[i] = wtab[i>>1] half.
    always @(posedge clk) g_wtab_q <= wtab[gi[TAB_AW:1]];

    // ---- stage-1 combinational: pick idx/wq/tap, range-check, form source-bank addresses -----
    // Coefficient SOURCE mux (the only value-carrying difference between the two modes).
    // Everything downstream -- g_inr1, ge_ra/go_ra, the lerp and the fused window -- is untouched.
    wire signed [31:0] idx1_ddr = g0_sel0 ? $signed(idxbuf1_q) : $signed(idxbuf0_q);
    wire        [15:0] wq1_ddr  = (g0_sel==2'd0) ? wqbuf0_q :
                                  (g0_sel==2'd1) ? wqbuf1_q :
                                  (g0_sel==2'd2) ? wqbuf2_q : wqbuf3_q;
    wire signed [31:0] idx1 = gr_cstream ? c_idx_r : idx1_ddr;
    wire        [15:0] wq1  = gr_cstream ? c_wq_r  : wq1_ddr;
    wire signed [15:0] tap1 = g0_sel0 ? g_wtab_q[31:16] : g_wtab_q[15:0];
    wire signed [31:0] g_sm1 = $signed({16'd0, gr_srclen}) - 32'sd1;   // S-1
    wire g_inr1 = (idx1 >= 0) && (idx1 < g_sm1);
    assign ge_ra = idx1[0] ? (idx1[G_BUF_AW:1] + 1'b1) : idx1[G_BUF_AW:1];
    assign go_ra = idx1[G_BUF_AW:1];

    // ---- stage-2 combinational: source pair (bufA=src[j], bufB=src[j+1]) ---------------------
    wire [31:0] bufA = g1_idx0 ? buf_o_q : buf_e_q;
    wire [31:0] bufB = g1_idx0 ? buf_e_q : buf_o_q;

    // ---- stage-3 combinational: lerp multiply  (b-a)*w, w Q15 (>=0), 33-bit exact -----------
    wire signed [32:0] sh_hi = {{16{g2_dhi[16]}}, g2_dhi} * $signed({1'b0, g2_wq});
    wire signed [32:0] sh_lo = {{16{g2_dlo[16]}}, g2_dlo} * $signed({1'b0, g2_wq});

    // ---- stage-4 combinational: lerp add  a + ((b-a)*w >>> 15) ------------------------------
    wire signed [17:0] r_hi = {{2{g3_ahi[15]}}, g3_ahi} + g3_mh[32:15];
    wire signed [17:0] r_lo = {{2{g3_alo[15]}}, g3_alo} + g3_ml[32:15];

    // =============================================================================================
    // 32-TAP SINC GATHER (GATHER_CTRL[2]) -- the azimuth-pass twin of pass 1's sar_resample_v
    // integration. Runs BESIDE the lerp: both kernels stay in the bitstream, gr_sinc resets LOW.
    //
    // WHY A SINC KERNEL IS EVEN LEGAL HERE. Pass 1's source grid is x0 + j*dx, so sinc(n-15-mu) is
    // exact. THIS pass gathers along tau = tan(phi), which is NOT uniform -- a sinc indexed by mu
    // assumes the 32 taps under the window are equally spaced, and they are not. Measured on the
    // real Umbra NDSU CPHD by mpfs/host/check_pass2_sinc_uniformity.py: within any 32-tap window
    // tau's spacing varies by max/min = 1.00045 (0.05%), even though it varies 3.1% across a whole
    // row. Locally flat is all the kernel needs, and reconstruction error matches a uniform-grid
    // control to within a dB (-34 dB sinc vs -13..-22 dB lerp). Without that measurement this
    // would be an unfalsifiable build: RTL and model would share the same wrong kernel and every
    // bit-exactness bench would pass.
    //
    // LATENCY, and it is the whole difficulty. The sinc core is 9 cycles from g_v; the lerp result
    // lands in g4 at 4. So the lerp and its window coefficient delay by 5 to meet it, and the edge
    // flag delays by 9 from g0_v so the select lands on the RIGHT query. Get this wrong and the row
    // comes out misordered or short -- a hang or a truncated row, not a wrong value.
    //
    // EDGE queries are NOT answered by the sinc core (g_edge tells it so); they fall back to the
    // delayed lerp, which is asserted for every query. That matters more here than in pass 1: a
    // pass-2 row is M pulses (2042 at deci=4) against pass 1's 8192, so the 31-sample edge band is
    // 1.52% of the row rather than 0.38%.
    // =============================================================================================
    localparam integer S_TAPS = 32;
    localparam integer S_HALF = S_TAPS/2 - 1;                  // 15
    localparam integer S_IDXW = 14;

    // window wholly in range?  idx >= 15  AND  idx <= S-17.  g_inr1 already covers idx<0 / idx>=S-1.
    wire signed [31:0] s_lo_lim = 32'sd15;
    wire signed [31:0] s_hi_lim = $signed({16'd0, gr_srclen}) - 32'sd17;
    wire        s_edge = ~g_inr1 | (idx1 < s_lo_lim) | (idx1 > s_hi_lim);

    // fill: one 64-bit beat carries two consecutive samples -> both write ports, different banks.
    // Sample index is 2*g_wn (even half) and 2*g_wn+1 (odd half), matching buf_e/buf_o above.
    wire [S_IDXW-1:0] s_wn_lo = {g_wn[S_IDXW-2:0], 1'b0};
    wire [S_IDXW-1:0] s_wn_hi = {g_wn[S_IDXW-2:0], 1'b1};
    wire s_lo_ok = buf_we && ({16'd0, s_wn_lo} < {16'd0, gr_srclen});
    wire s_hi_ok = buf_we && ({16'd0, s_wn_hi} < {16'd0, gr_srclen});

    wire        s_ov, s_busy;
    wire [31:0] s_odata;

    sar_sinc32_gather #(.IDX_W(S_IDXW), .WQ_W(15)) u_sinc (
        .clk(clk), .resetn(resetn),
        .ct_we(sct_we), .ct_data($signed(sct_data)), .ct_rewind(sct_rewind),
        .sw_we (s_lo_ok), .sw_idx (s_wn_lo), .sw_data (m_rdata[31:0]),
        .sw2_we(s_hi_ok), .sw2_idx(s_wn_hi), .sw2_data(m_rdata[63:32]),
        .en(gen), .g_v(g0_v), .g_idx(idx1[S_IDXW-1:0]), .g_wq(wq1[14:0]), .g_edge(s_edge),
        .o_v(s_ov), .o_data(s_odata), .o_busy(s_busy)
    );

    // lerp + window coefficient delayed by 5 (4 -> 9); edge flag delayed by 9 from g0_v.
    reg  [4:0]         d_v;
    reg signed [15:0]  d_hi [0:4];
    reg signed [15:0]  d_lo [0:4];
    reg signed [15:0]  d_cw [0:4];
    reg  [8:0]         e_pipe;
    integer di;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            d_v <= 5'd0; e_pipe <= 9'd0;
            for (di = 0; di < 5; di = di + 1) begin
                d_hi[di] <= 16'sd0; d_lo[di] <= 16'sd0; d_cw[di] <= 16'sd0;
            end
        end else if (gen) begin
            d_v      <= {d_v[3:0], g4_v};
            d_hi[0]  <= g4_hi;  d_lo[0] <= g4_lo;  d_cw[0] <= g4_cw;
            for (di = 1; di < 5; di = di + 1) begin
                d_hi[di] <= d_hi[di-1]; d_lo[di] <= d_lo[di-1]; d_cw[di] <= d_cw[di-1];
            end
            e_pipe   <= {e_pipe[7:0], s_edge & g0_v};
        end
    end

    // ONE output per query either way: in sinc mode the VALID comes from the delayed lerp (which is
    // asserted for every query, edge or not); only the DATA is switched.
    wire               gsel_v  = gr_sinc ? d_v[4] : g4_v;
    wire signed [15:0] gsel_hi = gr_sinc ? (e_pipe[8] ? d_hi[4] : $signed(s_odata[31:16])) : g4_hi;
    wire signed [15:0] gsel_lo = gr_sinc ? (e_pipe[8] ? d_lo[4] : $signed(s_odata[15:0]))  : g4_lo;
    wire signed [15:0] gsel_cw = gr_sinc ? d_cw[4] : g4_cw;

    // ---- stage-5 combinational: window multiply  (gathered * cw) >>> 15 ----------------------
    wire signed [31:0] wm_i = $signed(gsel_hi) * $signed(gsel_cw);
    wire signed [31:0] wm_q = $signed(gsel_lo) * $signed(gsel_cw);
    wire [31:0] g5_win  = {wm_i[30:15], wm_q[30:15]};   // windowed {I,Q}
    wire [31:0] g5_pass = {gsel_hi, gsel_lo};           // gathered  {I,Q} (window disabled)

    // ---- gather + window pipeline (all stages frozen together by `gen` backpressure) ---------
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            g0_v<=0; g1_v<=0; g2_v<=0; g3_v<=0; g4_v<=0; g5_v<=0;
            g0_sel0<=0; g0_sel<=0; c_idx_r<=32'sd0; c_wq_r<=16'd0;
            g1_val<=0; g1_idx0<=0; g1_wq<=0; g1_cwp<=32'sd0;
            g2_val<=0; g2_wq<=0; g2_dhi<=17'sd0; g2_dlo<=17'sd0; g2_ahi<=0; g2_alo<=0; g2_cw<=0;
            g3_val<=0; g3_mh<=33'sd0; g3_ml<=33'sd0; g3_ahi<=0; g3_alo<=0; g3_cw<=0;
            g4_hi<=0; g4_lo<=0; g4_cw<=0;
            g5_samp<=32'd0;
        end else if (gen) begin
            g0_v    <= g_issue;
            g0_sel0 <= gi[0];
            g0_sel  <= gi[1:0];
            if (g_issue) begin c_idx_r <= c_idx; c_wq_r <= c_wq; end

            g1_v    <= g0_v;
            g1_val  <= g_inr1;
            g1_idx0 <= idx1[0];
            g1_wq   <= wq1;
            g1_cwp  <= win_scale * tap1;

            g2_v    <= g1_v;
            g2_val  <= g1_val;
            g2_wq   <= g1_wq;
            g2_dhi  <= $signed(bufB[31:16]) - $signed(bufA[31:16]);
            g2_dlo  <= $signed(bufB[15:0])  - $signed(bufA[15:0]);
            g2_ahi  <= bufA[31:16];
            g2_alo  <= bufA[15:0];
            g2_cw   <= g1_cwp[30:15];

            g3_v    <= g2_v;
            g3_val  <= g2_val;
            g3_mh   <= sh_hi;
            g3_ml   <= sh_lo;
            g3_ahi  <= g2_ahi;
            g3_alo  <= g2_alo;
            g3_cw   <= g2_cw;

            g4_v    <= g3_v;
            g4_hi   <= g3_val ? r_hi[15:0] : 16'sd0;   // zero-fill out-of-range BEFORE the window
            g4_lo   <= g3_val ? r_lo[15:0] : 16'sd0;
            g4_cw   <= g3_cw;

            g5_v    <= gsel_v;
            g5_samp <= win_en ? g5_win : g5_pass;
        end
    end

    // issue counter
    always @(posedge clk or negedge resetn) begin
        if (!resetn)                    begin gi <= 0; g_left <= 16'd0; end
        else if (gstate != G_GATHER)    begin gi <= 0; g_left <= gr_qn; end
        else if (gen && g_issue)        begin gi <= gi + 1'b1; g_left <= g_left - 1'b1; end
    end

    // ---- pack two samples/beat -> gather stream FIFO ----------------------------------------
    reg [31:0] g_word; reg g_word_v;
    (* syn_ramstyle = "lsram" *) reg [AXI_DATA_W-1:0] gfifo [0:(1<<G_SFIFO_AW)-1];
    reg  [G_SFIFO_AW:0] gwptr, grptr;
    wire [G_SFIFO_AW:0] gcount = gwptr - grptr;
    localparam integer G_SFIFO_CAP = (1<<G_SFIFO_AW) - 2;
    wire g_sfull  = (gcount >= G_SFIFO_CAP);
    wire g_sempty = (gcount == 0);
    assign gen = ~g_sfull;

    wire g_push = gen & g5_v & g_word_v;                 // push on the SECOND sample of a pair
    always @(posedge clk or negedge resetn) begin
        if (!resetn)                 begin g_word <= 32'd0; g_word_v <= 1'b0; end
        else if (gstate == G_IDLE)   begin g_word_v <= 1'b0; end
        else if (gen & g5_v) begin
            if (!g_word_v) begin g_word <= g5_samp; g_word_v <= 1'b1; end   // even sample -> low half
            else                g_word_v <= 1'b0;                           // odd sample -> push
        end
    end
    always @(posedge clk) if (g_push) gfifo[gwptr[G_SFIFO_AW-1:0]] <= {g5_samp, g_word};
    always @(posedge clk or negedge resetn) begin
        if (!resetn)                gwptr <= 0;
        else if (gstate == G_IDLE)  gwptr <= 0;
        else if (g_push)            gwptr <= gwptr + 1'b1;
    end

    // show-ahead read -> stream (muxed onto m_axis when gmode)
    wire g_has     = (gwptr != grptr);
    wire g_consume = g_svalid & m_axis_tready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn)                begin grptr <= 0; g_svalid <= 1'b0; end
        else if (gstate == G_IDLE)  begin grptr <= 0; g_svalid <= 1'b0; end
        else begin
            if (g_consume) g_svalid <= 1'b0;
            if ((~g_svalid | g_consume) & g_has) begin
                g_sdata  <= gfifo[grptr[G_SFIFO_AW-1:0]];
                grptr    <= grptr + 1'b1;
                g_svalid <= 1'b1;
            end
        end
    end

    // ---- gather sequencer: 3 read passes, then gather/stream, then drain --------------------
    // Must include the sinc core and the 5-deep delay chain. Without them the row completes while
    // sinc results are still in flight: the FIFO gets fewer samples than QN and the FFT is armed on
    // a short row -- which presents as a hang or a truncated line, never as a wrong sample value.
    wire g_pipe_empty = !g0_v && !g1_v && !g2_v && !g3_v && !g4_v && !g5_v && !g_word_v
                        && (d_v == 5'd0) && !s_busy;
    wire gather_done  = (g_left == 16'd0) && g_pipe_empty;
    wire g_drained    = g_sempty && !g_svalid;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            gstate <= G_IDLE; grstate <= GA_IDLE; gpass <= 2'd0; gath_busy <= 1'b0;
            g_arvalid <= 1'b0; g_araddr <= 0; g_arlen <= 8'd0;
            g_beats_left <= 32'd0; g_next_addr <= 0; g_cur_len <= 32'd0; g_burst_rem <= 9'd0;
            g_wn <= 16'd0;
            g_err_extra <= 1'b0; g_err_rlast <= 1'b0; g_err_align <= 1'b0;
            gr_srclen <= 16'd0; gr_qn <= 16'd0; gr_cstream <= 1'b0; gr_sinc <= 1'b0;
            gr_srcbase <= 0; gr_idxbase <= 0; gr_wqbase <= 0;
        end else begin
            // sticky: a stray/misrouted R beat during a load pass must not silently shift a bank
            if (g_rbeat && !g_beat_ok) g_err_extra <= 1'b1;
            case (gstate)
              G_IDLE: begin
                  g_arvalid <= 1'b0;
                  if (start_pulse && gath_en) begin
                      gr_srclen  <= src_len;   gr_qn      <= q_n;
                      gr_srcbase <= src_base;  gr_idxbase <= idx_base;  gr_wqbase <= wq_base;
                      gr_cstream <= cstream_en;
                      gr_sinc    <= sinc_en;
                      gath_busy  <= 1'b1;
                      gpass      <= 2'd0;
                      g_next_addr  <= src_base;
                      g_beats_left <= ({16'd0, src_len} + 32'd1) >> 1;    // ceil(S/2) source beats
                      g_wn         <= 16'd0;
                      grstate      <= GA_ADDR;
                      gstate       <= G_SRC;
                      if (src_base[2:0]!=3'd0 || idx_base[2:0]!=3'd0 || wq_base[2:0]!=3'd0 ||
                          q_n[0] || q_n==16'd0 || src_len < 16'd2)
                          g_err_align <= 1'b1;
                  end
              end
              G_SRC, G_IDX, G_WQ: begin
                  case (grstate)
                    GA_ADDR: begin
                        if (g_beats_left == 32'd0) begin
                            // gr_cstream: the SOURCE row is still loaded from DDR, but G_IDX/G_WQ
                            // are skipped outright -- that is the 6144-of-8961 read-beat saving.
                            if (gpass == 2'd2 || gr_cstream) begin
                                grstate <= GA_IDLE;
                                gstate  <= G_GATHER;
                            end else begin
                                gpass <= gpass + 2'd1;
                                g_wn  <= 16'd0;
                                if (gpass == 2'd0) begin
                                    g_next_addr  <= gr_idxbase; g_beats_left <= idx_beats;
                                    gstate       <= G_IDX;
                                end else begin
                                    g_next_addr  <= gr_wqbase;  g_beats_left <= wq_beats;
                                    gstate       <= G_WQ;
                                end
                                grstate <= GA_ADDR;
                            end
                        end else if (!g_arvalid) begin
                            g_araddr  <= g_next_addr;
                            g_arlen   <= g_this_len[7:0] - 8'd1;
                            g_cur_len <= g_this_len;
                            g_arvalid <= 1'b1;
                        end else if (g_arvalid && m_arready) begin
                            g_arvalid   <= 1'b0;
                            g_burst_rem <= g_cur_len[8:0];
                            grstate     <= GA_DATA;
                        end
                    end
                    GA_DATA: begin
                        if (g_store) begin
                            g_wn        <= g_wn + 16'd1;
                            g_burst_rem <= g_burst_rem - 9'd1;
                            if (m_rlast != (g_burst_rem == 9'd1)) g_err_rlast <= 1'b1;
                            if (g_burst_rem == 9'd1) begin
                                g_beats_left <= g_beats_left - g_cur_len;
                                g_next_addr  <= g_next_addr + (g_cur_len << 3);
                                grstate      <= GA_ADDR;
                            end
                        end
                    end
                    default: grstate <= GA_IDLE;
                  endcase
              end
              G_GATHER: begin
                  if (gather_done) gstate <= G_DRAIN;
              end
              G_DRAIN: begin
                  if (g_drained) begin gath_busy <= 1'b0; gstate <= G_IDLE; end
              end
              default: gstate <= G_IDLE;
            endcase
        end
    end
endmodule
