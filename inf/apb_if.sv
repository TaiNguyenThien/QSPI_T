`timescale 1ns/1ps

interface apb_if #(
    parameter int unsigned ADDR_WIDTH = 12,
    parameter int unsigned DATA_WIDTH = 32
) (
    input logic clk,
    input logic rst_n
);

    localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;

    // APB request/control
    logic [ADDR_WIDTH-1:0] paddr;
    logic                  psel;
    logic                  penable;
    logic                  pwrite;
    logic [DATA_WIDTH-1:0] pwdata;
    logic [STRB_WIDTH-1:0] pstrb;
    logic [2:0]            pprot;

    // APB response
    logic [DATA_WIDTH-1:0] prdata;
    logic                  pready;
    logic                  pslverr;

endinterface : apb_if
