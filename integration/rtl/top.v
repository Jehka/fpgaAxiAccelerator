`timescale 1ns/1ps
// =============================================================================
// top.v
// Sensor Acquisition Pipeline + AXI-Lite Moving Average Accelerator
//
// Architecture:
//   ADC samples flow two ways simultaneously:
//     Path A (unchanged): sample → FIFO → UART → host PC  (raw data)
//     Path B (new):       sample → axi_moving_avg          (filtered result)
//
//   The accelerator is controlled via a simple AXI-Lite master stub.
//   In this integration the AXI master is a minimal static initialiser —
//   it configures the accelerator once at startup (enable, window=8) and
//   then lets sample_valid drive DATA_IN directly via the fast path.
//
//   For full firmware control (read RESULT back, change window at runtime)
//   replace axil_master_stub with a MicroBlaze or your own state machine.
// =============================================================================

module top (
    input  wire clk,          // 100 MHz board clock
    input  wire rst_n,        // active-low reset

    // SPI ADC pins
    input  wire adc_miso,
    output wire adc_cs_n,
    output wire adc_sclk,

    // UART output
    output wire uart_tx,

    // Filtered result output (optional — wire to LED/logic analyser/UART2)
    output wire [11:0] filtered_result,
    output wire        filter_valid
);

    // =========================================================================
    // Internal Signals — existing pipeline (unchanged)
    // =========================================================================
    wire        sample_tick;
    wire [11:0] sample;
    wire        sample_valid;

    wire [11:0] fifo_data;
    wire        fifo_empty;
    wire        fifo_full;
    wire        fifo_rd_en;

    wire        tx_start;
    wire [7:0]  tx_data;
    wire        tx_busy;

    // =========================================================================
    // Internal Signals — AXI-Lite bus to accelerator
    // =========================================================================
    // Write address channel
    wire [4:0]  m_axil_awaddr;
    wire        m_axil_awvalid;
    wire        m_axil_awready;
    // Write data channel
    wire [31:0] m_axil_wdata;
    wire [3:0]  m_axil_wstrb;
    wire        m_axil_wvalid;
    wire        m_axil_wready;
    // Write response channel
    wire [1:0]  m_axil_bresp;
    wire        m_axil_bvalid;
    wire        m_axil_bready;
    // Read address channel
    wire [4:0]  m_axil_araddr;
    wire        m_axil_arvalid;
    wire        m_axil_arready;
    // Read data channel
    wire [31:0] m_axil_rdata;
    wire [1:0]  m_axil_rresp;
    wire        m_axil_rvalid;
    wire        m_axil_rready;

    // IRQ from accelerator
    wire        accel_irq;

    // =========================================================================
    // Sample Tick Generator (unchanged)
    // =========================================================================
    sample_tick_gen #(
        .CLK_FREQ_HZ(100_000_000),
        .SAMPLE_RATE_HZ(1_000)
    ) tick_gen (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick)
    );

    // =========================================================================
    // ADC Interface (unchanged)
    // =========================================================================
    adc_interface adc_inst (
        .clk(clk),
        .rst_n(rst_n),
        .sample_tick(sample_tick),
        .miso(adc_miso),
        .sample(sample),
        .sample_valid(sample_valid),
        .cs_n(adc_cs_n),
        .sclk(adc_sclk)
    );

    // =========================================================================
    // FIFO (unchanged)
    // Path A: raw samples go here exactly as before
    // =========================================================================
    fifo_buffer #(
        .DATA_WIDTH(12),
        .DEPTH(16)
    ) fifo_inst (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(sample_valid),       // same driver as before
        .wr_data(sample),           // same driver as before
        .full(fifo_full),
        .rd_en(fifo_rd_en),
        .rd_data(fifo_data),
        .empty(fifo_empty)
    );

    // =========================================================================
    // UART Controller (unchanged)
    // =========================================================================
    uart_controller uart_ctrl (
        .clk(clk),
        .rst_n(rst_n),
        .fifo_data(fifo_data),
        .fifo_empty(fifo_empty),
        .fifo_rd_en(fifo_rd_en),
        .tx_busy(tx_busy),
        .tx_start(tx_start),
        .tx_data(tx_data)
    );

    // =========================================================================
    // UART TX (unchanged)
    // =========================================================================
    uart_tx #(
        .CLK_FREQ_HZ(100_000_000),
        .BAUD_RATE(115200)
    ) uart_inst (
        .clk(clk),
        .rst_n(rst_n),
        .tx_start(tx_start),
        .tx_data(tx_data),
        .tx(uart_tx),
        .tx_busy(tx_busy)
    );

    // =========================================================================
    // AXI-Lite Master Stub
    //
    // Handles two jobs:
    //   1. One-time startup: write CTRL=enable, CONFIG=window_8 via AXI
    //   2. Every sample_valid: write sample to DATA_IN via AXI
    //
    // This is the minimal state machine needed to drive the accelerator
    // without a soft CPU. Replace with MicroBlaze for full firmware control.
    // =========================================================================
    axil_master_stub axil_master (
        .clk(clk),
        .rst_n(rst_n),

        // Tap point: same sample & valid that feed the FIFO
        .sample(sample),
        .sample_valid(sample_valid),

        // AXI-Lite master outputs
        .m_axil_awaddr(m_axil_awaddr),
        .m_axil_awvalid(m_axil_awvalid),
        .m_axil_awready(m_axil_awready),
        .m_axil_wdata(m_axil_wdata),
        .m_axil_wstrb(m_axil_wstrb),
        .m_axil_wvalid(m_axil_wvalid),
        .m_axil_wready(m_axil_wready),
        .m_axil_bresp(m_axil_bresp),
        .m_axil_bvalid(m_axil_bvalid),
        .m_axil_bready(m_axil_bready),

        // Read channel (tied off for now — extend to read RESULT if needed)
        .m_axil_araddr(m_axil_araddr),
        .m_axil_arvalid(m_axil_arvalid),
        .m_axil_arready(m_axil_arready),
        .m_axil_rdata(m_axil_rdata),
        .m_axil_rresp(m_axil_rresp),
        .m_axil_rvalid(m_axil_rvalid),
        .m_axil_rready(m_axil_rready)
    );

    // =========================================================================
    // AXI-Lite Moving Average Accelerator
    // Path B: same sample, parallel path, result readable via AXI
    // =========================================================================
    axi_moving_avg #(
        .DATA_WIDTH(12),
        .MAX_WINDOW(16),
        .ADDR_WIDTH(5)
    ) accel_inst (
        .aclk(clk),
        .aresetn(rst_n),

        // Write address channel
        .s_axil_awaddr(m_axil_awaddr),
        .s_axil_awvalid(m_axil_awvalid),
        .s_axil_awready(m_axil_awready),

        // Write data channel
        .s_axil_wdata(m_axil_wdata),
        .s_axil_wstrb(m_axil_wstrb),
        .s_axil_wvalid(m_axil_wvalid),
        .s_axil_wready(m_axil_wready),

        // Write response channel
        .s_axil_bresp(m_axil_bresp),
        .s_axil_bvalid(m_axil_bvalid),
        .s_axil_bready(m_axil_bready),

        // Read address channel
        .s_axil_araddr(m_axil_araddr),
        .s_axil_arvalid(m_axil_arvalid),
        .s_axil_arready(m_axil_arready),

        // Read data channel
        .s_axil_rdata(m_axil_rdata),
        .s_axil_rresp(m_axil_rresp),
        .s_axil_rvalid(m_axil_rvalid),
        .s_axil_rready(m_axil_rready),

        .irq_result_valid(accel_irq)
    );

    // =========================================================================
    // Filtered result output
    // Read RESULT register combinationally from master stub
    // =========================================================================
    assign filtered_result = m_axil_rdata[11:0];
    assign filter_valid    = accel_irq;

endmodule