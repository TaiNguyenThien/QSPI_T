`timescale 1ns/1ps

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_if.sv
// Role   : Physical & Clocking Interface for AXI4-Lite Master/Slave
// Spec   : ARM AMBA AXI4-Lite Protocol Specification (ARM IHI 0022H.c)
// =============================================================================

interface axil_if(input logic aclk, input logic aresetn);

  // --- Read Address Channel (AR) ---
  logic [31:0] araddr;
  logic [2:0]  arprot;
  logic        arvalid;
  logic        arready;

  // --- Read Data Channel (R) ---
  logic [31:0] rdata;
  logic [1:0]  rresp;
  logic        rvalid;
  logic        rready;

  // ---------------------------------------------------------------------------
  // Master Clocking Block: #1step input skew, #0 / NBA output skew
  // ---------------------------------------------------------------------------
  clocking master_cb @(posedge aclk);
    default input #1step output #0;
    input  aresetn;
    input  arready;
    input  rvalid;
    input  rdata;
    input  rresp;
    output araddr;
    output arprot;
    output arvalid;
    output rready;
  endclocking : master_cb

  // ---------------------------------------------------------------------------
  // Monitor Clocking Block: Sample-only on inputs with #1step skew
  // ---------------------------------------------------------------------------
  clocking monitor_cb @(posedge aclk);
    default input #1step;
    input aresetn;
    input araddr;
    input arprot;
    input arvalid;
    input arready;
    input rdata;
    input rresp;
    input rvalid;
    input rready;
  endclocking : monitor_cb

  // --- Modports ---
  modport dut (
    input  aclk, aresetn, araddr, arprot, arvalid, rready,
    output arready, rdata, rresp, rvalid
  );

  modport master (
    clocking master_cb,
    input    aclk, aresetn
  );

  modport monitor (
    clocking monitor_cb,
    input    aclk, aresetn
  );

  // Direct asynchronous access modport for reset watchers
  modport direct_master (
    input  aclk, aresetn, arready, rdata, rresp, rvalid,
    output araddr, arprot, arvalid, rready
  );

  // Persistent asynchronous reset forcing (satisfies ARM AXI §A3.1.2 & IEEE 1800 §10.6.2)
  // 'force' provides absolute priority over any scheduled Re-NBA clocking updates
  function void direct_reset_force();
    force araddr  = '0;
    force arprot  = '0;
    force arvalid = 1'b0;
    force rready  = 1'b0;
  endfunction

  function void direct_reset_release();
    release araddr;
    release arprot;
    release arvalid;
    release rready;
  endfunction

endinterface : axil_if
