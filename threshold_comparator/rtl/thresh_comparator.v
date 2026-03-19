`timescale 1ns/1ps
// =============================================================================
// thresh_comparator.v
// AXI-Lite Controlled Threshold Comparator with Latched IRQ
//
// Register Map (byte addresses):
//   0x00  CTRL       [1:0]=direction  [2]=irq_clear  [3]=enable
//   0x04  THRESH_HI  [11:0]=upper threshold
//   0x08  THRESH_LO  [11:0]=lower threshold
//   0x0C  DATA_IN    [11:0]=write sample (triggers comparison, write-only)
//   0x10  STATUS     [0]=irq_pending  [1]=last_crossing  [13:2]=last_sample
//
// Direction (CTRL[1:0]):
//   2'b00 = ABOVE  IRQ fires when sample > THRESH_HI
//   2'b01 = BELOW  IRQ fires when sample < THRESH_LO
//   2'b10 = BOTH   IRQ fires on either crossing
// =============================================================================

module thresh_comparator #(
    parameter DATA_WIDTH = 12,
    parameter ADDR_WIDTH = 5
)(
    input  wire                   aclk,
    input  wire                   aresetn,

    // Write address channel
    input  wire  [ADDR_WIDTH-1:0] s_axil_awaddr,
    input  wire                   s_axil_awvalid,
    output reg                    s_axil_awready,

    // Write data channel
    input  wire  [31:0]           s_axil_wdata,
    input  wire  [3:0]            s_axil_wstrb,
    input  wire                   s_axil_wvalid,
    output reg                    s_axil_wready,

    // Write response channel
    output reg   [1:0]            s_axil_bresp,
    output reg                    s_axil_bvalid,
    input  wire                   s_axil_bready,

    // Read address channel
    input  wire  [ADDR_WIDTH-1:0] s_axil_araddr,
    input  wire                   s_axil_arvalid,
    output reg                    s_axil_arready,

    // Read data channel
    output reg   [31:0]           s_axil_rdata,
    output reg   [1:0]            s_axil_rresp,
    output reg                    s_axil_rvalid,
    input  wire                   s_axil_rready,

    output wire                   irq_out
);

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam ADDR_CTRL      = 5'h00;
    localparam ADDR_THRESH_HI = 5'h04;
    localparam ADDR_THRESH_LO = 5'h08;
    localparam ADDR_DATA_IN   = 5'h0C;
    localparam ADDR_STATUS    = 5'h10;

    localparam DIR_ABOVE = 2'b00;
    localparam DIR_BELOW = 2'b01;
    localparam DIR_BOTH  = 2'b10;

    localparam ST_ARMED      = 2'd0;
    localparam ST_TRIPPED_HI = 2'd1;
    localparam ST_TRIPPED_LO = 2'd2;

    // =========================================================================
    // Register Bank
    // =========================================================================
    reg [31:0] reg_ctrl;
    reg [31:0] reg_thresh_hi;
    reg [31:0] reg_thresh_lo;
    reg [31:0] reg_status;

    // =========================================================================
    // AXI-Lite Write Logic
    // =========================================================================
    reg                   aw_active, w_active;
    reg  [ADDR_WIDTH-1:0] aw_addr_lat;
    reg                   sample_we;
    reg  [DATA_WIDTH-1:0] sample_din;

    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axil_awready <= 1'b1;
            s_axil_wready  <= 1'b1;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00;
            aw_active      <= 1'b0;
            w_active       <= 1'b0;
            aw_addr_lat    <= {ADDR_WIDTH{1'b0}};
            reg_ctrl       <= 32'h0000_0008;
            reg_thresh_hi  <= 32'h0000_0E00;
            reg_thresh_lo  <= 32'h0000_0200;
            sample_we      <= 1'b0;
            sample_din     <= {DATA_WIDTH{1'b0}};
        end else begin
            sample_we <= 1'b0;

            if (s_axil_awvalid && s_axil_awready) begin
                aw_addr_lat    <= s_axil_awaddr;
                aw_active      <= 1'b1;
                s_axil_awready <= 1'b0;
            end

            if (s_axil_wvalid && s_axil_wready) begin
                w_active      <= 1'b1;
                s_axil_wready <= 1'b0;
            end

            if (aw_active && w_active) begin
                case (aw_addr_lat)
                    ADDR_CTRL:      reg_ctrl      <= s_axil_wdata;
                    ADDR_THRESH_HI: reg_thresh_hi <= {20'b0, s_axil_wdata[DATA_WIDTH-1:0]};
                    ADDR_THRESH_LO: reg_thresh_lo <= {20'b0, s_axil_wdata[DATA_WIDTH-1:0]};
                    ADDR_DATA_IN: begin
                        if (reg_ctrl[3]) begin
                            sample_din <= s_axil_wdata[DATA_WIDTH-1:0];
                            sample_we  <= 1'b1;
                        end
                    end
                    default: ;
                endcase

                aw_active      <= 1'b0;
                w_active       <= 1'b0;
                s_axil_awready <= 1'b1;
                s_axil_wready  <= 1'b1;
                s_axil_bvalid  <= 1'b1;
                s_axil_bresp   <= 2'b00;
            end

            if (s_axil_bvalid && s_axil_bready)
                s_axil_bvalid <= 1'b0;
        end
    end

    // =========================================================================
    // AXI-Lite Read Logic
    // =========================================================================
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axil_arready <= 1'b1;
            s_axil_rvalid  <= 1'b0;
            s_axil_rdata   <= 32'h0000_0000;
            s_axil_rresp   <= 2'b00;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_arready <= 1'b0;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;
                case (s_axil_araddr)
                    ADDR_CTRL:      s_axil_rdata <= reg_ctrl;
                    ADDR_THRESH_HI: s_axil_rdata <= reg_thresh_hi;
                    ADDR_THRESH_LO: s_axil_rdata <= reg_thresh_lo;
                    ADDR_DATA_IN:   s_axil_rdata <= 32'h0000_0000;
                    ADDR_STATUS:    s_axil_rdata <= reg_status;
                    default:        s_axil_rdata <= 32'hDEADBEEF;
                endcase
            end

            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid  <= 1'b0;
                s_axil_arready <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Comparator Engine
    // =========================================================================
    reg [1:0]            cmp_state;
    reg                  irq_pending;
    reg                  last_crossing;
    reg [DATA_WIDTH-1:0] last_sample;
    reg [1:0]            direction_prev; // detects direction changes

    wire [1:0]            direction;
    wire                  irq_clear;
    wire [DATA_WIDTH-1:0] thresh_hi;
    wire [DATA_WIDTH-1:0] thresh_lo;

    assign direction = reg_ctrl[1:0];
    assign irq_clear = reg_ctrl[2];
    assign thresh_hi = reg_thresh_hi[DATA_WIDTH-1:0];
    assign thresh_lo = reg_thresh_lo[DATA_WIDTH-1:0];

    always @(posedge aclk) begin
        if (!aresetn) begin
            cmp_state      <= ST_ARMED;
            irq_pending    <= 1'b0;
            last_crossing  <= 1'b0;
            last_sample    <= {DATA_WIDTH{1'b0}};
            direction_prev <= 2'b00;
        end else begin

            // Track direction each cycle
            direction_prev <= direction;

            // If firmware changed direction, re-arm state machine immediately.
            // irq_pending is NOT auto-cleared — firmware must still acknowledge.
            if (direction != direction_prev)
                cmp_state <= ST_ARMED;

            if (irq_clear)
                irq_pending <= 1'b0;

            if (sample_we) begin
                last_sample <= sample_din;

                case (cmp_state)
                    ST_ARMED: begin
                        case (direction)
                            DIR_ABOVE: begin
                                if (sample_din > thresh_hi) begin
                                    irq_pending   <= 1'b1;
                                    last_crossing <= 1'b0;
                                    cmp_state     <= ST_TRIPPED_HI;
                                end
                            end
                            DIR_BELOW: begin
                                if (sample_din < thresh_lo) begin
                                    irq_pending   <= 1'b1;
                                    last_crossing <= 1'b1;
                                    cmp_state     <= ST_TRIPPED_LO;
                                end
                            end
                            DIR_BOTH: begin
                                if (sample_din > thresh_hi) begin
                                    irq_pending   <= 1'b1;
                                    last_crossing <= 1'b0;
                                    cmp_state     <= ST_TRIPPED_HI;
                                end else if (sample_din < thresh_lo) begin
                                    irq_pending   <= 1'b1;
                                    last_crossing <= 1'b1;
                                    cmp_state     <= ST_TRIPPED_LO;
                                end
                            end
                            default: ;
                        endcase
                    end

                    ST_TRIPPED_HI: begin
                        if (sample_din < thresh_lo)
                            cmp_state <= ST_ARMED;
                    end

                    ST_TRIPPED_LO: begin
                        if (sample_din > thresh_hi)
                            cmp_state <= ST_ARMED;
                    end

                    default: cmp_state <= ST_ARMED;
                endcase
            end
        end
    end

    // =========================================================================
    // STATUS Register
    // =========================================================================
    always @(posedge aclk) begin
        if (!aresetn)
            reg_status <= 32'h0000_0000;
        else
            reg_status <= {18'b0, last_sample, last_crossing, irq_pending};
    end

    // =========================================================================
    // IRQ Output
    // =========================================================================
    assign irq_out = irq_pending;

endmodule