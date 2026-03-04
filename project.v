/*
 * Reaction Time Tester - Tiny Tapeout SKY130
 *
 * One button (ui_in[0]) to start and react.
 * 3-digit 7-segment multiplexed display:
 *   uo_out[7:0]  = segment data (a-g + dp)
 *   uio_out[2:0] = digit select (active high, one-hot: digit 0=hundreds, 1=tens, 2=units)
 *
 * States:
 *   IDLE    - press button to start
 *   WAITING - random delay via LFSR, press early = reset to IDLE
 *   GO      - displays "GO" indicator, starts ms counter, press to latch time
 *   RESULT  - shows reaction time in ms (0-999)
 */

module tt_um_reaction_timer (
    input  wire [7:0] ui_in,    // button on ui_in[0]
    output wire [7:0] uo_out,   // 7-segment segments
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,  // digit selects on uio_out[2:0]
    output wire [7:0] uio_oe,   // set bidirectional pins as outputs
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // All uio pins are outputs
    assign uio_oe = 8'hFF;

    // ---------------------------------------------------------------------
    // Parameters
    // ---------------------------------------------------------------------
    // Assumes 50 MHz clock (adjust CLK_HZ for your board)
    parameter CLK_HZ      = 50_000_000;
    parameter MS_TICKS    = CLK_HZ / 1000;       // ticks per millisecond
    parameter MUX_TICKS   = CLK_HZ / 1000;       // multiplex at ~1kHz

    // Random delay range: LFSR wraps, we use 1–8 seconds
    // We just check the top 3 bits of LFSR to pick 1–8 sec
    parameter SEC_TICKS   = CLK_HZ;

    // ---------------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------------
    localparam IDLE    = 2'd0;
    localparam WAITING = 2'd1;
    localparam GO      = 2'd2;
    localparam RESULT  = 2'd3;

    reg [1:0] state;

    // ---------------------------------------------------------------------
    // Button edge detection (synchronise & debounce)
    // ---------------------------------------------------------------------
    reg btn_r0, btn_r1, btn_r2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            btn_r0 <= 0; btn_r1 <= 0; btn_r2 <= 0;
        end else begin
            btn_r0 <= ui_in[0];
            btn_r1 <= btn_r0;
            btn_r2 <= btn_r1;
        end
    end
    wire btn_press = (btn_r1 & ~btn_r2); // rising edge

    // ---------------------------------------------------------------------
    // 16-bit Galois LFSR for pseudo-random delay
    // ---------------------------------------------------------------------
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            lfsr <= 16'hACE1;
        else
            lfsr <= {lfsr[0], lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0000);
    end

    // Pick a delay of 1–8 seconds from top 3 bits (1..8)
    wire [2:0] rand_secs = (lfsr[14:12] % 5) + 1;

    // ---------------------------------------------------------------------
    // Counters
    // ---------------------------------------------------------------------
    reg [25:0] wait_ctr;   // counts down the random wait
    reg [25:0] ms_ctr;     // counts up in ms
    reg [9:0]  reaction_ms; // latched result (0–999)

    // Millisecond tick
    reg [15:0] ms_tick_ctr;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms_tick_ctr <= 0;
            ms_tick <= 0;
        end else begin
            ms_tick <= 0;
            if (ms_tick_ctr >= MS_TICKS - 1) begin
                ms_tick_ctr <= 0;
                ms_tick <= 1;
            end else begin
                ms_tick_ctr <= ms_tick_ctr + 1;
            end
        end
    end

    // ---------------------------------------------------------------------
    // State machine
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= IDLE;
            wait_ctr    <= 0;
            ms_ctr      <= 0;
            reaction_ms <= 0;
        end else begin
            case (state)

                IDLE: begin
                    if (btn_press) begin
                        // Load random wait: rand_secs * SEC_TICKS
                        wait_ctr <= rand_secs * SEC_TICKS;
                        ms_ctr   <= 0;
                        state    <= WAITING;
                    end
                end

                WAITING: begin
                    if (btn_press) begin
                        // Too early! Reset back to IDLE
                        state <= IDLE;
                    end else if (ms_tick) begin
                        if (wait_ctr <= 1) begin
                            ms_ctr <= 0;
                            state  <= GO;
                        end else begin
                            wait_ctr <= wait_ctr - 1;
                        end
                    end
                end

                GO: begin
                    if (btn_press) begin
                        reaction_ms <= (ms_ctr > 999) ? 10'd999 : ms_ctr[9:0];
                        state <= RESULT;
                    end else if (ms_tick) begin
                        ms_ctr <= ms_ctr + 1;
                    end
                end

                RESULT: begin
                    if (btn_press) begin
                        state <= IDLE;
                    end
                end

            endcase
        end
    end

    // ---------------------------------------------------------------------
    // BCD breakdown of reaction_ms (0–999)
    // ---------------------------------------------------------------------
    wire [3:0] hundreds = reaction_ms / 100;
    wire [3:0] tens     = (reaction_ms % 100) / 10;
    wire [3:0] units    = reaction_ms % 10;

    // ---------------------------------------------------------------------
    // 7-segment encoding (common cathode, active high)
    // Segments: {dp, g, f, e, d, c, b, a}
    // ---------------------------------------------------------------------
    function [7:0] seg7;
        input [3:0] digit;
        case (digit)
            4'd0: seg7 = 8'b00111111; // 0
            4'd1: seg7 = 8'b00000110; // 1
            4'd2: seg7 = 8'b01011011; // 2
            4'd3: seg7 = 8'b01001111; // 3
            4'd4: seg7 = 8'b01100110; // 4
            4'd5: seg7 = 8'b01101101; // 5
            4'd6: seg7 = 8'b01111101; // 6
            4'd7: seg7 = 8'b00000111; // 7
            4'd8: seg7 = 8'b01111111; // 8
            4'd9: seg7 = 8'b01101111; // 9
            4'd10: seg7 = 8'b01110111; // A  (used for "go" indicator)
            4'd11: seg7 = 8'b01111100; // b
            4'd12: seg7 = 8'b00111001; // C
            4'd13: seg7 = 8'b01011110; // d
            4'd14: seg7 = 8'b01111001; // E  (error/early)
            4'd15: seg7 = 8'b01110001; // F
            default: seg7 = 8'b00000000;
        endcase
    endfunction

    // Special patterns
    localparam SEG_DASH  = 8'b01000000; // "-"
    localparam SEG_G     = 8'b01101111; // "G" (same as 9 + bottom)
    localparam SEG_O     = 8'b00111111; // "O" (same as 0)
    localparam SEG_BLANK = 8'b00000000;

    // ---------------------------------------------------------------------
    // Multiplexed display
    // ---------------------------------------------------------------------
    reg [1:0]  mux_digit;   // which digit is active: 0=hundreds, 1=tens, 2=units
    reg [15:0] mux_ctr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mux_ctr   <= 0;
            mux_digit <= 0;
        end else begin
            if (mux_ctr >= MUX_TICKS - 1) begin
                mux_ctr   <= 0;
                mux_digit <= (mux_digit == 2'd2) ? 2'd0 : mux_digit + 1;
            end else begin
                mux_ctr <= mux_ctr + 1;
            end
        end
    end

    // Which segment data to show per digit per state
    reg [7:0] seg_data;
    always @(*) begin
        case (state)
            IDLE: begin
                // Show "---" to indicate ready
                seg_data = SEG_DASH;
            end
            WAITING: begin
                // Show "..." (all segments off) while waiting
                seg_data = SEG_BLANK;
            end
            GO: begin
                // Show " Go" across the three digits
                case (mux_digit)
                    2'd0: seg_data = SEG_BLANK;
                    2'd1: seg_data = SEG_G;
                    2'd2: seg_data = SEG_O;
                    default: seg_data = SEG_BLANK;
                endcase
            end
            RESULT: begin
                // Show reaction time in ms
                case (mux_digit)
                    2'd0: seg_data = seg7(hundreds);
                    2'd1: seg_data = seg7(tens);
                    2'd2: seg_data = seg7(units);
                    default: seg_data = SEG_BLANK;
                endcase
            end
            default: seg_data = SEG_BLANK;
        endcase
    end

    // Digit select: one-hot, active high
    reg [2:0] digit_sel;
    always @(*) begin
        case (mux_digit)
            2'd0: digit_sel = 3'b100; // hundreds
            2'd1: digit_sel = 3'b010; // tens
            2'd2: digit_sel = 3'b001; // units
            default: digit_sel = 3'b000;
        endcase
    end

    // For IDLE and WAITING states, all digits show same pattern
    // so override digit_sel to show all (only relevant for IDLE dashes)
    wire all_same = (state == IDLE) || (state == WAITING);

    assign uo_out  = seg_data;
    assign uio_out = {5'b00000, all_same ? 3'b111 : digit_sel};

endmodule
