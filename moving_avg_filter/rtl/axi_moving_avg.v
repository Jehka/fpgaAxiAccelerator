// =============================================================================
// axi_moving_avg.v
// AXI-Lite Controlled Moving Average Hardware Accelerator
// Verilog-2005 version (converted from SystemVerilog)
//
// Register Map (byte addresses):
//   0x00  CTRL      [0]=enable  [1]=clear
//   0x04  CONFIG    [3:0]=window_size_minus1  (0->N=1, 15->N=16)
//   0x08  DATA_IN   [11:0]=write new sample (triggers computation)
//   0x0C  RESULT    [11:0]=filtered output (read-only)
//   0x10  STATUS    [0]=result_valid  [1]=busy  [5:2]=fill_count
// =============================================================================

// -----------------------------------------------------------------------------
// DIFF 1: No `logic` type in Verilog.
// Ports driven by always blocks become `reg`.
// Ports that are inputs, or driven only by assign, stay `wire`.
// In SV, `logic` handles both — in Verilog you must choose.
// -----------------------------------------------------------------------------
module axi_moving_avg #(
    parameter DATA_WIDTH = 12,
    parameter MAX_WINDOW = 16,
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

    output wire                   irq_result_valid
);

    // =========================================================================
    // Local Parameters
    // =========================================================================
    localparam ACCUM_WIDTH = DATA_WIDTH + $clog2(MAX_WINDOW);

    localparam ADDR_CTRL    = 5'h00;
    localparam ADDR_CONFIG  = 5'h04;
    localparam ADDR_DATA_IN = 5'h08;
    localparam ADDR_RESULT  = 5'h0C;
    localparam ADDR_STATUS  = 5'h10;

    // =========================================================================
    // AXI-Lite Register Bank
    // -----------------------------------------------------------------------------
    // DIFF 1 (continued): Internal signals driven by always blocks are `reg`.
    // In SV these were all `logic`.
    // -----------------------------------------------------------------------------
    reg [31:0] reg_ctrl;
    reg [31:0] reg_config;
    reg [31:0] reg_result;
    reg [31:0] reg_status;

    reg                   aw_active, w_active;
    reg  [ADDR_WIDTH-1:0] aw_addr_lat;
    reg                   sample_we;
    reg  [DATA_WIDTH-1:0] sample_din;

    // =========================================================================
    // AXI-Lite Write Logic
    // -----------------------------------------------------------------------------
    // DIFF 2: `always_ff` becomes `always`.
    // They behave identically in simulation. The difference is that
    // `always_ff` is a synthesis hint to tools — it makes the compiler
    // warn you if you accidentally infer combinational logic inside it.
    // Plain `always @(posedge clk)` gives you no such safety net.
    // -----------------------------------------------------------------------------
    always @(posedge aclk) begin
        if (!aresetn) begin
            s_axil_awready <= 1'b1;
            s_axil_wready  <= 1'b1;
            s_axil_bvalid  <= 1'b0;
            s_axil_bresp   <= 2'b00;
            aw_active      <= 1'b0;
            w_active       <= 1'b0;
            // DIFF 3: `'0` (SV aggregate zero) becomes explicit width'd zeros.
            // SV `'0` fills any width with zeros automatically.
            // Verilog requires you to be explicit.
            aw_addr_lat    <= {ADDR_WIDTH{1'b0}};
            reg_ctrl       <= 32'h0000_0000;
            reg_config     <= 32'h0000_0007;
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
                    ADDR_CTRL:    reg_ctrl   <= s_axil_wdata;
                    ADDR_CONFIG:  reg_config <= {28'b0, s_axil_wdata[3:0]};
                    ADDR_DATA_IN: begin
                        if (reg_ctrl[0]) begin
                            sample_din <= s_axil_wdata[DATA_WIDTH-1:0];
                            sample_we  <= 1'b1;
                        end
                    end
                    default: ; // RESULT and STATUS are read-only
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
            s_axil_rdata   <= 32'h0000_0000;    // DIFF 3: explicit zero
            s_axil_rresp   <= 2'b00;
        end else begin
            if (s_axil_arvalid && s_axil_arready) begin
                s_axil_arready <= 1'b0;
                s_axil_rvalid  <= 1'b1;
                s_axil_rresp   <= 2'b00;
                case (s_axil_araddr)
                    ADDR_CTRL:    s_axil_rdata <= reg_ctrl;
                    ADDR_CONFIG:  s_axil_rdata <= reg_config;
                    ADDR_DATA_IN: s_axil_rdata <= 32'h0000_0000;
                    ADDR_RESULT:  s_axil_rdata <= reg_result;
                    ADDR_STATUS:  s_axil_rdata <= reg_status;
                    default:      s_axil_rdata <= 32'hDEADBEEF;
                endcase
            end

            if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid  <= 1'b0;
                s_axil_arready <= 1'b1;
            end
        end
    end

    // =========================================================================
    // Compute Engine — Internal Signals
    // =========================================================================
    reg  [DATA_WIDTH-1:0]        sample_buf [0:MAX_WINDOW-1];
    reg  [$clog2(MAX_WINDOW)-1:0] buf_ptr;
    reg  [$clog2(MAX_WINDOW):0]   fill_count;
    reg  [ACCUM_WIDTH-1:0]        accumulator;
    reg                           result_valid_pulse;

    // Combinational signals (driven by always @(*))
    wire [4:0]              win_minus1;
    reg  [4:0]              win_size;
    reg  [3:0]              shift_amount;
    reg  [$clog2(MAX_WINDOW):0] fill_next;
    reg  [ACCUM_WIDTH-1:0]  accum_next;

    assign win_minus1 = reg_config[3:0];

    // =========================================================================
    // Window Size Decode
    // -----------------------------------------------------------------------------
    // DIFF 4: `always_comb` becomes `always @(*)`.
    // `@(*)` means "re-evaluate whenever any input changes" — same behaviour.
    // `always_comb` additionally fires once at time-zero before any signal
    // changes, which can matter for initialisation. In practice with proper
    // resets this difference never matters for synthesizable RTL.
    // -----------------------------------------------------------------------------
    always @(*) begin
        case (win_minus1)
            4'h0:                    win_size = 5'd1;
            4'h1:                    win_size = 5'd2;
            4'h2, 4'h3:              win_size = 5'd4;
            4'h4, 4'h5, 4'h6, 4'h7: win_size = 5'd8;
            default:                 win_size = 5'd16;
        endcase
    end

    // Warmup-aware fill_next
    always @(*) begin
        fill_next = (fill_count < win_size) ? fill_count + 1 : win_size;
    end

    // Warmup-aware shift amount
    always @(*) begin
        case (fill_next)
            5'd1:                        shift_amount = 4'd0;
            5'd2:                        shift_amount = 4'd1;
            5'd3, 5'd4:                  shift_amount = 4'd2;
            5'd5, 5'd6, 5'd7, 5'd8:     shift_amount = 4'd3;
            default:                     shift_amount = 4'd4;
        endcase
    end

    // Next-accumulator combinational logic
    always @(*) begin
        if (sample_we) begin
            if (fill_count == win_size)
                // DIFF 5: SV cast `ACCUM_WIDTH'(x)` becomes zero-extension.
                // SV lets you write `16'(some_12bit_signal)` to widen it.
                // In Verilog you zero-extend explicitly with concatenation:
                // {{(ACCUM_WIDTH-DATA_WIDTH){1'b0}}, sample_buf[buf_ptr]}
                accum_next = accumulator
                           - {{(ACCUM_WIDTH-DATA_WIDTH){1'b0}}, sample_buf[buf_ptr]}
                           + {{(ACCUM_WIDTH-DATA_WIDTH){1'b0}}, sample_din};
            else
                accum_next = accumulator
                           + {{(ACCUM_WIDTH-DATA_WIDTH){1'b0}}, sample_din};
        end else begin
            accum_next = accumulator;
        end
    end

    // =========================================================================
    // Compute Engine — Sequential Logic
    // -----------------------------------------------------------------------------
    // DIFF 6: `for (int i ...)` inside always_ff becomes `integer i` declared
    // outside, used inside `always @(posedge clk)`.
    // SV introduced `int` as a 2-state 32-bit type scoped inside procedural
    // blocks. Verilog only has `integer` (4-state 32-bit), and it must be
    // declared in the module scope, not inside the always block.
    // -----------------------------------------------------------------------------
    integer i;  // loop variable for buffer clear — declared at module scope

    always @(posedge aclk) begin
        if (!aresetn || reg_ctrl[1]) begin
            buf_ptr            <= {$clog2(MAX_WINDOW){1'b0}};
            fill_count         <= {($clog2(MAX_WINDOW)+1){1'b0}};
            accumulator        <= {ACCUM_WIDTH{1'b0}};
            result_valid_pulse <= 1'b0;
            reg_result         <= 32'h0000_0000;
            reg_status         <= 32'h0000_0000;
            // DIFF 6 (continued): loop uses module-scope `integer i`
            for (i = 0; i < MAX_WINDOW; i = i + 1)
                sample_buf[i] <= {DATA_WIDTH{1'b0}};
        end else begin
            result_valid_pulse <= 1'b0;

            if (sample_we) begin
                accumulator <= accum_next;

                sample_buf[buf_ptr] <= sample_din;
                buf_ptr <= (buf_ptr == win_size - 1) ? {$clog2(MAX_WINDOW){1'b0}}
                                                     : buf_ptr + 1;

                if (fill_count < win_size)
                    fill_count <= fill_count + 1;

                // DIFF 5 (continued): `DATA_WIDTH'(accum_next >> shift_amount)`
                // becomes a plain bit-select. Right-shifting gives a value
                // that fits in DATA_WIDTH bits — just take the low bits.
                reg_result         <= {20'b0,
                                       accum_next[shift_amount +: DATA_WIDTH]};
                result_valid_pulse <= 1'b1;
            end

            reg_status <= {26'b0,
                           fill_count[3:0],
                           1'b0,
                           result_valid_pulse};
        end
    end

    // =========================================================================
    // Interrupt Output
    // -----------------------------------------------------------------------------
    // DIFF 1 (continued): output was `output logic` in SV.
    // Now it's `output wire` driven by a continuous assign.
    // -----------------------------------------------------------------------------
    assign irq_result_valid = result_valid_pulse;

endmodule