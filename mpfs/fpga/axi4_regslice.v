// axi4_regslice.v -- topology-preserving AXI4 pipeline / skid-buffer register slice.
//
// WHY: post-layout multi-corner timing (2026-07-22) shows the worst setup path is NOT in our
// RTL -- it moves between two vendor CoreAXI4Interconnect instances build to build:
//   worst setup +0.864 ns: CIC/AXIIC_CTRL_0/IntrConvertor_loop[0]/.../rdatach_rs_en.rrs/... (control)
//   worst setup (another build): DIC/AXIIC_C0_0/.../rdata_interleave_fifo/fifo_ctrl_inst/fifo_nearly_full (data)
// CoreFFT's own SLOWCLK-domain logic has +114 ns of slack out of a 128 ns period -- it is nowhere
// near the limiter. This module sits INLINE on an EXISTING point-to-point AXI4 link (rewire
// A->B into A->[this]->B) to break up the long combinational paths feeding into/out of DIC/CIC,
// buying setup margin. It does NOT add or remove a target/initiator from either
// CoreAXI4Interconnect instance -- see sar_axi_idconv.v's header for why that distinction
// matters on this project (44 stray TARGET6_* tie-offs from an earlier target-count change once
// blocked every Libero build).
//
// Ports follow the AXI4 naming convention so Libero "Create Core from HDL" auto-detects:
//   S_AXI : AXI4 *target*    (upstream side -- connect the existing initiator/DIC-target output here)
//   M_AXI : AXI4 *initiator* (downstream side -- connect the existing target/DIC-initiator input here)
// Then it is ONE delete + TWO bus drags in SmartDesign, exactly like sar_axi_idconv.v.
//
// FIELD WIDTHS copy sar_axi_idconv.v's S_AXI port 1:1 (AWLOCK/ARLOCK = 2 bits -- this project's
// vendor `AXI4:AMBA:AMBA4` BIF presents a 2-bit AxLOCK even under AXI4, not AXI4's nominal 1 bit;
// CACHE=4, PROT=3, QOS=4, REGION=4, xUSER=1) so the module matches the DIC target0<->ID_FIX and
// CIC initiator0<->MSS FIC_0_AXI4_INITIATOR links byte-for-byte. Unlike sar_axi_idconv.v this
// module performs NO width conversion: S_AXI and M_AXI share the same ID_WIDTH/ADDR_WIDTH/
// DATA_WIDTH (all three are module parameters -- this design uses both 4-bit and 11-bit ID and
// 32-bit/38-bit address in different places, so nothing here is hardcoded).
//
// STRUCTURE: each of the 5 channels (AW, W, B, AR, R) is an independent unidirectional
// ready/valid pipe built from DEPTH (parameter, default 1) cascaded 2-register "skid" stages
// (axi4_regslice_skid_stage, below). Each stage is a formally standard skid buffer: a beat that
// arrives while the downstream is not ready is captured into a side (skid) register instead of
// being dropped, so throughput is undegraded (sustained back-to-back beats, zero bubbles) and
// upstream is only stalled once BOTH the main output register and the skid register are full.
// Cascading DEPTH independently-correct stages is trivially correct (well-known composability of
// ready/valid pipelines) and gives DEPTH cycles of latency / up to 2*DEPTH beats of buffering.
//
// This is a PURE protocol/timing element: every field (ID, ADDR, LEN, SIZE, BURST, LOCK, CACHE,
// PROT, QOS, REGION, USER, DATA, STRB, LAST, RESP) is registered unchanged -- packed into one
// vector per channel and carried through the skid stages verbatim, then unpacked in the SAME
// field order it was packed, so no field can be reordered or corrupted by construction. There is
// NO combinational path from any S_AXI input to the corresponding M_AXI output: M_AXI_*VALID and
// M_AXI_*DATA are driven only by the skid stage's own registers, and S_AXI_*READY is driven only
// by that stage's OWN skid_valid register (never combinationally by M_AXI_*READY) -- that is the
// entire point: it is exactly the S_AXI_*READY <- (combinational fabric) <- M_AXI_*READY chain
// through the vendor interconnect's internal muxing/arbitration logic that this module exists to
// interrupt.
//
// See tb/tb_axi4_regslice.v for the self-checking TB (back-to-back/no-bubble, random
// backpressure, VALID-held-stable-until-accepted, out-of-order multi-ID responses, and the
// mutation check).
`timescale 1ns/1ps

// ============================================================================================
// axi4_regslice_skid_stage -- one 2-register skid buffer stage (WIDTH-bit payload).
// s_ready depends only on the internal skid_valid register: never combinationally on m_ready.
// m_valid/m_data depend only on internal registers: never combinationally on s_valid/s_data.
// ============================================================================================
module axi4_regslice_skid_stage #(
    parameter integer WIDTH = 1
)(
    input  wire             clk,
    input  wire             resetn,
    input  wire [WIDTH-1:0] s_data,
    input  wire             s_valid,
    output wire             s_ready,
    output reg  [WIDTH-1:0] m_data,
    output reg              m_valid,
    input  wire             m_ready
);
    reg [WIDTH-1:0] skid_data;
    reg             skid_valid;

    // can the main output register accept a new value THIS cycle?
    wire load_main = m_ready | ~m_valid;

    // upstream may present a new beat iff the skid register is empty -- a pure function of our
    // own state, not of m_ready, so backpressure from downstream cannot combinationally reach
    // upstream through this stage.
`ifdef AXI4_REGSLICE_MUTATE_OVERWRITE
    // MUTATION (deliberately broken, for tb/tb_axi4_regslice.v's mutation check ONLY -- must
    // NEVER be defined in a real build): claim ready even when the skid register is already
    // occupied, so a second incoming beat silently overwrites skid_data instead of stalling --
    // the "skid buffer that overwrites instead of stalling" bug class named in the design brief.
    assign s_ready = 1'b1;
