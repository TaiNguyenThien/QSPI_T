package apb_agent_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "apb_trans.sv"
  `include "apb_cfg.sv"
  `include "apb_sequencer.sv"
  `include "apb_driver.sv"
  `include "apb_monitor.sv"
  `include "apb_agent.sv"
  `include "apb_seq_lib.sv"
endpackage
