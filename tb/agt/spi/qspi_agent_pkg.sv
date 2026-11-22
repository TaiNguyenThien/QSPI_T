package qspi_agent_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;

  `include "uvm_macros.svh"
  `include "qspi_cfg.sv"
  `include "qspi_transaction.sv"
  `include "qspi_flash_slave.sv"
  `include "qspi_monitor.sv"
  `include "qspi_agent.sv"
endpackage
