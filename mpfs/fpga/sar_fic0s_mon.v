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
//       mon_rvalid  <- DIC_AXI4mslave0_RVALID     mon_rready  <- DIC_AXI4mslave0_RREADY
//       mon_rresp   <- DIC_AXI4mslave0_RRESP      mon_rid     <- DIC_AXI4mslave0_RID
//       mon_rlast   <- DIC_AXI4mslave0_RLAST
//   * Add it as an AXIIC_CTRL slave (enable SLAVE6) mapped at 0x6000_6000 (4 KiB).
//   * Firmware reads 0x60006000.. (see register map). A *write* to 0x00 clears the latches.
//
// Register map (AXI4-Lite, 32-bit):
//   0x00 STATUS (RO; write any value = clear all sticky latches)
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

module sar_fic0s_mon #(
    parameter SIG = 8'hA5
)(
    input  wire        aclk,
    input  wire        aresetn,        // active low

    // ---- tapped FIC0_S boundary (observe-only) ----
    input  wire        mon_arvalid,
    input  wire        mon_arready,
    input  wire [37:0] mon_araddr,
    input  wire [3:0]  mon_arid,
    input  wire        mon_rvalid,
    input  wire        mon_rready,
    input  wire [1:0]  mon_rresp,
    input  wire [3:0]  mon_rid,
    input  wire        mon_rlast,

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
                    default: s_axi_rdata <= 32'hDEAD_0000;
                endcase
            end else if (s_axi_rvalid & s_axi_rready) begin
                s_axi_rvalid <= 1'b0;
            end
        end
    end
endmodule
