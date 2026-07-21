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
`timescale 1ns/1ps
module fft_feeder_v #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 64,
    parameter integer AXI_ID_W   = 4,
    parameter integer MAX_BURST   = 64,      // beats per AR (<=256 for AXI4 INCR)
    parameter integer FIFO_AW      = 9,       // read-data FIFO depth = 512 beats (> MAX_BURST*OUTSTANDING)
    parameter integer TAB_AW       = 12       // window taper: 4096 words x 2 taps = 8192 taps = one row
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
    output reg  [AXI_ID_W-1:0]      m_arid,
    output reg  [AXI_ADDR_W-1:0]    m_araddr,
    output reg  [7:0]               m_arlen,
    output wire [2:0]               m_arsize,
    output wire [1:0]               m_arburst,
    output reg                      m_arvalid,
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

    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;   // simple: latch when both present
    assign s_wready  = s_awready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            src_base <= 0; nbeats <= 0; s_bvalid <= 0; start_pulse <= 0;
            win_scale <= 16'sd0; win_en <= 1'b0; tab_wptr <= 0; tab_we <= 1'b0;
        end else begin
            start_pulse <= 0;
            tab_we      <= 1'b0;
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
                12'h008: s_rdata <= {31'd0, busy};
                12'h00c: s_rdata <= src_base;
                12'h010: s_rdata <= nbeats;
                // [3:0] SCALE_EXP; [18:16] sticky AXI protocol-violation flags. The firmware
                // already reads this register once per row, so a violation is visible without
                // any extra bus traffic -- see fft_fabric_pass().
                12'h014: s_rdata <= {13'd0, err_align, err_rlast, err_extra,
                                     12'd0, scale_exp_latched};
                12'h018: s_rdata <= {15'd0, win_en, win_scale};  // window ctrl readback
                12'h01c: s_rdata <= {{(32-TAB_AW){1'b0}}, tab_wptr};  // taper fill level
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

    wire rbeat = m_rvalid & m_rready;
    assign m_rready = ~fifo_full;

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
    assign m_axis_tdata  = sdata;
    assign m_axis_tvalid = svalid;

    // ===================== AXI4 read-burst master =====================
    assign m_arsize  = (AXI_DATA_W==64) ? 3'b011 : 3'b010; // 8 bytes/beat
    assign m_arburst = 2'b01;                              // INCR
    assign m_arid    = {AXI_ID_W{1'b0}};

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
            state <= S_IDLE; m_arvalid <= 0; m_araddr <= 0; m_arlen <= 0;
            beats_left <= 0; next_addr <= 0; busy <= 0; cur_len <= 0; burst_rem <= 0;
            err_extra <= 1'b0; err_rlast <= 1'b0; err_align <= 1'b0;
        end else begin
            // sticky: an R beat that does not belong to a burst we asked for
            if (rbeat && !beat_ok) err_extra <= 1'b1;
            case (state)
              S_IDLE: begin
                  m_arvalid <= 1'b0;
                  if (start_pulse && nbeats != 0) begin
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
                  end else if (!m_arvalid && (fifo_room >= this_len)) begin
                      // Issue only when the FIFO can hold the whole burst. NOTE: this is a
                      // throughput optimisation, not the safety property -- `fifo_full`
                      // gating m_rready is the independent guard, and with the window stages
                      // in flight fcount CAN reach the cap mid-burst, so RREADY may legally
                      // deassert part-way through a burst. That is harmless.
                      m_araddr  <= next_addr;
                      m_arlen   <= this_len[7:0] - 8'd1;   // AXI len = beats-1
                      cur_len   <= this_len;               // latch what we actually asked for
                      m_arvalid <= 1'b1;
                  end else if (m_arvalid && m_arready) begin
                      m_arvalid  <= 1'b0;
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
endmodule
