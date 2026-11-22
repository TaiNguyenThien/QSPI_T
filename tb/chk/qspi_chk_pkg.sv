package qspi_chk_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import apb_agent_pkg::*;
  import qspi_types_pkg::*;
  import qspi_cfg_pkg::*;
  import qspi_ral_pkg::*;
  import qspi_agent_pkg::*;
  import axi_slave_agent_pkg::*;
  import axil_master_agent_pkg::*;

  `include "uvm_macros.svh"
  `uvm_analysis_imp_decl(_driver_result)
  `uvm_analysis_imp_decl(_sclk_spi)
  `uvm_analysis_imp_decl(_status_spi)
  `include "tb/chk/qspi_apb_contract_chk.sv"
  `include "tb/chk/qspi_apb_csr_sb.sv"
  `include "tb/chk/qspi_flow_sb.sv"
  `include "tb/chk/qspi_sclk_timing_chk.sv"
  `include "tb/chk/qspi_status_chk.sv"
  `include "tb/chk/qspi_dma_sb.sv"
  `include "tb/chk/qspi_xip_sb.sv"
endpackage : qspi_chk_pkg
