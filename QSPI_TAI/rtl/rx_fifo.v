`timescale 1ns/1ps
`default_nettype none

module rx_fifo #(
    parameter integer WIDTH = 32,
    parameter integer DEPTH = 4
) (
    // ----------- Clock and Reset -----------
    input  wire                   i_clk,
    input  wire                   i_rst_n,

    // ----------- Write Interface (QSPI Controller side) -----------
    input  wire                   i_rx_wen,
    input  wire [WIDTH-1:0]       i_rx_data,
    output wire                   o_rx_full,

    // ----------- Read Interface (CSR/DMA/XIP side) -----------
    input  wire                   i_rx_ren,
    output reg  [WIDTH-1:0]       o_rx_data,
    output wire                   o_rx_empty,

    // ----------- FIFO Status -----------
    output wire [3:0]             o_rx_level
);

    // =================================================================
    // INTERNAL REGISTERS AND MEMORY
    // =================================================================
    reg [WIDTH-1:0]               r_mem [0:DEPTH-1];
    reg [$clog2(DEPTH)-1:0]       r_wptr, r_rptr;
    reg [$clog2(DEPTH):0]         r_cnt;

    // =================================================================
    // CONTINUOUS ASSIGNMENTS
    // =================================================================
    assign o_rx_full  = (r_cnt == DEPTH);
    assign o_rx_empty = (r_cnt == 0);
    assign o_rx_level = r_cnt;

    // =================================================================
    // SEQUENTIAL LOGIC
    // =================================================================
    integer i;
    always @(posedge i_clk or negedge i_rst_n) begin
        if (!i_rst_n) begin
            for (i = 0; i < DEPTH; i = i + 1) r_mem[i] <= {WIDTH{1'b0}};
            r_wptr    <= {$clog2(DEPTH){1'b0}};
            r_rptr    <= {$clog2(DEPTH){1'b0}};
            r_cnt     <= {($clog2(DEPTH)+1){1'b0}};
            o_rx_data <= {WIDTH{1'b0}};
        end else begin
            if (i_rx_ren && i_rx_wen && !o_rx_empty && !o_rx_full) begin
                r_mem[r_wptr] <= i_rx_data;
                r_wptr        <= r_wptr + 1'b1;
                o_rx_data     <= r_mem[r_rptr];
                r_rptr        <= r_rptr + 1'b1;
            end else begin
                // Write logic
                if (i_rx_wen && !o_rx_full) begin
                    r_mem[r_wptr] <= i_rx_data;
                    r_wptr        <= r_wptr + 1'b1;
                    r_cnt         <= r_cnt + 1'b1;
                end

                // Read logic
                if (i_rx_ren && !o_rx_empty) begin
                    o_rx_data     <= r_mem[r_rptr];
                    r_rptr        <= r_rptr + 1'b1;
                    r_cnt         <= r_cnt - 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire