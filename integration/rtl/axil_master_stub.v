`timescale 1ns/1ps
// =============================================================================
// axil_master_stub.v
// Minimal AXI-Lite Master for axi_moving_avg accelerator
//
// Does exactly two things:
//   1. At startup: writes CTRL=0x1 (enable) and CONFIG=0x7 (window=8)
//   2. On every sample_valid pulse: writes sample to DATA_IN (0x08)
//
// State machine:
//
//   INIT_CTRL  → write 0x01 to CTRL   (enable)
//   INIT_CFG   → write 0x07 to CONFIG (window=8)
//   IDLE       → wait for sample_valid
//   SEND       → write sample to DATA_IN
//   WAIT_RESP  → wait for AXI write response, back to IDLE
//
// To extend: add READ states after IDLE to poll RESULT register,
// or drive this from a MicroBlaze for full firmware control.
// =============================================================================

module axil_master_stub (
    input  wire        clk,
    input  wire        rst_n,

    // Sample tap from ADC
    input  wire [11:0] sample,
    input  wire        sample_valid,

    // AXI-Lite Master — Write Address Channel
    output reg  [4:0]  m_axil_awaddr,
    output reg         m_axil_awvalid,
    input  wire        m_axil_awready,

    // AXI-Lite Master — Write Data Channel
    output reg  [31:0] m_axil_wdata,
    output reg  [3:0]  m_axil_wstrb,
    output reg         m_axil_wvalid,
    input  wire        m_axil_wready,

    // AXI-Lite Master — Write Response Channel
    input  wire [1:0]  m_axil_bresp,
    input  wire        m_axil_bvalid,
    output reg         m_axil_bready,

    // AXI-Lite Master — Read Address Channel (tied off, extend later)
    output reg  [4:0]  m_axil_araddr,
    output reg         m_axil_arvalid,
    input  wire        m_axil_arready,

    // AXI-Lite Master — Read Data Channel
    input  wire [31:0] m_axil_rdata,
    input  wire [1:0]  m_axil_rresp,
    input  wire        m_axil_rvalid,
    output reg         m_axil_rready
);

    // =========================================================================
    // Register addresses (must match axi_moving_avg register map)
    // =========================================================================
    localparam ADDR_CTRL    = 5'h00;
    localparam ADDR_CONFIG  = 5'h04;
    localparam ADDR_DATA_IN = 5'h08;

    // =========================================================================
    // State encoding
    // =========================================================================
    localparam ST_INIT_CTRL  = 3'd0;  // write CTRL = enable
    localparam ST_INIT_CFG   = 3'd1;  // write CONFIG = window_8
    localparam ST_IDLE       = 3'd2;  // wait for sample
    localparam ST_SEND       = 3'd3;  // write sample to DATA_IN
    localparam ST_WAIT_RESP  = 3'd4;  // wait for AXI write response

    reg [2:0] state;

    // Latch sample on valid to hold it stable through the AXI transaction
    reg [11:0] sample_lat;

    // =========================================================================
    // State Machine
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state          <= ST_INIT_CTRL;
            sample_lat     <= 12'b0;
            m_axil_awaddr  <= 5'b0;
            m_axil_awvalid <= 1'b0;
            m_axil_wdata   <= 32'b0;
            m_axil_wstrb   <= 4'hF;
            m_axil_wvalid  <= 1'b0;
            m_axil_bready  <= 1'b0;
            m_axil_araddr  <= 5'b0;
            m_axil_arvalid <= 1'b0;
            m_axil_rready  <= 1'b0;
        end else begin
            case (state)

                // -----------------------------------------------------------------
                // ST_INIT_CTRL: write 0x1 to CTRL register (enable accelerator)
                // -----------------------------------------------------------------
                ST_INIT_CTRL: begin
                    m_axil_awaddr  <= ADDR_CTRL;
                    m_axil_awvalid <= 1'b1;
                    m_axil_wdata   <= 32'h0000_0001;  // CTRL[0] = enable
                    m_axil_wstrb   <= 4'hF;
                    m_axil_wvalid  <= 1'b1;
                    m_axil_bready  <= 1'b1;

                    // Both address and data accepted — move on
                    if (m_axil_awready && m_axil_wready) begin
                        m_axil_awvalid <= 1'b0;
                        m_axil_wvalid  <= 1'b0;
                        state          <= ST_INIT_CFG;
                    end
                end

                // -----------------------------------------------------------------
                // ST_INIT_CFG: write 0x7 to CONFIG (window_minus1=7 → N=8)
                // -----------------------------------------------------------------
                ST_INIT_CFG: begin
                    // Wait for write response from CTRL write first
                    if (m_axil_bvalid) begin
                        m_axil_bready  <= 1'b0;
                        m_axil_awaddr  <= ADDR_CONFIG;
                        m_axil_awvalid <= 1'b1;
                        m_axil_wdata   <= 32'h0000_0007;  // window = 8
                        m_axil_wstrb   <= 4'hF;
                        m_axil_wvalid  <= 1'b1;
                        m_axil_bready  <= 1'b1;
                    end

                    if (m_axil_awready && m_axil_wready && m_axil_awvalid) begin
                        m_axil_awvalid <= 1'b0;
                        m_axil_wvalid  <= 1'b0;
                        state          <= ST_IDLE;
                    end
                end

                // -----------------------------------------------------------------
                // ST_IDLE: accelerator configured, wait for next ADC sample
                // -----------------------------------------------------------------
                ST_IDLE: begin
                    m_axil_bready <= 1'b0;

                    if (sample_valid) begin
                        sample_lat <= sample;   // latch sample, hold through write
                        state      <= ST_SEND;
                    end
                end

                // -----------------------------------------------------------------
                // ST_SEND: issue AXI write of sample to DATA_IN
                // Drive both address and data channels simultaneously (legal in
                // AXI-Lite — manager may present AW and W in same cycle)
                // -----------------------------------------------------------------
                ST_SEND: begin
                    m_axil_awaddr  <= ADDR_DATA_IN;
                    m_axil_awvalid <= 1'b1;
                    m_axil_wdata   <= {20'b0, sample_lat};
                    m_axil_wstrb   <= 4'hF;
                    m_axil_wvalid  <= 1'b1;
                    m_axil_bready  <= 1'b1;

                    if (m_axil_awready && m_axil_wready) begin
                        m_axil_awvalid <= 1'b0;
                        m_axil_wvalid  <= 1'b0;
                        state          <= ST_WAIT_RESP;
                    end
                end

                // -----------------------------------------------------------------
                // ST_WAIT_RESP: wait for write response, then back to IDLE
                // -----------------------------------------------------------------
                ST_WAIT_RESP: begin
                    if (m_axil_bvalid) begin
                        m_axil_bready <= 1'b0;
                        state         <= ST_IDLE;
                    end
                end

                default: state <= ST_IDLE;

            endcase
        end
    end

    // Read channel tied off — not used in this stub
    // m_axil_arvalid is held 0 via the reset initialisation above
    // Extend here to periodically read RESULT register if needed

endmodule