`else
    assign s_ready = ~skid_valid;
`endif

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_valid    <= 1'b0;
            m_data     <= {WIDTH{1'b0}};
            skid_valid <= 1'b0;
            skid_data  <= {WIDTH{1'b0}};
        end else begin
            if (load_main) begin
                if (skid_valid) begin
                    // drain the skid register into the now-free output register
                    m_data     <= skid_data;
                    m_valid    <= 1'b1;
                    skid_valid <= 1'b0;
                end else begin
                    // pass a new beat straight into the (now-free) output register
                    m_data  <= s_data;
                    m_valid <= s_valid;
                end
            end else if (s_valid & s_ready) begin
                // output register busy (m_valid & ~m_ready): stash the incoming beat rather
                // than drop it. s_ready==1 here implies skid_valid was 0, so this cannot
                // overwrite an already-occupied skid register.
                skid_data  <= s_data;
                skid_valid <= 1'b1;
            end
            // else: output stalled and skid already occupied -- s_ready is 0, upstream MUST
            // hold s_valid/s_data steady (AXI4 requirement); nothing to latch.
        end
    end
endmodule

// ============================================================================================
// axi4_regslice -- top level, 5-channel AXI4 register slice
// ============================================================================================
module axi4_regslice #(
    parameter integer ID_WIDTH   = 4,
    parameter integer ADDR_WIDTH = 32,
    parameter integer DATA_WIDTH = 64,
    parameter integer LOCK_WIDTH = 2,    // AxLOCK width. 2 for this project's vendor AXI4 BIF;
                                         // MUST be 1 to connect MSS:FIC_0_AXI4_M (1-bit scalar
                                         // AxLOCK) or SmartDesign promotes the whole interface
                                         // bus to top-level I/O (a dangling bif signal exposes
                                         // the entire interface -- cost a build to learn).
    parameter integer DEPTH      = 1     // cascaded skid stages per channel; >=1
)(
    input  wire                      ACLK,
    input  wire                      ARESETN,

    // ===================== S_AXI : target (upstream / existing initiator side) ==============
    input  wire [ID_WIDTH-1:0]       S_AXI_AWID,
    input  wire [ADDR_WIDTH-1:0]     S_AXI_AWADDR,
    input  wire [7:0]                S_AXI_AWLEN,
    input  wire [2:0]                S_AXI_AWSIZE,
    input  wire [1:0]                S_AXI_AWBURST,
    input  wire [LOCK_WIDTH-1:0]      S_AXI_AWLOCK,
    input  wire [3:0]                S_AXI_AWCACHE,
    input  wire [2:0]                S_AXI_AWPROT,
    input  wire [3:0]                S_AXI_AWQOS,
    input  wire [3:0]                S_AXI_AWREGION,
    input  wire [0:0]                S_AXI_AWUSER,
    input  wire                      S_AXI_AWVALID,
    output wire                      S_AXI_AWREADY,
    input  wire [DATA_WIDTH-1:0]     S_AXI_WDATA,
    input  wire [DATA_WIDTH/8-1:0]   S_AXI_WSTRB,
    input  wire                      S_AXI_WLAST,
    input  wire [0:0]                S_AXI_WUSER,
    input  wire                      S_AXI_WVALID,
    output wire                      S_AXI_WREADY,
    output wire [ID_WIDTH-1:0]       S_AXI_BID,
    output wire [1:0]                S_AXI_BRESP,
    output wire                      S_AXI_BVALID,
    input  wire                      S_AXI_BREADY,
    input  wire [ID_WIDTH-1:0]       S_AXI_ARID,
    input  wire [ADDR_WIDTH-1:0]     S_AXI_ARADDR,
    input  wire [7:0]                S_AXI_ARLEN,
    input  wire [2:0]                S_AXI_ARSIZE,
    input  wire [1:0]                S_AXI_ARBURST,
    input  wire [LOCK_WIDTH-1:0]      S_AXI_ARLOCK,
    input  wire [3:0]                S_AXI_ARCACHE,
    input  wire [2:0]                S_AXI_ARPROT,
    input  wire [3:0]                S_AXI_ARQOS,
    input  wire [3:0]                S_AXI_ARREGION,
    input  wire [0:0]                S_AXI_ARUSER,
    input  wire                      S_AXI_ARVALID,
    output wire                      S_AXI_ARREADY,
    output wire [ID_WIDTH-1:0]       S_AXI_RID,
    output wire [DATA_WIDTH-1:0]     S_AXI_RDATA,
    output wire [1:0]                S_AXI_RRESP,
    output wire                      S_AXI_RLAST,
    output wire                      S_AXI_RVALID,
    input  wire                      S_AXI_RREADY,

    // ===================== M_AXI : initiator (downstream / existing target side) ============
    output wire [ID_WIDTH-1:0]       M_AXI_AWID,
    output wire [ADDR_WIDTH-1:0]     M_AXI_AWADDR,
    output wire [7:0]                M_AXI_AWLEN,
    output wire [2:0]                M_AXI_AWSIZE,
    output wire [1:0]                M_AXI_AWBURST,
    output wire [LOCK_WIDTH-1:0]      M_AXI_AWLOCK,
    output wire [3:0]                M_AXI_AWCACHE,
    output wire [2:0]                M_AXI_AWPROT,
    output wire [3:0]                M_AXI_AWQOS,
    output wire [3:0]                M_AXI_AWREGION,
    output wire [0:0]                M_AXI_AWUSER,
    output wire                      M_AXI_AWVALID,
    input  wire                      M_AXI_AWREADY,
    output wire [DATA_WIDTH-1:0]     M_AXI_WDATA,
    output wire [DATA_WIDTH/8-1:0]   M_AXI_WSTRB,
    output wire                      M_AXI_WLAST,
    output wire [0:0]                M_AXI_WUSER,
    output wire                      M_AXI_WVALID,
    input  wire                      M_AXI_WREADY,
    input  wire [ID_WIDTH-1:0]       M_AXI_BID,
    input  wire [1:0]                M_AXI_BRESP,
    input  wire                      M_AXI_BVALID,
    output wire                      M_AXI_BREADY,
    output wire [ID_WIDTH-1:0]       M_AXI_ARID,
    output wire [ADDR_WIDTH-1:0]     M_AXI_ARADDR,
    output wire [7:0]                M_AXI_ARLEN,
    output wire [2:0]                M_AXI_ARSIZE,
    output wire [1:0]                M_AXI_ARBURST,
    output wire [LOCK_WIDTH-1:0]      M_AXI_ARLOCK,
    output wire [3:0]                M_AXI_ARCACHE,
    output wire [2:0]                M_AXI_ARPROT,
    output wire [3:0]                M_AXI_ARQOS,
    output wire [3:0]                M_AXI_ARREGION,
    output wire [0:0]                M_AXI_ARUSER,
    output wire                      M_AXI_ARVALID,
    input  wire                      M_AXI_ARREADY,
    input  wire [ID_WIDTH-1:0]       M_AXI_RID,
    input  wire [DATA_WIDTH-1:0]     M_AXI_RDATA,
    input  wire [1:0]                M_AXI_RRESP,
    input  wire                      M_AXI_RLAST,
    input  wire                      M_AXI_RVALID,
    output wire                      M_AXI_RREADY
);
    localparam integer STRB_WIDTH = DATA_WIDTH/8;
    // AW/AR payload: ID+ADDR+LEN(8)+SIZE(3)+BURST(2)+LOCK(2)+CACHE(4)+PROT(3)+QOS(4)+REGION(4)+USER(1)
    localparam integer AW_W = ID_WIDTH + ADDR_WIDTH + 29 + LOCK_WIDTH;
    localparam integer AR_W = ID_WIDTH + ADDR_WIDTH + 29 + LOCK_WIDTH;
    localparam integer W_W  = DATA_WIDTH + STRB_WIDTH + 2;   // DATA+STRB+LAST(1)+USER(1)
    localparam integer B_W  = ID_WIDTH + 2;                  // ID+RESP(2)
    localparam integer R_W  = ID_WIDTH + DATA_WIDTH + 3;     // ID+DATA+RESP(2)+LAST(1)

    // ---------------------------------------------------------------- AW channel (S->M) -----
    wire [AW_W-1:0] awc_data  [0:DEPTH];
    wire            awc_valid [0:DEPTH];
    wire            awc_ready [0:DEPTH];
    assign awc_data[0]   = {S_AXI_AWID, S_AXI_AWADDR, S_AXI_AWLEN, S_AXI_AWSIZE, S_AXI_AWBURST,
                             S_AXI_AWLOCK, S_AXI_AWCACHE, S_AXI_AWPROT, S_AXI_AWQOS,
                             S_AXI_AWREGION, S_AXI_AWUSER};
    assign awc_valid[0]  = S_AXI_AWVALID;
    assign S_AXI_AWREADY = awc_ready[0];
    assign {M_AXI_AWID, M_AXI_AWADDR, M_AXI_AWLEN, M_AXI_AWSIZE, M_AXI_AWBURST,
            M_AXI_AWLOCK, M_AXI_AWCACHE, M_AXI_AWPROT, M_AXI_AWQOS,
            M_AXI_AWREGION, M_AXI_AWUSER} = awc_data[DEPTH];
    assign M_AXI_AWVALID    = awc_valid[DEPTH];
    assign awc_ready[DEPTH] = M_AXI_AWREADY;
    genvar gaw;
    generate
        for (gaw = 0; gaw < DEPTH; gaw = gaw + 1) begin : AW_STAGE
            axi4_regslice_skid_stage #(.WIDTH(AW_W)) u_aw (
                .clk(ACLK), .resetn(ARESETN),
                .s_data(awc_data[gaw]),   .s_valid(awc_valid[gaw]),   .s_ready(awc_ready[gaw]),
                .m_data(awc_data[gaw+1]), .m_valid(awc_valid[gaw+1]), .m_ready(awc_ready[gaw+1])
            );
        end
    endgenerate

    // ----------------------------------------------------------------- W channel (S->M) -----
    wire [W_W-1:0] wc_data  [0:DEPTH];
    wire           wc_valid [0:DEPTH];
    wire           wc_ready [0:DEPTH];
    assign wc_data[0]   = {S_AXI_WDATA, S_AXI_WSTRB, S_AXI_WLAST, S_AXI_WUSER};
    assign wc_valid[0]  = S_AXI_WVALID;
    assign S_AXI_WREADY = wc_ready[0];
    assign {M_AXI_WDATA, M_AXI_WSTRB, M_AXI_WLAST, M_AXI_WUSER} = wc_data[DEPTH];
    assign M_AXI_WVALID    = wc_valid[DEPTH];
    assign wc_ready[DEPTH] = M_AXI_WREADY;
    genvar gw;
    generate
        for (gw = 0; gw < DEPTH; gw = gw + 1) begin : W_STAGE
            axi4_regslice_skid_stage #(.WIDTH(W_W)) u_w (
                .clk(ACLK), .resetn(ARESETN),
                .s_data(wc_data[gw]),   .s_valid(wc_valid[gw]),   .s_ready(wc_ready[gw]),
                .m_data(wc_data[gw+1]), .m_valid(wc_valid[gw+1]), .m_ready(wc_ready[gw+1])
            );
        end
    endgenerate

    // ----------------------------------------------------------------- B channel (M->S) -----
    // NOTE direction reversal: "S" of this pipe is M_AXI_B*, "M" of this pipe is S_AXI_B*.
    wire [B_W-1:0] bc_data  [0:DEPTH];
    wire           bc_valid [0:DEPTH];
    wire           bc_ready [0:DEPTH];
    assign bc_data[0]    = {M_AXI_BID, M_AXI_BRESP};
    assign bc_valid[0]   = M_AXI_BVALID;
    assign M_AXI_BREADY  = bc_ready[0];
    assign {S_AXI_BID, S_AXI_BRESP} = bc_data[DEPTH];
    assign S_AXI_BVALID     = bc_valid[DEPTH];
    assign bc_ready[DEPTH]  = S_AXI_BREADY;
    genvar gb;
    generate
        for (gb = 0; gb < DEPTH; gb = gb + 1) begin : B_STAGE
            axi4_regslice_skid_stage #(.WIDTH(B_W)) u_b (
                .clk(ACLK), .resetn(ARESETN),
                .s_data(bc_data[gb]),   .s_valid(bc_valid[gb]),   .s_ready(bc_ready[gb]),
                .m_data(bc_data[gb+1]), .m_valid(bc_valid[gb+1]), .m_ready(bc_ready[gb+1])
            );
        end
    endgenerate

    // ---------------------------------------------------------------- AR channel (S->M) -----
    wire [AR_W-1:0] arc_data  [0:DEPTH];
    wire            arc_valid [0:DEPTH];
    wire            arc_ready [0:DEPTH];
    assign arc_data[0]   = {S_AXI_ARID, S_AXI_ARADDR, S_AXI_ARLEN, S_AXI_ARSIZE, S_AXI_ARBURST,
                             S_AXI_ARLOCK, S_AXI_ARCACHE, S_AXI_ARPROT, S_AXI_ARQOS,
                             S_AXI_ARREGION, S_AXI_ARUSER};
    assign arc_valid[0]  = S_AXI_ARVALID;
    assign S_AXI_ARREADY = arc_ready[0];
    assign {M_AXI_ARID, M_AXI_ARADDR, M_AXI_ARLEN, M_AXI_ARSIZE, M_AXI_ARBURST,
            M_AXI_ARLOCK, M_AXI_ARCACHE, M_AXI_ARPROT, M_AXI_ARQOS,
            M_AXI_ARREGION, M_AXI_ARUSER} = arc_data[DEPTH];
    assign M_AXI_ARVALID    = arc_valid[DEPTH];
    assign arc_ready[DEPTH] = M_AXI_ARREADY;
    genvar gar;
    generate
        for (gar = 0; gar < DEPTH; gar = gar + 1) begin : AR_STAGE
            axi4_regslice_skid_stage #(.WIDTH(AR_W)) u_ar (
                .clk(ACLK), .resetn(ARESETN),
                .s_data(arc_data[gar]),   .s_valid(arc_valid[gar]),   .s_ready(arc_ready[gar]),
                .m_data(arc_data[gar+1]), .m_valid(arc_valid[gar+1]), .m_ready(arc_ready[gar+1])
            );
        end
    endgenerate

    // ----------------------------------------------------------------- R channel (M->S) -----
    wire [R_W-1:0] rc_data  [0:DEPTH];
    wire           rc_valid [0:DEPTH];
    wire           rc_ready [0:DEPTH];
    assign rc_data[0]   = {M_AXI_RID, M_AXI_RDATA, M_AXI_RRESP, M_AXI_RLAST};
    assign rc_valid[0]  = M_AXI_RVALID;
    assign M_AXI_RREADY = rc_ready[0];
    assign {S_AXI_RID, S_AXI_RDATA, S_AXI_RRESP, S_AXI_RLAST} = rc_data[DEPTH];
    assign S_AXI_RVALID    = rc_valid[DEPTH];
    assign rc_ready[DEPTH] = S_AXI_RREADY;
    genvar gr;
    generate
        for (gr = 0; gr < DEPTH; gr = gr + 1) begin : R_STAGE
            axi4_regslice_skid_stage #(.WIDTH(R_W)) u_r (
                .clk(ACLK), .resetn(ARESETN),
                .s_data(rc_data[gr]),   .s_valid(rc_valid[gr]),   .s_ready(rc_ready[gr]),
                .m_data(rc_data[gr+1]), .m_valid(rc_valid[gr+1]), .m_ready(rc_ready[gr+1])
            );
        end
    endgenerate
endmodule
