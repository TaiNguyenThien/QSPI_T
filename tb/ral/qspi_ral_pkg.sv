package qspi_ral_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import uvm_pkg::*;
  import apb_agent_pkg::*;
  import qspi_types_pkg::*;
  `include "uvm_macros.svh"
  typedef bit [QSPI_APB_ADDR_WIDTH-1:0] qspi_reg_offset_t;
  localparam qspi_reg_offset_t
  QSPI_REG_ID        = 'h000,
  QSPI_REG_CTRL      = 'h004,
  QSPI_REG_STATUS    = 'h008,
  QSPI_REG_INT_EN    = 'h00c,
  QSPI_REG_INT_STAT  = 'h010,
  QSPI_REG_CLK_DIV   = 'h014,
  QSPI_REG_CS_CTRL   = 'h018,
  QSPI_REG_XIP_CFG   = 'h01c,
  QSPI_REG_XIP_CMD   = 'h020,
  QSPI_REG_CMD_CFG   = 'h024,
  QSPI_REG_CMD_OP    = 'h028,
  QSPI_REG_CMD_ADDR  = 'h02c,
  QSPI_REG_CMD_LEN   = 'h030,
  QSPI_REG_CMD_DUMMY = 'h034,
  QSPI_REG_DMA_CFG   = 'h038,
  QSPI_REG_DMA_ADDR  = 'h03c,
  QSPI_REG_DMA_LEN   = 'h040,
  QSPI_REG_WRITE_TX  = 'h044,
  QSPI_REG_READ_RX   = 'h048,
  QSPI_REG_FIFO_STAT = 'h04c,
  QSPI_REG_ERR_STAT  = 'h050,
  QSPI_REG_LUT_CTRL  = 'h054,
  QSPI_REG_LUT_CFG   = 'h058,
  QSPI_REG_LUT_OP    = 'h05c,
  QSPI_REG_LUT_DUMMY = 'h060;

  // Single source of truth for spec writable-field masks (VNCHIP QSPI Spec Ch. 4).
  // Reserved bits read as zero and are masked out on write.
  function automatic bit [31:0] qspi_csr_writable_mask(input qspi_reg_offset_t addr);
    case (addr)
      QSPI_REG_CTRL:      return 32'h0000_031F;  // [9]=DMA_EN, [8]=CMD_TRIGGER, [4:0]=core control
      QSPI_REG_CLK_DIV:   return 32'h0000_0007;  // [2:0]=DIV
      QSPI_REG_CS_CTRL:   return 32'h0000_000F;  // [3:2]=CS_DELAY, [1]=CS_LEVEL, [0]=CS_AUTO
      QSPI_REG_INT_EN:    return 32'h0000_001F;  // [4:0]=interrupt enables
      QSPI_REG_XIP_CFG:   return 32'h0000_1FFF;  // [12:0]
      QSPI_REG_XIP_CMD:   return 32'h00FF_00FF;  // [23:16]=MODE_BITS, [7:0]=READ_OPCODE
      QSPI_REG_CMD_CFG:   return 32'h0000_3FFF;  // [13:0]
      QSPI_REG_CMD_OP:    return 32'h0000_FFFF;  // [15:8]=MODE_BITS, [7:0]=OPCODE
      QSPI_REG_CMD_ADDR:  return 32'hFFFF_FFFF;
      QSPI_REG_CMD_LEN:   return 32'hFFFF_FFFF;
      QSPI_REG_CMD_DUMMY: return 32'h0000_00FF;  // [7:0]
      QSPI_REG_DMA_CFG:   return 32'h0000_0030;  // [5]=INCR_ADDR, [4]=DIR
      QSPI_REG_DMA_ADDR:  return 32'hFFFF_FFFF;
      QSPI_REG_DMA_LEN:   return 32'hFFFF_FFFF;
      QSPI_REG_LUT_CTRL:  return 32'h0000_000D;  // [3:2]=LUT_INDEX, [0]=LUT_EN
      QSPI_REG_LUT_CFG:   return 32'h0000_3FFF;
      QSPI_REG_LUT_OP:    return 32'h0000_FFFF;
      QSPI_REG_LUT_DUMMY: return 32'h0000_00FF;
      default:            return 32'h0000_0000;
    endcase
  endfunction

  `include "tb/ral/qspi_csr_shadow.sv"
  `include "tb/ral/qspi_reg_block.sv"
  `include "tb/ral/qspi_apb_reg_adapter.sv"
endpackage : qspi_ral_pkg
