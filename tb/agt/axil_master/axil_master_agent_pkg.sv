// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_master_agent_pkg.sv
// Role   : Package defining the AXI4-Lite Master Agent
// =============================================================================

`timescale 1ns/1ps

package axil_master_agent_pkg;
  timeunit 1ns;
  timeprecision 1ps;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "axil_master_transaction.sv"
  `include "axil_master_cfg.sv"
  `include "axil_master_sequencer.sv"
  `include "axil_master_driver.sv"
  `include "axil_master_monitor.sv"
  `include "axil_master_agent.sv"

endpackage : axil_master_agent_pkg
