/*
 * Reaction Time Tester
 *
 * One button (ui_in[0]) to start and react.
 * 3-digit 7-segment multiplexed display:
 *   uo_out[7:0]  = segment data (a-g + dp)
 *   uio_out[2:0] = digit select (active high, one-hot: 100=hundreds, 010=tens, 001=units)
 *
 * States:
 *   IDLE    - press button to start, display shows "---"
 *   WAITING - random delay 1-5 seconds, press early = reset to IDLE
 *   GO      - display shows " Go", timer counting ms
 *   RESULT  - display shows reaction time in ms (0-999)
 */

`default_nettype none

module tt_um_reaction_timer (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    assign uio_oe = 8'hFF;

    parameter CLK_HZ   = 1_000_000;
    parameter MS_DIV  = CLK_HZ / 1000;
    parameter MUX_DIV = CLK_HZ / 1000;

    // States
    localparam IDLE    = 2'd0;
    localparam WAITING = 2'd1;
    localparam GO      = 2'd2;
    localparam RESULT  = 2'd3;

    reg [1:0] state;

    // Button sync + edge detect
  
    reg b0, b1, b2;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin b0<=0; b1<=0; b2<=0; end
        else        begin b0<=ui_in[0]; b1<=b0; b2<=b1; end
    end
    wire btn = b1 & ~b2;

  
    // LFSR
    
    reg [15:0] lfsr;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) lfsr <= 16'hACE1;
        else        lfsr <= {lfsr[0], lfsr[15:1]} ^ (lfsr[0] ? 16'hB400 : 16'h0);
    end

    // 1-5 seconds lookup
    wire [2:0] rand_secs = 3'd1;
        //(lfsr[14:12]==3'd0) ? 3'd3 :
        //(lfsr[14:12]==3'd1) ? 3'd1 :
        //(lfsr[14:12]==3'd2) ? 3'd4 :
        //(lfsr[14:12]==3'd3) ? 3'd2 :
        //(lfsr[14:12]==3'd4) ? 3'd5 :
        //(lfsr[14:12]==3'd5) ? 3'd3 :
        //(lfsr[14:12]==3'd6) ? 3'd1 : 3'd4;

    
    // ms tick: pulses 1 cycle every millisecond
   
    reg [25:0] ms_cnt;
    reg        ms_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin ms_cnt<=0; ms_tick<=0; end
        else begin
            ms_tick <= 0;
            if (ms_cnt >= MS_DIV-1) begin ms_cnt<=0; ms_tick<=1; end
            else ms_cnt <= ms_cnt + 1;
        end
    end

   
    // sec tick: pulses 1 cycle every second
    
    reg [9:0] sec_cnt;
    reg       sec_tick;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin sec_cnt<=0; sec_tick<=0; end
        else begin
            sec_tick <= 0;
            if (ms_tick) begin
                if (sec_cnt >= 999) begin sec_cnt<=0; sec_tick<=1; end
                else sec_cnt <= sec_cnt + 1;
            end
        end
    end

    
    // State machine
    
    reg [2:0] wait_secs;
    reg [9:0] ms_ctr;
    reg [9:0] result_ms;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state     <= IDLE;
            wait_secs <= 0;
            ms_ctr    <= 0;
            result_ms <= 0;
        end else begin
            case (state)
                IDLE: begin
                    if (btn) begin
                        wait_secs <= rand_secs;
                        ms_ctr    <= 0;
                        state     <= WAITING;
                    end
                end
                WAITING: begin
                    if (btn) begin
                        state <= IDLE;           // early press: reset
                    end else if (sec_tick) begin
                        if (wait_secs <= 1) begin
                            ms_ctr <= 0;
                            state  <= GO;
                        end else begin
                            wait_secs <= wait_secs - 1;
                        end
                    end
                end
                GO: begin
                    if (btn) begin
                        result_ms <= ms_ctr;
                        state     <= RESULT;
                    end else if (ms_tick) begin
                        if (ms_ctr < 999) ms_ctr <= ms_ctr + 1;
                    end
                end
                RESULT: begin
                    if (btn) state <= IDLE;
                end
            endcase
        end
    end

    
    // BCD
    
    wire [3:0] d_h = result_ms / 100;
    wire [3:0] d_t = (result_ms % 100) / 10;
    wire [3:0] d_u = result_ms % 10;

    
    // 7-segment (active high) {dp,g,f,e,d,c,b,a}
    
    function [7:0] seg7(input [3:0] d);
        case (d)
            4'd0: seg7 = 8'b00111111;
            4'd1: seg7 = 8'b00000110;
            4'd2: seg7 = 8'b01011011;
            4'd3: seg7 = 8'b01001111;
            4'd4: seg7 = 8'b01100110;
            4'd5: seg7 = 8'b01101101;
            4'd6: seg7 = 8'b01111101;
            4'd7: seg7 = 8'b00000111;
            4'd8: seg7 = 8'b01111111;
            4'd9: seg7 = 8'b01101111;
            default: seg7 = 8'b00000000;
        endcase
    endfunction

    localparam SEG_DASH  = 8'b01000000;
    localparam SEG_G     = 8'b01101111;
    localparam SEG_O     = 8'b00111111;
    localparam SEG_BLANK = 8'b00000000;

    
    // Mux display
    
    reg [1:0]  mux_d;
    reg [25:0] mux_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin mux_cnt<=0; mux_d<=0; end
        else begin
            if (mux_cnt >= MUX_DIV-1) begin
                mux_cnt <= 0;
                mux_d   <= (mux_d==2'd2) ? 2'd0 : mux_d+1;
            end else mux_cnt <= mux_cnt+1;
        end
    end

    reg [7:0] seg;
    always @(*) begin
        case (state)
            IDLE:    seg = SEG_DASH;
            WAITING: seg = SEG_BLANK;
            GO: case (mux_d)
                    2'd0: seg = SEG_BLANK;
                    2'd1: seg = SEG_G;
                    2'd2: seg = SEG_O;
                    default: seg = SEG_BLANK;
                endcase
            RESULT: case (mux_d)
                    2'd0: seg = seg7(d_h);
                    2'd1: seg = seg7(d_t);
                    2'd2: seg = seg7(d_u);
                    default: seg = SEG_BLANK;
                endcase
            default: seg = SEG_BLANK;
        endcase
    end

    reg [2:0] digit_sel;
    always @(*) begin
        case (mux_d)
            2'd0: digit_sel = 3'b100;
            2'd1: digit_sel = 3'b010;
            2'd2: digit_sel = 3'b001;
            default: digit_sel = 3'b000;
        endcase
    end

    wire all_same = (state==IDLE) || (state==WAITING);
    assign uo_out  = seg;
    assign uio_out = {5'b0, all_same ? 3'b111 : digit_sel};

endmodule
