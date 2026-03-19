`timescale 1ns/1ps
// =============================================================================
// tb_thresh_comparator.sv
// Testbench for AXI-Lite Threshold Comparator with Latched IRQ
//
// Test cases:
//   1. Reset behaviour
//   2. Threshold register read/write
//   3. ABOVE mode — IRQ fires crossing hi, re-arms after crossing lo
//   4. BELOW mode — IRQ fires crossing lo, re-arms after crossing hi
//   5. BOTH  mode — fires on both crossings with hysteresis
//   6. IRQ clear — firmware acknowledges via CTRL[2]
//   7. No spurious IRQ — sample inside band never fires
// =============================================================================

module tb_thresh_comparator;

    // =========================================================================
    // Parameters
    // =========================================================================
    localparam CLK_PERIOD = 10;    // 100 MHz
    localparam DATA_WIDTH = 12;

    // Default thresholds
    localparam THRESH_HI = 12'd3584;   // 0xE00
    localparam THRESH_LO = 12'd512;    // 0x200

    // =========================================================================
    // DUT Signals
    // =========================================================================
    logic        aclk, aresetn;
    logic [4:0]  s_axil_awaddr;
    logic        s_axil_awvalid, s_axil_awready;
    logic [31:0] s_axil_wdata;
    logic [3:0]  s_axil_wstrb;
    logic        s_axil_wvalid,  s_axil_wready;
    logic [1:0]  s_axil_bresp;
    logic        s_axil_bvalid,  s_axil_bready;
    logic [4:0]  s_axil_araddr;
    logic        s_axil_arvalid, s_axil_arready;
    logic [31:0] s_axil_rdata;
    logic [1:0]  s_axil_rresp;
    logic        s_axil_rvalid,  s_axil_rready;
    logic        irq_out;

    // =========================================================================
    // DUT Instantiation
    // =========================================================================
    thresh_comparator #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(5)
    ) dut (.*);

    // =========================================================================
    // Clock
    // =========================================================================
    initial aclk = 0;
    always #(CLK_PERIOD/2) aclk = ~aclk;

    // =========================================================================
    // Test Tracking
    // =========================================================================
    int pass_count = 0;
    int fail_count = 0;

    task automatic check(
        input string      name,
        input logic [31:0] got,
        input logic [31:0] expected
    );
        if (got === expected) begin
            $display("[PASS] %s  got=0x%08X", name, got);
            pass_count++;
        end else begin
            $display("[FAIL] %s  got=0x%08X  expected=0x%08X", name, got, expected);
            fail_count++;
        end
    endtask

    // =========================================================================
    // AXI-Lite Bus Tasks
    // =========================================================================
    task automatic axil_write(input logic [4:0] addr, input logic [31:0] data);
        @(posedge aclk);
        s_axil_awaddr  = addr;
        s_axil_awvalid = 1'b1;
        s_axil_wdata   = data;
        s_axil_wstrb   = 4'hF;
        s_axil_wvalid  = 1'b1;
        fork
            begin wait(s_axil_awready); @(posedge aclk); s_axil_awvalid = 1'b0; end
            begin wait(s_axil_wready);  @(posedge aclk); s_axil_wvalid  = 1'b0; end
        join
        s_axil_bready = 1'b1;
        wait(s_axil_bvalid);
        @(posedge aclk);
        s_axil_bready = 1'b0;
    endtask

    task automatic axil_read(input logic [4:0] addr, output logic [31:0] data);
        @(posedge aclk);
        s_axil_araddr  = addr;
        s_axil_arvalid = 1'b1;
        s_axil_rready  = 1'b1;
        wait(s_axil_arready);
        @(posedge aclk);
        s_axil_arvalid = 1'b0;
        wait(s_axil_rvalid);
        data = s_axil_rdata;
        @(posedge aclk);
        s_axil_rready = 1'b0;
    endtask

    task automatic push_sample(input logic [11:0] sample);
        axil_write(5'h0C, {20'b0, sample});
        @(posedge aclk);
    endtask

    // dir: 0=ABOVE, 1=BELOW, 2=BOTH — must match current operating mode
    task automatic clear_irq(input logic [1:0] dir);
        // Assert irq_clear keeping correct direction and enable
        axil_write(5'h00, {28'b0, 1'b1, 1'b1, dir}); // enable|irq_clear|dir
        axil_write(5'h00, {28'b0, 1'b1, 1'b0, dir}); // enable|irq_clear=0|dir
        @(posedge aclk);
    endtask

    // =========================================================================
    // Test Variables
    // =========================================================================
    logic [31:0] rdata;

    // =========================================================================
    // Main Test Sequence
    // =========================================================================
    initial begin
        $display("========================================");
        $display("  Threshold Comparator with IRQ TB");
        $display("========================================");

        // Init signals
        aresetn        = 1'b0;
        s_axil_awvalid = 1'b0;
        s_axil_wvalid  = 1'b0;
        s_axil_bready  = 1'b0;
        s_axil_arvalid = 1'b0;
        s_axil_rready  = 1'b0;
        s_axil_awaddr  = '0;
        s_axil_wdata   = '0;
        s_axil_wstrb   = '0;
        s_axil_araddr  = '0;

        // ------------------------------------------------------------------
        // Test 1: Reset
        // ------------------------------------------------------------------
        $display("\n-- Test 1: Reset --");
        repeat(5) @(posedge aclk);
        aresetn = 1'b1;
        @(posedge aclk);

        axil_read(5'h10, rdata);
        check("STATUS after reset = 0", rdata, 32'h0);
        check("IRQ after reset = 0", {31'b0, irq_out}, 32'h0);

        // ------------------------------------------------------------------
        // Test 2: Threshold register R/W
        // ------------------------------------------------------------------
        $display("\n-- Test 2: Threshold Registers --");
        axil_write(5'h04, 32'h0000_0E00);  // THRESH_HI = 3584
        axil_write(5'h08, 32'h0000_0200);  // THRESH_LO = 512
        axil_read(5'h04, rdata);
        check("THRESH_HI readback", rdata, 32'h0000_0E00);
        axil_read(5'h08, rdata);
        check("THRESH_LO readback", rdata, 32'h0000_0200);

        // ------------------------------------------------------------------
        // Test 3: ABOVE mode
        // CTRL = enable(1) | irq_clear(0) | dir=ABOVE(00) = 0x8
        // ------------------------------------------------------------------
        $display("\n-- Test 3: ABOVE Mode --");
        axil_write(5'h00, 32'h0000_0008); // enable, dir=ABOVE

        // Sample inside band — no IRQ
        push_sample(12'd1000);
        check("No IRQ inside band", {31'b0, irq_out}, 32'h0);

        // Sample above THRESH_HI (3584) — IRQ fires
        push_sample(12'd4000);
        @(posedge aclk);
        check("IRQ fires above THRESH_HI", {31'b0, irq_out}, 32'h1);

        // Read STATUS — check last_crossing=0 (above), last_sample=4000
        axil_read(5'h10, rdata);
        check("STATUS crossing=above",
              rdata & 32'h0000_0002, 32'h0);               // bit[1]=0
        check("STATUS last_sample=4000",
              (rdata >> 2) & 12'hFFF, 32'd4000);

        // Another sample above — still tripped, IRQ stays high
        push_sample(12'd3900);
        check("IRQ stays latched", {31'b0, irq_out}, 32'h1);

        // Sample below THRESH_LO (512) — re-arms, but IRQ stays until cleared
        push_sample(12'd100);
        check("IRQ still latched after re-arm", {31'b0, irq_out}, 32'h1);

        // Clear IRQ
        clear_irq(2'd0);  // ABOVE mode
        check("IRQ cleared", {31'b0, irq_out}, 32'h0);

        // Now re-armed — fire again
        push_sample(12'd4000);
        @(posedge aclk);
        check("IRQ fires again after re-arm", {31'b0, irq_out}, 32'h1);
        clear_irq(2'd0);  // ABOVE mode

        // ------------------------------------------------------------------
        // Test 4: BELOW mode
        // CTRL = enable(1) | dir=BELOW(01) = 0x9
        // ------------------------------------------------------------------
        $display("\n-- Test 4: BELOW Mode --");
        axil_write(5'h00, 32'h0000_0009); // enable, dir=BELOW
        push_sample(12'd1000); // inside band, re-arm state machine

        // Sample below THRESH_LO — IRQ fires
        push_sample(12'd100);
        @(posedge aclk);
        check("IRQ fires below THRESH_LO", {31'b0, irq_out}, 32'h1);

        axil_read(5'h10, rdata);
        check("STATUS crossing=below",
              rdata & 32'h0000_0002, 32'h2);   // bit[1]=1

        // Re-arm by going above THRESH_HI
        push_sample(12'd4000);
        clear_irq(2'd1);  // BELOW mode
        check("IRQ cleared in BELOW mode", {31'b0, irq_out}, 32'h0);

        // ------------------------------------------------------------------
        // Test 5: BOTH mode
        // CTRL = enable(1) | dir=BOTH(10) = 0xA
        // ------------------------------------------------------------------
        $display("\n-- Test 5: BOTH Mode --");
        axil_write(5'h00, 32'h0000_000A); // enable, dir=BOTH

        // Start mid-band
        push_sample(12'd2000);
        check("No IRQ mid-band", {31'b0, irq_out}, 32'h0);

        // Cross above
        push_sample(12'd4000);
        @(posedge aclk);
        check("IRQ fires crossing above in BOTH mode", {31'b0, irq_out}, 32'h1);
        clear_irq(2'd2);  // BOTH mode

        // After above crossing, state=ST_TRIPPED_HI.
        // First push below THRESH_LO re-arms to ST_ARMED.
        // Second push below THRESH_LO fires the BELOW IRQ.
        push_sample(12'd100);   // re-arm (exits ST_TRIPPED_HI)
        push_sample(12'd100);   // now armed — fires BELOW IRQ
        @(posedge aclk);
        check("IRQ fires crossing below in BOTH mode", {31'b0, irq_out}, 32'h1);
        clear_irq(2'd2);  // BOTH mode

        // ------------------------------------------------------------------
        // Test 6: No spurious IRQ — sample sits exactly on boundary
        // ------------------------------------------------------------------
        $display("\n-- Test 6: No Spurious IRQ Inside Band --");
        axil_write(5'h00, 32'h0000_0008); // ABOVE mode, re-arm first
        push_sample(12'd100);  // go below lo to re-arm
        clear_irq(2'd0);  // ABOVE mode

        // Repeatedly push samples inside the band — never fires
        repeat(10) push_sample(12'd2000);
        check("No IRQ after 10 in-band samples", {31'b0, irq_out}, 32'h0);

        // Push exactly at THRESH_HI — not above, no IRQ (> not >=)
        push_sample(THRESH_HI);
        check("No IRQ at exactly THRESH_HI (> not >=)", {31'b0, irq_out}, 32'h0);

        // Push one above — fires
        push_sample(THRESH_HI + 12'd1);
        @(posedge aclk);
        check("IRQ fires one above THRESH_HI", {31'b0, irq_out}, 32'h1);
        clear_irq(2'd0);  // ABOVE mode

        // ------------------------------------------------------------------
        // Summary
        // ------------------------------------------------------------------
        $display("\n========================================");
        $display("  Results: %0d passed, %0d failed", pass_count, fail_count);
        $display("========================================");
        if (fail_count == 0)
            $display("  ALL TESTS PASSED");
        else
            $display("  SOME TESTS FAILED");

        $finish;
    end

    // =========================================================================
    // Waveform Dump
    // =========================================================================
    initial begin
        $dumpfile("tb_thresh_comparator.vcd");
        $dumpvars(0, tb_thresh_comparator);
    end

    // =========================================================================
    // Timeout Watchdog
    // =========================================================================
    initial begin
        #200000;
        $display("[ERROR] Simulation timeout!");
        $finish;
    end

endmodule