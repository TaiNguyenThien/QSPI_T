package qspi_test_pkg;
  import uvm_pkg::*;
  import apb_agent_pkg::*;
  import qspi_cfg_pkg::*;
  import qspi_chk_pkg::*;
  import qspi_env_pkg::*;
 // import seq_pkg::*;
  import qspi_regmodel_pkg::*;

  `include "qspi_base_test.sv"
  `include "qspi_bit_bash_test.sv"
  `include "qspi_default_test.sv"
  `include "div_test.sv"
  //opcode_test
 // `include "pio_op_0x02_test.sv"
 // `include "pio_op_0x32_test.sv"
 // `include "pio_op_0x03_test.sv"
 // `include "pio_op_0x0b_test.sv"
  //`include "pio_op_0x3b_test.sv"
  //`include "pio_op_0x6b_test.sv"
  //`include "pio_op_0xeb_test.sv"

  //fifo_test
  `include "tx_fifo_test.sv"
  // cpol cpha
  `include "cpol_cpha_test.sv"
endpackage