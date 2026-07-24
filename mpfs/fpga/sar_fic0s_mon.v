// sar_fic0s_mon.v -- FIC_0_AXI4_S transaction monitor.
//
// Purpose: isolate "timing drop vs ID/protocol reject" WITHOUT an ILA/scope.
// Tap the FIC0_S boundary nets, sticky-latch what actually happens on the AR/R
// channels, and expose it on a tiny AXI4-Lite slave so the firmware can read the
// verdict over the (working) FIC0 control path / JTAG -- the same path M2 uses.
//
// Integration (SmartDesign, then synth/P&R/regenerate bitstream):
//   * Instantiate this in SAR_TOP, clock = CCC_OUT0_FABCLK_0, aresetn = RST_FABRIC_RESET_N.
//   * Connect the mon_* inputs to the FIC0_S boundary nets (DIC_AXI4mslave0_*):
//       mon_arvalid <- DIC_AXI4mslave0_ARVALID    mon_arready <- DIC_AXI4mslave0_ARREADY
//       mon_araddr  <- DIC_AXI4mslave0_ARADDR_0   mon_arid    <- DIC_AXI4mslave0_ARID_0
//       mon_arlen   <- DIC_AXI4mslave0_ARLEN_0    (NEW tap -- confirm exact net name/suffix
//                                                   at integration time against the other
//                                                   AR-channel nets above; it was not tapped
//                                                   by the original monitor)
//       mon_rvalid  <- DIC_AXI4mslave0_RVALID     mon_rready  <- DIC_AXI4mslave0_RREADY
//       mon_rresp   <- DIC_AXI4mslave0_RRESP      mon_rid     <- DIC_AXI4mslave0_RID
//       mon_rlast   <- DIC_AXI4mslave0_RLAST
//   * Add it as an AXIIC_CTRL slave (enable SLAVE6) mapped at 0x6000_6000 (4 KiB).
//   * Firmware reads 0x60006000.. (see register map). A *write* to 0x00 clears the latches
//     AND all counters below (one clear-all).
//
// Register map (AXI4-Lite, 32-bit):
//   0x00 STATUS (RO; write any value = clear ALL sticky latches + all counters below)
//        [0] ar_valid_seen   ARVALID was asserted at least once
//        [1] ar_accepted     ARVALID & ARREADY seen together (AR handshake completed)
//        [2] r_valid_seen    RVALID was asserted
//        [3] r_accepted      RVALID & RREADY seen (read data delivered)
//        [4] r_last_seen     RLAST seen
//        [6:5] rresp_last    last RRESP captured at RVALID (00 OKAY,10 SLVERR,11 DECERR)
//        [15:8]  ar_count    AR-beats (saturating 0xFF)
//        [23:16] r_count     R-beats  (saturating 0xFF)
//        [31:24] 0xA5        signature (confirms the slave is alive/decoded)
//   0x04 ARADDR_LO  araddr captured at first ARVALID, bits [31:0]   (expect 0x88000000-class / 0xB0148000)
//   0x08 ARADDR_HI  bits [37:32] in [5:0]
//   0x0C IDS        [3:0] arid_first   [7:4] rid_last
//
//   ---- added: ARLEN histogram / gap-and-utilization counters (all RO, 32-bit saturating) ----
//   Counted on the AR handshake (mon_arvalid & mon_arready), bucketed by ARLEN+1 (beats, not
//   the raw AXI ARLEN encoding). Answers "short bursts vs long idle gaps" for the resample
//   gather kernel's 2.44x AXI-stall gap (see sar_kernels.h / resample runbook).
//   0x10 ARLEN_HIST_1        beats==1   (single-beat burst, ARLEN==0)
//   0x14 ARLEN_HIST_2_4      2<=beats<=4
//   0x18 ARLEN_HIST_5_16     5<=beats<=16
//   0x1C ARLEN_HIST_17_64    17<=beats<=64
//   0x20 ARLEN_HIST_65_256   65<=beats<=256
//   0x24 BUSY_CYCLES     cycles with an AR or R handshake in flight (mon_arvalid&mon_arready
//                         OR mon_rvalid&mon_rready) -- "useful work" cycles.
//   0x28 ELAPSED_CYCLES  total cycles since the last clear (utilization = BUSY/ELAPSED).
//   0x2C MAX_GAP         longest run of consecutive idle cycles (no AR/R handshake) between
//                         two AR/R handshake events. Running gap resets to 0 on any AR/R
//                         handshake; latched into MAX_GAP only if the just-ended run exceeds
//                         the current MAX_GAP (monotonic non-decreasing until cleared).
//   Firmware usage: write 0x00 immediately before arming ONE resample line (sar_k_start),
//   read 0x10-0x2C immediately after that line's sar_k_wait completes -- counters then cover
//   exactly that line's AXI activity (thousands of cycles; 32-bit saturation is not a
//   practical concern for a single line).
//
//   ==== v2 (2026-07-24): WRITE channel + intra-burst read-throttle ====================
//   The v1 fields above tap only AR/R, so they CANNOT tell whether the gather kernel's
//   distributed idle is (a) time spent WRITING output (invisible to a read-only tap) or
//   (b) DDR returning read data slower than 1 beat/cyc within an outstanding burst. These
//   v2 counters split exactly that -- the decision the gather-stall root-cause hinges on.
//   0x30 AW_COUNT         AW handshakes (write bursts issued), saturating 0xFFFFFFFF
//   0x34 W_COUNT          W beats accepted (mon_wvalid&mon_wready)
//   0x38 B_STATUS         [7:0] b_count(resp count, sat 0xFF) [9:8] bresp_last
//                         [16] aw_valid_seen [17] aw_accepted [18] w_last_seen [19] b_seen
//                         [31:24] 0x5A signature (v2 slave-alive)
//   0x3C WRITE_BUSY       cycles with an AW, W, or B handshake in flight  -> WRITE time.
//                         (write_busy/elapsed answers "is the idle actually writes?" = cause (a))
//   0x40 R_DATAWAIT       cycles where a read burst is OUTSTANDING (AR accepted, not yet
//                         RLAST) but RVALID is LOW -> DDR not delivering read data = cause (b)
//                         (read latency + intra-burst throttle). r_datawait/elapsed sizes it.
//   0x44 MAX_R_DATAWAIT   longest single run of read-outstanding-but-RVALID-low cycles
//                         (a big value => one long DDR stall; many small => steady throttle).
//   0x48 TOTAL_ACTIVE     cycles with ANY handshake (AR|R|AW|W|B) -- the true utilization
//                         numerator (v1 BUSY_CYCLES omitted writes). util = TOTAL_ACTIVE/ELAPSED.
//   Decode: ELAPSED = read_busy(0x24) + write_busy(0x3C) + genuine_idle + overlap; and
//   R_DATAWAIT attributes the read-side idle to DDR throttle vs. inter-burst arbitration.

