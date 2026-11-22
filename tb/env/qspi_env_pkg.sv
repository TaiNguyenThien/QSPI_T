package qspi_env_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import apb_agent_pkg::*;
  import qspi_types_pkg::*;
  import qspi_agent_pkg::*;
  import axi_slave_agent_pkg::*;
  import axil_master_agent_pkg::*;
  import qspi_cfg_pkg::*;
  import qspi_cov_pkg::*;
  import qspi_chk_pkg::*;
  import qspi_ral_pkg::*;
  import qspi_vseq_pkg::*;

  `include "uvm_macros.svh"
  `include "tb/env/qspi_flash_profile_sync.sv"
  `include "tb/env/qspi_tb_mem_service.sv"
  `include "tb/env/qspi_env.sv"
endpackage : qspi_env_pkg
