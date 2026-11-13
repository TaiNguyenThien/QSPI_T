
`timescale 1ns/1ps

interface axi_if ();

    // Write Address
    logic [31:0] m_awaddr;
    logic [7:0]  m_awlen;
    logic [2:0]  m_awsize;
    logic [1:0]  m_awburst;
    logic        m_awvalid;
    logic        m_awready;

    // Write Data
    logic [31:0] m_wdata;
    logic [3:0]  m_wstrb;
    logic        m_wlast;
    logic        m_wvalid;
    logic        m_wready;

    // Write Response
    logic [1:0] m_bresp;
    logic       m_bvalid;
    logic       m_bready;

    // Read Address
    logic [31:0] m_araddr;
    logic [7:0]  m_arlen;
    logic [2:0]  m_arsize;
    logic [1:0]  m_arburst;
    logic        m_arvalid;
    logic        m_arready;

    // Read Data
    logic [31:0] m_rdata;
    logic [1:0]  m_rresp;
    logic        m_rlast;
    logic        m_rvalid;
    logic        m_rready;

endinterface
