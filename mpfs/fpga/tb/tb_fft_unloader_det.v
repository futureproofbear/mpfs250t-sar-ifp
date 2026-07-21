// tb_fft_unloader_det.v -- value-level check of fft_unloader_v.
//
// Reproduces the failure that killed the HLS fabric detect: negative I/Q treated as UNSIGNED,
// which saturates ~50% of the image while still passing a correlation check. So this TB does
// NOT correlate -- it diffs every uint16 magnitude against a behavioural model of cpu_detect()
// / cpu_isqrt() from sar_sequencer.c, and it deliberately feeds mostly-negative operands.
//
// Case 1: det_en=0 -> the output must be the input beats verbatim (legacy contract intact).
// Case 2: det_en=1 -> four packed uint16 magnitudes per two input beats, little-endian.
`timescale 1ns/1ps
module tb_fft_unloader_det;
    localparam integer NB = 4096;              // one row = SAR_ROW_BEATS

    reg clk = 0, resetn = 0;
    always #8 clk = ~clk;                      // 62.5 MHz

    // ---- AXI4-Lite control ----
    reg  [11:0] s_awaddr; reg s_awvalid; wire s_awready;
    reg  [31:0] s_wdata;  reg s_wvalid;  wire s_wready;
    wire s_bvalid; reg s_bready = 1;
    reg  [11:0] s_araddr; reg s_arvalid = 0; wire s_arready;
    wire [31:0] s_rdata;  wire s_rvalid; reg s_rready = 1;

    // ---- stream in ----
    reg  [63:0] t_data; reg t_valid; wire t_ready;

    // ---- AXI write master out ----
    wire [3:0] m_awid; wire [31:0] m_awaddr; wire [7:0] m_awlen;
    wire [2:0] m_awsize; wire [1:0] m_awburst; wire m_awvalid; reg m_awready;
    wire [63:0] m_wdata; wire [7:0] m_wstrb; wire m_wlast, m_wvalid; reg m_wready;
    reg [3:0] m_bid; reg [1:0] m_bresp; reg m_bvalid; wire m_bready;

    fft_unloader_v #(.AXI_ADDR_W(32), .AXI_DATA_W(64), .AXI_ID_W(4)) dut (
        .clk(clk), .resetn(resetn),
        .s_awaddr(s_awaddr), .s_awvalid(s_awvalid), .s_awready(s_awready),
        .s_wdata(s_wdata), .s_wvalid(s_wvalid), .s_wready(s_wready),
        .s_bvalid(s_bvalid), .s_bready(s_bready),
        .s_araddr(s_araddr), .s_arvalid(s_arvalid), .s_arready(s_arready),
        .s_rdata(s_rdata), .s_rvalid(s_rvalid), .s_rready(s_rready),
        .s_axis_tdata(t_data), .s_axis_tvalid(t_valid), .s_axis_tready(t_ready),
        .m_awid(m_awid), .m_awaddr(m_awaddr), .m_awlen(m_awlen), .m_awsize(m_awsize),
        .m_awburst(m_awburst), .m_awvalid(m_awvalid), .m_awready(m_awready),
        .m_wdata(m_wdata), .m_wstrb(m_wstrb), .m_wlast(m_wlast), .m_wvalid(m_wvalid),
        .m_wready(m_wready), .m_bid(m_bid), .m_bresp(m_bresp), .m_bvalid(m_bvalid),
        .m_bready(m_bready)
    );

    // ---- trivial AXI write slave: address-ordered store, B after WLAST ----
    reg [63:0] ddr [0:8191];
    reg [31:0] waddr;
    integer    wcount = 0;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            m_awready <= 1; m_wready <= 1; m_bvalid <= 0; m_bresp <= 2'b00; m_bid <= 0;
            wcount <= 0;
        end else begin
            // random AW/W backpressure + delayed B: FIC0 does not hold ready high for us
            m_awready <= ($random % 4) != 0;
            m_wready  <= ($random % 3) != 0;
            if (m_awvalid && m_awready) waddr <= m_awaddr;
            if (m_wvalid && m_wready) begin
                ddr[waddr[15:3]] <= m_wdata;
                waddr  <= waddr + 32'd8;
                wcount <= wcount + 1;
                if (m_wlast) m_bvalid <= 1'b1;
            end
            if (m_bvalid && m_bready) m_bvalid <= 1'b0;
        end
    end

    // ---- behavioural cpu_isqrt (sar_sequencer.c:463) ----
    function [15:0] mdl_isqrt;
        input [63:0] v;
        reg [63:0] one, res, op;
        integer i;
        begin
            one = 64'd1 << 30; res = 0; op = v;
            for (i = 0; i < 16; i = i + 1) begin
                if (op >= res + one) begin op = op - (res + one); res = (res >> 1) + one; end
                else res = res >> 1;
                one = one >> 2;
            end
            mdl_isqrt = res[15:0];
        end
    endfunction
    function [15:0] mdl_mag;                    // cpu_detect() for one complex sample
        input [31:0] w;
        reg signed [31:0] re, im;
        begin
            re = $signed(w[31:16]);
            im = $signed(w[15:0]);
            mdl_mag = mdl_isqrt(re*re + im*im);
        end
    endfunction

    task lite_w; input [11:0] a; input [31:0] d; begin
        @(posedge clk); s_awaddr <= a; s_wdata <= d; s_awvalid <= 1; s_wvalid <= 1;
        @(posedge clk); while (!s_awready) @(posedge clk);
        s_awvalid <= 0; s_wvalid <= 0; @(posedge clk);
    end endtask

    reg [63:0] stim [0:NB-1];
    integer i, errs, mode;
    reg [63:0] got, exp;

    initial begin
        s_awvalid = 0; s_wvalid = 0; t_valid = 0; t_data = 0; errs = 0;
        repeat (4) @(posedge clk); resetn = 1; repeat (4) @(posedge clk);

        // Mostly-NEGATIVE operands: the exact regime the HLS detect got wrong.
        for (i = 0; i < NB; i = i + 1) begin
            stim[i] = {$random, $random};
            if (i < 64) stim[i] = {16'hF001, 16'hF002, 16'h8000, 16'h8000};  // extremes
        end

        for (mode = 0; mode < 2; mode = mode + 1) begin
            lite_w(12'h018, mode);                       // DET_CTRL
            lite_w(12'h00c, 32'h0000_0000);              // ARG0 dst_base
            lite_w(12'h010, NB);                         // ARG1 nbeats (stream beats)
            lite_w(12'h008, 32'h1);                      // START
            for (i = 0; i < NB; i = i + 1) begin
                if (($random % 5) == 0) begin        // gaps: CoreFFT does not stream solid
                    t_valid <= 0; @(posedge clk);
                end
                t_data <= stim[i]; t_valid <= 1;
                @(posedge clk); while (!t_ready) @(posedge clk);
            end
            t_valid <= 0;
            repeat (4000) @(posedge clk);

            if (mode == 0) begin
                for (i = 0; i < NB; i = i + 1)
                    if (ddr[i] !== stim[i]) begin
                        errs = errs + 1;
                        if (errs < 6) $display("PASSTHRU beat %0d got %h exp %h", i, ddr[i], stim[i]);
                    end
                $display("mode0 passthrough: %0d beats written, %0d mismatches", wcount, errs);
            end else begin
                for (i = 0; i < NB/2; i = i + 1) begin
                    exp = {mdl_mag(stim[2*i+1][63:32]), mdl_mag(stim[2*i+1][31:0]),
                           mdl_mag(stim[2*i  ][63:32]), mdl_mag(stim[2*i  ][31:0])};
                    got = ddr[i];
                    if (got !== exp) begin
                        errs = errs + 1;
                        if (errs < 6) $display("DETECT beat %0d got %h exp %h", i, got, exp);
                    end
                end
                $display("mode1 detect: %0d beats written (expect %0d), %0d mismatches",
                         wcount, NB/2, errs);
            end
            wcount = 0;
            repeat (20) @(posedge clk);
        end

        // sticky error latches must all be clear
        @(posedge clk); s_araddr <= 12'h014; s_arvalid <= 1;
        @(posedge clk); while (!s_arready) @(posedge clk); s_arvalid <= 0;
        @(posedge clk); while (!s_rvalid) @(posedge clk);
        $display("STATUS2 sticky = %h (must be 0)", s_rdata);
        if (s_rdata !== 32'd0) errs = errs + 1;

        if (errs == 0) $display("TB PASS"); else $display("TB FAIL: %0d errors", errs);
        $finish;
    end
endmodule
