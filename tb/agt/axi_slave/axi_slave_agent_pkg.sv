`timescale 1ns/1ps

package axi_slave_agent_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  `include "uvm_macros.svh"
  `include "axi_slave_transaction.sv"
  `include "axi_slave_cfg.sv"
  `include "axi_slave_driver.sv"
  `include "axi_slave_monitor.sv"
  `include "axi_slave_agent.sv"
endpackage : axi_slave_agent_pkg
