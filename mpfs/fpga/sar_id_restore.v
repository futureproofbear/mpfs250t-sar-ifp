// sar_id_restore.v -- AXI ID down/up converter for the AXIIC_C0 SLAVE0 -> FIC_0_AXI4_S
// boundary. Replaces SmartDesign's lossy "truncate + 5'h0 pad" wrapper with the
// store-identity / restore-on-response scheme:
//
//   AR/AW: the interconnect's wide ID (9-bit) is stored, keyed by its low 4 bits,
//          and the low 4 bits are passed to FIC0_S as the narrow tag.
//   R/B  : FIC0_S returns the 4-bit tag; the stored upper bits are restored so the
//          interconnect sees the FULL original ID and routes the response home.
//
// This is SNOOP-ONLY: it does not touch the handshake/addr/data signals (those wire
// straight through in SmartDesign). It only transforms ID buses + watches the *VALID&
// *READY handshakes to know when to capture.
//
// Assumption (true for this design): at most one outstanding transaction per distinct
// low-4 tag. Our sequencer runs kernels strictly one-at-a-time with NUM_THREADS=1, so
// outstanding IDs never collide in the low 4 bits. (For a general OoO multi-master case
// you'd allocate fresh tags + backpressure; not needed here.)
//
// Integration (SmartDesign, then synth/P&R/regenerate bitstream):
//   * Remove the auto-inserted ARID/RID/AWID/BID slice+concat objects on the
//     AXIIC_C0 SLAVE0 <-> FIC_0_AXI4_S path.
//   * Instantiate this module on that path; wire the ID buses through it, snoop the
//     four handshakes, and connect every non-ID signal AXIIC_C0<->FIC0_S directly.
//   * ID widths: WIDE=9 (AXIIC_C0 SLAVE0 side), NARROW=4 (FIC0_S side).

module sar_id_restore #(
    parameter WIDE   = 9,
    parameter NARROW = 4
)(
    input  wire               aclk,
    input  wire               aresetn,        // active low

    // ---- read address (interconnect -> FIC0_S): downsize ----
    input  wire [WIDE-1:0]    s_arid,          // from AXIIC_C0 SLAVE0
    input  wire               s_arvalid,
    input  wire               s_arready,
    output wire [NARROW-1:0]  m_arid,          // to FIC0_S

    // ---- read data (FIC0_S -> interconnect): upsize/restore ----
    input  wire [NARROW-1:0]  m_rid,           // from FIC0_S
    input  wire               m_rvalid,
    input  wire               m_rready,
    output wire [WIDE-1:0]    s_rid,           // to AXIIC_C0 SLAVE0

    // ---- write address (interconnect -> FIC0_S): downsize ----
    input  wire [WIDE-1:0]    s_awid,
    input  wire               s_awvalid,
    input  wire               s_awready,
    output wire [NARROW-1:0]  m_awid,

    // ---- write response (FIC0_S -> interconnect): upsize/restore ----
    input  wire [NARROW-1:0]  m_bid,
    input  wire               m_bvalid,
    input  wire               m_bready,
    output wire [WIDE-1:0]    s_bid
);
    localparam UPPER = WIDE - NARROW;   // bits to stash/restore (e.g. 5)

    // tag tables: stored upper bits, keyed by the narrow (low) tag
    reg [UPPER-1:0] ar_tab [0:(1<<NARROW)-1];
    reg [UPPER-1:0] aw_tab [0:(1<<NARROW)-1];

    integer i;
    always @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            for (i = 0; i < (1<<NARROW); i = i + 1) begin
                ar_tab[i] <= {UPPER{1'b0}};
                aw_tab[i] <= {UPPER{1'b0}};
            end
        end else begin
            if (s_arvalid & s_arready) ar_tab[s_arid[NARROW-1:0]] <= s_arid[WIDE-1:NARROW];
            if (s_awvalid & s_awready) aw_tab[s_awid[NARROW-1:0]] <= s_awid[WIDE-1:NARROW];
        end
    end

    // downsize: pass the low tag straight through
    assign m_arid = s_arid[NARROW-1:0];
    assign m_awid = s_awid[NARROW-1:0];

    // upsize/restore: re-attach the stashed upper bits to the returned tag
    assign s_rid  = { ar_tab[m_rid[NARROW-1:0]], m_rid[NARROW-1:0] };
    assign s_bid  = { aw_tab[m_bid[NARROW-1:0]], m_bid[NARROW-1:0] };

    // (m_rvalid/m_rready/m_bvalid/m_bready are observed for context only; this module
    //  drives no handshakes -- they pass through directly in SmartDesign.)
    wire _unused = &{1'b0, m_rvalid, m_rready, m_bvalid, m_bready};
endmodule
