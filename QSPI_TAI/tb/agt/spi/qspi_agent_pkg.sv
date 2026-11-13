package qspi_agent_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;

  `include "uvm_macros.svh"
  `include "tb/agt/spi/qspi_cfg.sv"
  `include "tb/agt/spi/qspi_transaction.sv"
  `include "tb/agt/spi/qspi_flash_slave.sv"
  `include "tb/agt/spi/qspi_monitor.sv"
  `include "tb/agt/spi/qspi_agent.sv"
endpackage
