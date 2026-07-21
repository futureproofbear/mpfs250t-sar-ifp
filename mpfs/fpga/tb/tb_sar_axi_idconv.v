// tb_sar_axi_idconv.v -- proves the AXI ID converter routes responses home when TWO fabric
// masters are in flight at once.
//
// THE BUG THIS EXISTS FOR: the 11-bit target ID is {master_number[2:0], master_id[7:0]}. The
// converter used to forward ARID[3:0] = master_id[3:0] and stash the upper bits keyed by that
// tag. Every SmartHLS kernel here presents master_id = 0, so every master aliased onto tag 0 and
// the stash held only the last writer -- responses routed to the WRONG master. It was invisible
// while kernels ran strictly one at a time, which is exactly why the old header could only claim
// safety for "sequential kernels".
//
// This is not detectable by synthesis, timing, or a correlation check on the image. It is a pure
// protocol-routing fault, so simulation is the only gate. The decisive case is TWO MASTERS THAT
// SHARE master_id AND DIFFER ONLY IN master_number -- the real situation on this design.
//
// Cases:
//   1. interleaved AR from master 3 and master 6 (both master_id=0), responses returned IN ORDER
//   2. same, responses returned OUT OF ORDER (the slave is allowed to reorder between IDs)
//   3. interleaved AW/B, same two masters
//   4. non-zero master_id preserved (master 2 with id 0x5A) -- the stash must still carry it
//
// Run:
//   MS=/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem
//   $MS/vlib work && $MS/vlog -work work tb_sar_axi_idconv.v ../sar_axi_idconv.v
//   $MS/vsim -c -do "run -all; quit -f" work.tb_sar_axi_idconv
// Expected: "ID CONVERTER: PASS (0 mis-routed)".
// Mutation check (must FAIL): revert M_AXI_ARID to S_AXI_ARID[3:0] and S_AXI_RID to
// {ar_tab[M_AXI_RID[3:0]], M_AXI_RID[3:0]} -- cases 1-3 must then report mis-routes.
`timescale 1ns/1ps

module tb_sar_axi_idconv;

    reg ACLK = 0, ARESETN = 0;
    always #8 ACLK = ~ACLK;

    // ---- S side (from AXIIC_C0) ----
    reg  [10:0] S_ARID, S_AWID;
    reg         S_ARVALID, S_AWVALID;
    wire        S_ARREADY, S_AWREADY;
    wire [10:0] S_RID, S_BID;
    wire        S_RVALID, S_BVALID;

    // ---- M side (to MSS FIC_0) ----
    wire [3:0]  M_ARID, M_AWID;
    wire        M_ARVALID, M_AWVALID;
    reg         M_ARREADY, M_AWREADY;
    reg  [3:0]  M_RID, M_BID;
    reg         M_RVALID, M_BVALID;

    sar_axi_idconv dut (
        .ACLK(ACLK), .ARESETN(ARESETN),
        .S_AXI_AWID(S_AWID), .S_AXI_AWADDR(32'd0), .S_AXI_AWLEN(8'd0), .S_AXI_AWSIZE(3'd3),
        .S_AXI_AWBURST(2'b01), .S_AXI_AWLOCK(2'b0), .S_AXI_AWCACHE(4'b0), .S_AXI_AWPROT(3'b0),
        .S_AXI_AWQOS(4'b0), .S_AXI_AWREGION(4'b0), .S_AXI_AWUSER(1'b0),
        .S_AXI_AWVALID(S_AWVALID), .S_AXI_AWREADY(S_AWREADY),
        .S_AXI_WDATA(64'd0), .S_AXI_WSTRB(8'hFF), .S_AXI_WLAST(1'b1), .S_AXI_WUSER(1'b0),
        .S_AXI_WVALID(1'b0), .S_AXI_WREADY(),
        .S_AXI_BID(S_BID), .S_AXI_BRESP(), .S_AXI_BVALID(S_BVALID), .S_AXI_BREADY(1'b1),
        .S_AXI_ARID(S_ARID), .S_AXI_ARADDR(32'd0), .S_AXI_ARLEN(8'd0), .S_AXI_ARSIZE(3'd3),
        .S_AXI_ARBURST(2'b01), .S_AXI_ARLOCK(2'b0), .S_AXI_ARCACHE(4'b0), .S_AXI_ARPROT(3'b0),
        .S_AXI_ARQOS(4'b0), .S_AXI_ARREGION(4'b0), .S_AXI_ARUSER(1'b0),
        .S_AXI_ARVALID(S_ARVALID), .S_AXI_ARREADY(S_ARREADY),
        .S_AXI_RID(S_RID), .S_AXI_RDATA(), .S_AXI_RRESP(), .S_AXI_RLAST(),
        .S_AXI_RVALID(S_RVALID), .S_AXI_RREADY(1'b1),
        .M_AXI_AWID(M_AWID), .M_AXI_AWADDR(), .M_AXI_AWLEN(), .M_AXI_AWSIZE(), .M_AXI_AWBURST(),
        .M_AXI_AWLOCK(), .M_AXI_AWCACHE(), .M_AXI_AWPROT(), .M_AXI_AWQOS(),
        .M_AXI_AWVALID(M_AWVALID), .M_AXI_AWREADY(M_AWREADY),
        .M_AXI_WDATA(), .M_AXI_WSTRB(), .M_AXI_WLAST(), .M_AXI_WVALID(), .M_AXI_WREADY(1'b1),
        .M_AXI_BID(M_BID), .M_AXI_BRESP(2'b00), .M_AXI_BVALID(M_BVALID), .M_AXI_BREADY(),
        .M_AXI_ARID(M_ARID), .M_AXI_ARADDR(), .M_AXI_ARLEN(), .M_AXI_ARSIZE(), .M_AXI_ARBURST(),
        .M_AXI_ARLOCK(), .M_AXI_ARCACHE(), .M_AXI_ARPROT(), .M_AXI_ARQOS(),
        .M_AXI_ARVALID(M_ARVALID), .M_AXI_ARREADY(M_ARREADY),
        .M_AXI_RID(M_RID), .M_AXI_RDATA(64'd0), .M_AXI_RRESP(2'b00), .M_AXI_RLAST(1'b1),
        .M_AXI_RVALID(M_RVALID), .M_AXI_RREADY()
    );

    integer errors = 0;
    reg [3:0] tag_of [0:7];          // master_number -> the 4-bit tag the DUT forwarded

    task issue_ar(input [2:0] mnum, input [7:0] mid);
    begin
        @(posedge ACLK);
        S_ARID <= {mnum, mid}; S_ARVALID <= 1'b1; M_ARREADY <= 1'b1;
        @(posedge ACLK);
        while (!S_ARREADY) @(posedge ACLK);
        tag_of[mnum] = M_ARID;       // capture what actually went to FIC_0
        S_ARVALID <= 1'b0; M_ARREADY <= 1'b0;
        @(posedge ACLK);
    end
    endtask

    task issue_aw(input [2:0] mnum, input [7:0] mid);
    begin
        @(posedge ACLK);
        S_AWID <= {mnum, mid}; S_AWVALID <= 1'b1; M_AWREADY <= 1'b1;
        @(posedge ACLK);
        while (!S_AWREADY) @(posedge ACLK);
        tag_of[mnum] = M_AWID;
        S_AWVALID <= 1'b0; M_AWREADY <= 1'b0;
        @(posedge ACLK);
    end
    endtask

    // Return a response bearing master `mnum`'s tag and check it reconstructs that master's ID.
    task resp_r(input [2:0] mnum, input [7:0] mid, input [127:0] label);
    begin
        @(posedge ACLK);
        M_RID <= tag_of[mnum]; M_RVALID <= 1'b1;
        @(posedge ACLK);
        if (S_RID !== {mnum, mid}) begin
            $display("  MIS-ROUTED R [%0s]: master %0d id 0x%02x -> tag 0x%01x -> RID 0x%03x (want 0x%03x)",
                     label, mnum, mid, tag_of[mnum], S_RID, {mnum, mid});
            errors = errors + 1;
        end
        M_RVALID <= 1'b0;
        @(posedge ACLK);
    end
    endtask

    task resp_b(input [2:0] mnum, input [7:0] mid, input [127:0] label);
    begin
        @(posedge ACLK);
        M_BID <= tag_of[mnum]; M_BVALID <= 1'b1;
        @(posedge ACLK);
        if (S_BID !== {mnum, mid}) begin
            $display("  MIS-ROUTED B [%0s]: master %0d id 0x%02x -> tag 0x%01x -> BID 0x%03x (want 0x%03x)",
                     label, mnum, mid, tag_of[mnum], S_BID, {mnum, mid});
            errors = errors + 1;
        end
        M_BVALID <= 1'b0;
        @(posedge ACLK);
    end
    endtask

    initial begin
        S_ARVALID = 0; S_AWVALID = 0; M_ARREADY = 0; M_AWREADY = 0;
        M_RVALID = 0; M_BVALID = 0; M_RID = 0; M_BID = 0; S_ARID = 0; S_AWID = 0;
        repeat (6) @(posedge ACLK);
        ARESETN = 1;
        repeat (4) @(posedge ACLK);

        // -- case 1: two masters, SAME master_id (the real situation), responses in order --
        issue_ar(3'd3, 8'h00);
        issue_ar(3'd6, 8'h00);
        if (tag_of[3] === tag_of[6]) begin
            $display("  ALIASED: masters 3 and 6 both forwarded tag 0x%01x -- responses cannot be routed",
                     tag_of[3]);
            errors = errors + 1;
        end
        resp_r(3'd3, 8'h00, "case1 in-order");
        resp_r(3'd6, 8'h00, "case1 in-order");

        // -- case 2: same, responses OUT OF ORDER (legal: a slave may reorder between IDs) --
        issue_ar(3'd3, 8'h00);
        issue_ar(3'd6, 8'h00);
        resp_r(3'd6, 8'h00, "case2 out-of-order");
        resp_r(3'd3, 8'h00, "case2 out-of-order");

        // -- case 3: write channel, same two masters --
        issue_aw(3'd3, 8'h00);
        issue_aw(3'd6, 8'h00);
        resp_b(3'd6, 8'h00, "case3 write");
        resp_b(3'd3, 8'h00, "case3 write");

        // -- case 4: a non-zero master_id must survive the round trip --
        issue_ar(3'd2, 8'h5A);
        resp_r(3'd2, 8'h5A, "case4 nonzero id");

        $display("\n==== ID CONVERTER: %s (%0d mis-routed) ====",
                 errors ? "FAIL" : "PASS", errors);
        if (errors) $fatal(1, "responses do not route home");
        $finish;
    end

    initial begin
        #200000;
        $display("==== ID CONVERTER: FAIL (timeout) ====");
        $fatal(1, "timeout");
    end
endmodule
