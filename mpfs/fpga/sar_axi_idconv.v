// sar_axi_idconv.v -- full AXI4 pass-through that converts the AXI ID width between
// AXIIC_C0 SLAVE0 (11-bit ID, 32-bit addr) and MSS FIC_0_AXI4_S (4-bit ID, 38-bit addr).
// NOTE: AXIIC 3.0.130 target ID is 11-bit = {master_number[2:0], master_id[7:0]}; the
// master-select is in the HIGH bits, so it MUST be preserved -- a 9-bit truncation drops
// 2 of the 3 select bits and the B/R response cannot route home (write hangs, M2 tag 0x30).
//
// Replaces SmartDesign's lossy "truncate + 5'h0 pad". On AR/AW it stores the wide ID
// (keyed by its low 4 bits) and forwards the 4-bit tag; on R/B it re-attaches the stored
// upper bits so AXIIC_C0 sees the FULL original ID and routes the response home.
// Address is zero-extended 32->38. Everything else passes straight through.
//
// Ports follow the AXI4 naming convention so Libero "Create Core from HDL" auto-detects:
//   S_AXI : AXI4 *target*   (connect AXIIC_C0 DIC:SLAVE0 here)
//   M_AXI : AXI4 *initiator*(connect MSS:FIC_0_AXI4_S here)
// Then it is ONE delete + TWO bus drags in SmartDesign.
//
// ---------------------------------------------------------------------------------------
// 2026-07-22 FIX: forward master_number, not master_id.
//
// The 11-bit target ID is {master_number[2:0], master_id[7:0]}. The previous version forwarded
// ARID[3:0] -- i.e. master_id[3:0] -- and stashed the upper 7 bits keyed by that tag. But EVERY
// SmartHLS kernel on this design presents master_id = 0, so every master produced
// ARID = {master_number, 8'h00}: the low 4 bits were 0 for ALL of them, every master aliased onto
// tag 0, and the stash kept only the last writer. The keyed store was indexed by the one field
// that carries no information.
//
// That is why the old header could only claim safety for "sequential kernels": with one master
// active at a time the aliasing is invisible. Run two fabric masters concurrently and the
// sequence RES AW (stash<-0x30), RES2 AW (stash<-0x60), RES B reconstructs 0x600 -- the response
// routes to the wrong master. It builds clean, closes timing, and fails only on silicon.
//
// Now: forward master_number[2:0] as the tag (that IS the master-select the interconnect routes
// on), and stash master_id[7:0] keyed by master_number. The remaining assumption is only
// "<=1 outstanding txn per MASTER with a differing master_id", which is trivially true here
// because each kernel presents a single fixed master_id. Up to 8 masters are distinguishable;
// the DIC has 6 initiators.
//
// This unblocks running fabric kernels CONCURRENTLY -- multi-instance FFT, multi-instance
// resample, and overlapping resample with the first FFT all sit behind this one change.
// Verified by tb/tb_sar_axi_idconv.v, which specifically drives two masters that share
// master_id and differ only in master_number, and returns responses out of order.

