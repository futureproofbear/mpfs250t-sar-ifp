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
`timescale 1ns/1ps
module fft_feeder_v #(
    parameter integer AXI_ADDR_W = 32,
    parameter integer AXI_DATA_W = 64,
    parameter integer AXI_ID_W   = 4,
    parameter integer MAX_BURST   = 64,      // beats per AR (<=256 for AXI4 INCR)
    parameter integer FIFO_AW      = 9        // read-data FIFO depth = 512 beats (> MAX_BURST*OUTSTANDING)
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

    assign s_awready = s_awvalid & s_wvalid & ~s_bvalid;   // simple: latch when both present
    assign s_wready  = s_awready;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            src_base <= 0; nbeats <= 0; s_bvalid <= 0; start_pulse <= 0;
        end else begin
            start_pulse <= 0;
            if (s_awready) begin
                case (s_awaddr[11:0])
                    12'h008: start_pulse <= s_wdata[0];    // write 1 -> start
                    12'h00c: src_base    <= s_wdata[AXI_ADDR_W-1:0];
                    12'h010: nbeats      <= s_wdata;
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
                12'h014: s_rdata <= {28'd0, scale_exp_latched};  // last frame's CoreFFT SCALE_EXP
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
    wire fifo_full  = (fcount == (1<<FIFO_AW));
    wire [FIFO_AW:0]      fifo_room = ((1<<FIFO_AW) - fcount);   // free slots (must be wide, not 1-bit!)
    wire fifo_empty = (fcount == 0);

    // push read data
    wire rbeat = m_rvalid & m_rready;
    assign m_rready = ~fifo_full;
    always @(posedge clk) if (rbeat) fifo[wptr[FIFO_AW-1:0]] <= m_rdata;
    always @(posedge clk or negedge resetn)
        if (!resetn)  wptr <= 0;
        else if (rbeat) wptr <= wptr + 1'b1;

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

    // next burst length: min(MAX_BURST, beats_left, and don't cross a 4KB boundary)
    wire [31:0] blk_to_4k = (32'd4096 - {20'd0, next_addr[11:0]}) >> 3;  // 64-bit beats to next 4KB
    wire [31:0] cap_burst = (beats_left < MAX_BURST) ? beats_left : MAX_BURST;
    wire [31:0] this_len  = (blk_to_4k < cap_burst) ? blk_to_4k : cap_burst;

    // SINGLE outstanding burst: issue AR, receive the whole burst (to RLAST), repeat.
    // CoreFFT consumes at <=1 sample/cyc so one burst in flight is ample; keeps the
    // FSM provably correct (no outstanding-count bookkeeping).
    localparam S_IDLE=2'd0, S_ADDR=2'd1, S_DATA=2'd2, S_DRAIN=2'd3;
    reg [1:0] state;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state <= S_IDLE; m_arvalid <= 0; m_araddr <= 0; m_arlen <= 0;
            beats_left <= 0; next_addr <= 0; busy <= 0;
        end else begin
            case (state)
              S_IDLE: begin
                  m_arvalid <= 1'b0;
                  if (start_pulse && nbeats != 0) begin
                      beats_left <= nbeats;
                      next_addr  <= src_base;
                      busy       <= 1'b1;
                      state      <= S_ADDR;
                  end
              end
              S_ADDR: begin
                  if (beats_left == 0) begin
                      state <= S_DRAIN;
                  end else if (!m_arvalid && (fifo_room >= this_len)) begin
                      // only issue when the FIFO can hold the whole burst (no RREADY stall
                      // mid-burst -> simplest correct backpressure)
                      m_araddr  <= next_addr;
                      m_arlen   <= this_len[7:0] - 8'd1;   // AXI len = beats-1
                      m_arvalid <= 1'b1;
                  end else if (m_arvalid && m_arready) begin
                      m_arvalid  <= 1'b0;
                      state      <= S_DATA;
                  end
              end
              S_DATA: begin
                  // receive the burst; each rbeat pushed to FIFO by the FIFO logic above
                  if (rbeat && m_rlast) begin
                      beats_left <= beats_left - this_len;
                      next_addr  <= next_addr + (this_len << 3);   // *8 bytes/beat
                      state      <= S_ADDR;
                  end
              end
              S_DRAIN: begin
                  if (fifo_empty && !svalid) begin
                      busy  <= 1'b0;
                      state <= S_IDLE;
                  end
              end
              default: state <= S_IDLE;
            endcase
        end
    end
endmodule