module sar_fic0s_mon #(
    parameter SIG    = 8'hA5,
    parameter SIG_V2 = 8'h5A
)(
    input  wire        aclk,
    input  wire        aresetn,        // active low

    // ---- tapped FIC0_S boundary (observe-only) ----
    input  wire        mon_arvalid,
    input  wire        mon_arready,
    input  wire [37:0] mon_araddr,
    input  wire [3:0]  mon_arid,
    input  wire [7:0]  mon_arlen,
    input  wire        mon_rvalid,
    input  wire        mon_rready,
    input  wire [1:0]  mon_rresp,
    input  wire [3:0]  mon_rid,
    input  wire        mon_rlast,

    // ---- v2: tapped FIC0_S WRITE channel (observe-only) ----
    input  wire        mon_awvalid,
    input  wire        mon_awready,
    input  wire        mon_wvalid,
    input  wire        mon_wready,
    input  wire        mon_wlast,
    input  wire        mon_bvalid,
    input  wire        mon_bready,
    input  wire [1:0]  mon_bresp,

    // ---- AXI4-Lite slave (read verdict / write-clear) ----
    input  wire [11:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready,
    input  wire [31:0] s_axi_wdata,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready,
    output reg  [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid,
    input  wire        s_axi_bready,
    input  wire [11:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready,
    output reg  [31:0] s_axi_rdata,
    output reg  [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid,
    input  wire        s_axi_rready
);
    // ---- sticky observation state ----
    reg        ar_valid_seen, ar_accepted, r_valid_seen, r_accepted, r_last_seen;
    reg [1:0]  rresp_last;
    reg [7:0]  ar_count, r_count;
    reg [37:0] araddr_first;
    reg        araddr_taken;
    reg [3:0]  arid_first, rid_last;

    wire clr;   // pulse from the AXI write side (declared below)

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            ar_valid_seen<=0; ar_accepted<=0; r_valid_seen<=0; r_accepted<=0; r_last_seen<=0;
            rresp_last<=0; ar_count<=0; r_count<=0; araddr_first<=0; araddr_taken<=0;
            arid_first<=0; rid_last<=0;
        end else if (clr) begin
            ar_valid_seen<=0; ar_accepted<=0; r_valid_seen<=0; r_accepted<=0; r_last_seen<=0;
            rresp_last<=0; ar_count<=0; r_count<=0; araddr_taken<=0;
        end else begin
            if (mon_arvalid) begin
                ar_valid_seen <= 1'b1;
                if (!araddr_taken) begin araddr_first<=mon_araddr; arid_first<=mon_arid; araddr_taken<=1'b1; end
            end
            if (mon_arvalid & mon_arready) begin
                ar_accepted <= 1'b1;
                if (ar_count != 8'hFF) ar_count <= ar_count + 8'd1;
            end
            if (mon_rvalid) begin
                r_valid_seen <= 1'b1; rresp_last <= mon_rresp; rid_last <= mon_rid;
            end
            if (mon_rvalid & mon_rready) begin
                r_accepted <= 1'b1; if (mon_rlast) r_last_seen <= 1'b1;
                if (r_count != 8'hFF) r_count <= r_count + 8'd1;
            end
        end
    end

    wire [31:0] status = { SIG, r_count, ar_count, 1'b0, rresp_last,
                           r_last_seen, r_accepted, r_valid_seen, ar_accepted, ar_valid_seen };

    // ---- ARLEN histogram / busy / elapsed / max-gap (see register map above) ----
    reg [31:0] hist_len1, hist_len2_4, hist_len5_16, hist_len17_64, hist_len65_256;
    reg [31:0] busy_cycles, elapsed_cycles, max_gap, running_gap;

    wire       ar_hs     = mon_arvalid & mon_arready;
    wire       r_hs      = mon_rvalid  & mon_rready;
    wire       act_cycle = ar_hs | r_hs;              // AR or R handshake this cycle
    wire [8:0] ar_beats  = {1'b0, mon_arlen} + 9'd1;  // ARLEN encodes beats-1

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            hist_len1<=0; hist_len2_4<=0; hist_len5_16<=0; hist_len17_64<=0; hist_len65_256<=0;
            busy_cycles<=0; elapsed_cycles<=0; max_gap<=0; running_gap<=0;
        end else if (clr) begin
            hist_len1<=0; hist_len2_4<=0; hist_len5_16<=0; hist_len17_64<=0; hist_len65_256<=0;
            busy_cycles<=0; elapsed_cycles<=0; max_gap<=0; running_gap<=0;
        end else begin
            // ELAPSED: every cycle since the last clear (saturating)
            if (elapsed_cycles != 32'hFFFF_FFFF) elapsed_cycles <= elapsed_cycles + 32'd1;

            // BUSY: cycles with an AR or R handshake in flight (saturating)
            if (act_cycle && busy_cycles != 32'hFFFF_FFFF) busy_cycles <= busy_cycles + 32'd1;

            // ARLEN histogram, bucketed on AR acceptance (saturating per bucket)
            if (ar_hs) begin
                if (ar_beats == 9'd1) begin
                    if (hist_len1 != 32'hFFFF_FFFF) hist_len1 <= hist_len1 + 32'd1;
                end else if (ar_beats <= 9'd4) begin
                    if (hist_len2_4 != 32'hFFFF_FFFF) hist_len2_4 <= hist_len2_4 + 32'd1;
                end else if (ar_beats <= 9'd16) begin
                    if (hist_len5_16 != 32'hFFFF_FFFF) hist_len5_16 <= hist_len5_16 + 32'd1;
                end else if (ar_beats <= 9'd64) begin
                    if (hist_len17_64 != 32'hFFFF_FFFF) hist_len17_64 <= hist_len17_64 + 32'd1;
                end else begin
                    if (hist_len65_256 != 32'hFFFF_FFFF) hist_len65_256 <= hist_len65_256 + 32'd1;
                end
            end

            // MAX_GAP: longest run of idle cycles between two AR/R handshake events.
            if (act_cycle) begin
                if (running_gap > max_gap) max_gap <= running_gap;
                running_gap <= 32'd0;
            end else if (running_gap != 32'hFFFF_FFFF) begin
                running_gap <= running_gap + 32'd1;
            end
        end
    end

    // ---- v2: WRITE channel + intra-burst read-throttle -----------------------------------
    reg        aw_valid_seen, aw_accepted, w_last_seen, b_seen;
    reg [1:0]  bresp_last;
    reg [7:0]  b_count;
    reg [31:0] aw_count, w_count, write_busy, total_active;
    reg [3:0]  rd_outstanding;                       // in-flight read bursts (max_outstanding_reads=8)
    reg [31:0] r_datawait, max_r_datawait, run_r_datawait;

    wire aw_hs   = mon_awvalid & mon_awready;
    wire w_hs    = mon_wvalid  & mon_wready;
    wire b_hs    = mon_bvalid  & mon_bready;
    wire wr_act  = aw_hs | w_hs | b_hs;
    wire any_act = act_cycle | wr_act;               // act_cycle = ar_hs|r_hs (v1)
    wire rd_inflight = (rd_outstanding != 4'd0);
    wire r_stall = rd_inflight & ~mon_rvalid;        // read burst outstanding but no data arriving
    wire rburst_done = r_hs & mon_rlast;

    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn || clr) begin
            aw_valid_seen<=0; aw_accepted<=0; w_last_seen<=0; b_seen<=0; bresp_last<=0;
            b_count<=0; aw_count<=0; w_count<=0; write_busy<=0; total_active<=0;
            rd_outstanding<=0; r_datawait<=0; max_r_datawait<=0; run_r_datawait<=0;
        end else begin
            // write-channel sticky + counts
            if (mon_awvalid) aw_valid_seen <= 1'b1;
            if (aw_hs) begin aw_accepted<=1'b1; if (aw_count!=32'hFFFFFFFF) aw_count<=aw_count+32'd1; end
            if (w_hs)  begin if (mon_wlast) w_last_seen<=1'b1; if (w_count!=32'hFFFFFFFF) w_count<=w_count+32'd1; end
            if (b_hs)  begin b_seen<=1'b1; bresp_last<=mon_bresp; if (b_count!=8'hFF) b_count<=b_count+8'd1; end

            if (wr_act   && write_busy   !=32'hFFFFFFFF) write_busy   <= write_busy   + 32'd1;
            if (any_act  && total_active !=32'hFFFFFFFF) total_active <= total_active + 32'd1;

            // outstanding read bursts: +1 on AR accept, -1 on RLAST beat (both can occur same cycle)
            case ({ar_hs, rburst_done})
                2'b10:   rd_outstanding <= rd_outstanding + 4'd1;
                2'b01:   if (rd_outstanding!=4'd0) rd_outstanding <= rd_outstanding - 4'd1;
                default: ;
            endcase

            // R_DATAWAIT: read outstanding but RVALID low = DDR read latency / intra-burst throttle
            if (r_stall) begin
                if (r_datawait     != 32'hFFFFFFFF) r_datawait     <= r_datawait     + 32'd1;
                if (run_r_datawait != 32'hFFFFFFFF) run_r_datawait <= run_r_datawait + 32'd1;
            end else begin
                if (run_r_datawait > max_r_datawait) max_r_datawait <= run_r_datawait;
                run_r_datawait <= 32'd0;
            end
        end
    end

    wire [31:0] b_status = { SIG_V2, 4'b0, b_seen, w_last_seen, aw_accepted, aw_valid_seen,
                             6'b0, bresp_last, b_count };

    // ---- minimal AXI4-Lite (single-beat, always OKAY) ----
    reg wr_clr;
    assign clr = wr_clr;
    // write
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_awready<=0; s_axi_wready<=0; s_axi_bvalid<=0; s_axi_bresp<=2'b00; wr_clr<=0;
        end else begin
            wr_clr <= 0;
            s_axi_awready <= (s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid);
            s_axi_wready  <= (s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid);
            if (s_axi_awvalid & s_axi_wvalid & ~s_axi_bvalid) begin
                if (s_axi_awaddr[11:2]==10'd0) wr_clr <= 1'b1;   // write to 0x00 clears latches
                s_axi_bvalid <= 1'b1; s_axi_bresp <= 2'b00;
            end else if (s_axi_bvalid & s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end
    // read
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            s_axi_arready<=0; s_axi_rvalid<=0; s_axi_rresp<=2'b00; s_axi_rdata<=32'b0;
        end else begin
            s_axi_arready <= (s_axi_arvalid & ~s_axi_rvalid);
            if (s_axi_arvalid & ~s_axi_rvalid) begin
                s_axi_rvalid <= 1'b1; s_axi_rresp <= 2'b00;
                case (s_axi_araddr[11:2])
                    10'd0:   s_axi_rdata <= status;
                    10'd1:   s_axi_rdata <= araddr_first[31:0];
                    10'd2:   s_axi_rdata <= {26'b0, araddr_first[37:32]};
                    10'd3:   s_axi_rdata <= {24'b0, rid_last, arid_first};
                    10'd4:   s_axi_rdata <= hist_len1;        // 0x10 ARLEN_HIST_1
                    10'd5:   s_axi_rdata <= hist_len2_4;      // 0x14 ARLEN_HIST_2_4
                    10'd6:   s_axi_rdata <= hist_len5_16;     // 0x18 ARLEN_HIST_5_16
                    10'd7:   s_axi_rdata <= hist_len17_64;    // 0x1C ARLEN_HIST_17_64
                    10'd8:   s_axi_rdata <= hist_len65_256;   // 0x20 ARLEN_HIST_65_256
                    10'd9:   s_axi_rdata <= busy_cycles;      // 0x24 BUSY_CYCLES
                    10'd10:  s_axi_rdata <= elapsed_cycles;   // 0x28 ELAPSED_CYCLES
                    10'd11:  s_axi_rdata <= max_gap;          // 0x2C MAX_GAP
                    10'd12:  s_axi_rdata <= aw_count;         // 0x30 AW_COUNT
                    10'd13:  s_axi_rdata <= w_count;          // 0x34 W_COUNT
                    10'd14:  s_axi_rdata <= b_status;         // 0x38 B_STATUS (+SIG_V2)
                    10'd15:  s_axi_rdata <= write_busy;       // 0x3C WRITE_BUSY
                    10'd16:  s_axi_rdata <= r_datawait;       // 0x40 R_DATAWAIT
                    10'd17:  s_axi_rdata <= max_r_datawait;   // 0x44 MAX_R_DATAWAIT
                    10'd18:  s_axi_rdata <= total_active;     // 0x48 TOTAL_ACTIVE
                    default: s_axi_rdata <= 32'hDEAD_0000;
                endcase
            end else if (s_axi_rvalid & s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