module sar_axi_idconv (
    input  wire         ACLK,
    input  wire         ARESETN,

    // ===================== S_AXI : target (AXIIC_C0 DIC SLAVE0, 11-bit ID / 32-bit addr)
    input  wire [10:0]  S_AXI_AWID,
    input  wire [31:0]  S_AXI_AWADDR,
    input  wire [7:0]   S_AXI_AWLEN,
    input  wire [2:0]   S_AXI_AWSIZE,
    input  wire [1:0]   S_AXI_AWBURST,
    input  wire [1:0]   S_AXI_AWLOCK,
    input  wire [3:0]   S_AXI_AWCACHE,
    input  wire [2:0]   S_AXI_AWPROT,
    input  wire [3:0]   S_AXI_AWQOS,
    input  wire [3:0]   S_AXI_AWREGION,
    input  wire [0:0]   S_AXI_AWUSER,
    input  wire         S_AXI_AWVALID,
    output wire         S_AXI_AWREADY,
    input  wire [63:0]  S_AXI_WDATA,
    input  wire [7:0]   S_AXI_WSTRB,
    input  wire         S_AXI_WLAST,
    input  wire [0:0]   S_AXI_WUSER,
    input  wire         S_AXI_WVALID,
    output wire         S_AXI_WREADY,
    output wire [10:0]  S_AXI_BID,
    output wire [1:0]   S_AXI_BRESP,
    output wire         S_AXI_BVALID,
    input  wire         S_AXI_BREADY,
    input  wire [10:0]  S_AXI_ARID,
    input  wire [31:0]  S_AXI_ARADDR,
    input  wire [7:0]   S_AXI_ARLEN,
    input  wire [2:0]   S_AXI_ARSIZE,
    input  wire [1:0]   S_AXI_ARBURST,
    input  wire [1:0]   S_AXI_ARLOCK,
    input  wire [3:0]   S_AXI_ARCACHE,
    input  wire [2:0]   S_AXI_ARPROT,
    input  wire [3:0]   S_AXI_ARQOS,
    input  wire [3:0]   S_AXI_ARREGION,
    input  wire [0:0]   S_AXI_ARUSER,
    input  wire         S_AXI_ARVALID,
    output wire         S_AXI_ARREADY,
    output wire [10:0]  S_AXI_RID,
    output wire [63:0]  S_AXI_RDATA,
    output wire [1:0]   S_AXI_RRESP,
    output wire         S_AXI_RLAST,
    output wire         S_AXI_RVALID,
    input  wire         S_AXI_RREADY,

    // ===================== M_AXI : initiator (MSS FIC_0_AXI4_S, 4-bit ID / 38-bit addr)
    output wire [3:0]   M_AXI_AWID,
    output wire [37:0]  M_AXI_AWADDR,
    output wire [7:0]   M_AXI_AWLEN,
    output wire [2:0]   M_AXI_AWSIZE,
    output wire [1:0]   M_AXI_AWBURST,
    output wire         M_AXI_AWLOCK,
    output wire [3:0]   M_AXI_AWCACHE,
    output wire [2:0]   M_AXI_AWPROT,
    output wire [3:0]   M_AXI_AWQOS,
    output wire         M_AXI_AWVALID,
    input  wire         M_AXI_AWREADY,
    output wire [63:0]  M_AXI_WDATA,
    output wire [7:0]   M_AXI_WSTRB,
    output wire         M_AXI_WLAST,
    output wire         M_AXI_WVALID,
    input  wire         M_AXI_WREADY,
    input  wire [3:0]   M_AXI_BID,
    input  wire [1:0]   M_AXI_BRESP,
    input  wire         M_AXI_BVALID,
    output wire         M_AXI_BREADY,
    output wire [3:0]   M_AXI_ARID,
    output wire [37:0]  M_AXI_ARADDR,
    output wire [7:0]   M_AXI_ARLEN,
    output wire [2:0]   M_AXI_ARSIZE,
    output wire [1:0]   M_AXI_ARBURST,
    output wire         M_AXI_ARLOCK,
    output wire [3:0]   M_AXI_ARCACHE,
    output wire [2:0]   M_AXI_ARPROT,
    output wire [3:0]   M_AXI_ARQOS,
    output wire         M_AXI_ARVALID,
    input  wire         M_AXI_ARREADY,
    input  wire [3:0]   M_AXI_RID,
    input  wire [63:0]  M_AXI_RDATA,
    input  wire [1:0]   M_AXI_RRESP,
    input  wire         M_AXI_RLAST,
    input  wire         M_AXI_RVALID,
    output wire         M_AXI_RREADY
);
    // ---- ID stash: master_id[7:0] keyed by master_number[2:0] (8 masters max) ----
    // Keyed by the field that DISCRIMINATES masters, so two masters can be in flight at once.
    reg [7:0] ar_tab [0:7];
    reg [7:0] aw_tab [0:7];
    integer i;
    always @(posedge ACLK or negedge ARESETN) begin
        if (!ARESETN) begin
            for (i=0;i<8;i=i+1) begin ar_tab[i]<=8'h0; aw_tab[i]<=8'h0; end
        end else begin
            if (S_AXI_ARVALID & S_AXI_ARREADY) ar_tab[S_AXI_ARID[10:8]] <= S_AXI_ARID[7:0];
            if (S_AXI_AWVALID & S_AXI_AWREADY) aw_tab[S_AXI_AWID[10:8]] <= S_AXI_AWID[7:0];
        end
    end

    // ---- AR (S->M): downsize ID, zero-extend addr, pass the rest ----
    assign M_AXI_ARID    = {1'b0, S_AXI_ARID[10:8]};   // master_number is the routing key
    assign M_AXI_ARADDR  = {6'b0, S_AXI_ARADDR};
    assign M_AXI_ARLEN   = S_AXI_ARLEN;   assign M_AXI_ARSIZE  = S_AXI_ARSIZE;
    assign M_AXI_ARBURST = S_AXI_ARBURST; assign M_AXI_ARLOCK  = S_AXI_ARLOCK[0];
    assign M_AXI_ARCACHE = S_AXI_ARCACHE; assign M_AXI_ARPROT  = S_AXI_ARPROT;
    assign M_AXI_ARQOS   = S_AXI_ARQOS;   assign M_AXI_ARVALID = S_AXI_ARVALID;
    assign S_AXI_ARREADY = M_AXI_ARREADY;
    // ---- AW (S->M) ----
    assign M_AXI_AWID    = {1'b0, S_AXI_AWID[10:8]};   // master_number is the routing key
    assign M_AXI_AWADDR  = {6'b0, S_AXI_AWADDR};
    assign M_AXI_AWLEN   = S_AXI_AWLEN;   assign M_AXI_AWSIZE  = S_AXI_AWSIZE;
    assign M_AXI_AWBURST = S_AXI_AWBURST; assign M_AXI_AWLOCK  = S_AXI_AWLOCK[0];
    assign M_AXI_AWCACHE = S_AXI_AWCACHE; assign M_AXI_AWPROT  = S_AXI_AWPROT;
    assign M_AXI_AWQOS   = S_AXI_AWQOS;   assign M_AXI_AWVALID = S_AXI_AWVALID;
    assign S_AXI_AWREADY = M_AXI_AWREADY;
    // ---- W (S->M) ----  (FIC0_S has no WUSER; dropped)
    assign M_AXI_WDATA = S_AXI_WDATA; assign M_AXI_WSTRB = S_AXI_WSTRB;
    assign M_AXI_WLAST = S_AXI_WLAST;
    assign M_AXI_WVALID= S_AXI_WVALID; assign S_AXI_WREADY = M_AXI_WREADY;
    // ---- R (M->S): restore ID ----
    assign S_AXI_RID   = { M_AXI_RID[2:0], ar_tab[M_AXI_RID[2:0]] };
    assign S_AXI_RDATA = M_AXI_RDATA; assign S_AXI_RRESP = M_AXI_RRESP;
    assign S_AXI_RLAST = M_AXI_RLAST; assign S_AXI_RVALID= M_AXI_RVALID;
    assign M_AXI_RREADY= S_AXI_RREADY;
    // ---- B (M->S): restore ID ----
    assign S_AXI_BID   = { M_AXI_BID[2:0], aw_tab[M_AXI_BID[2:0]] };
    assign S_AXI_BRESP = M_AXI_BRESP; assign S_AXI_BVALID= M_AXI_BVALID;
    assign M_AXI_BREADY= S_AXI_BREADY;
endmodule
