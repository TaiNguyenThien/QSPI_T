package qspi_cfg_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import apb_agent_pkg::*;
  import qspi_types_pkg::*;
  import qspi_agent_pkg::*;
  import axi_slave_agent_pkg::*;
  import axil_master_agent_pkg::*;

  `include "uvm_macros.svh"
  `include "tb/cfg/qspi_shared_items.sv"
  `include "tb/cfg/qspi_env_cfg.sv"
endpackage : qspi_cfg_pkg
