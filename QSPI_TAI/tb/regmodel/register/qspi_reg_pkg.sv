//==============================================================================
// Package : qspi_reg_pkg
// Desc    : UVM register definitions for VNCHIP QSPI Controller (Spec Rev 1.0)
//           One class per register, offsets 0x000 - 0x060 (APB4, 32-bit, word aligned).
//           Reserved bits are not modeled as fields -> they read back as 0.
//==============================================================================

`ifndef QSPI_REG_PKG_SV
`define QSPI_REG_PKG_SV

package qspi_reg_pkg;

  import uvm_pkg::*;
  `include "uvm_macros.svh"

  `include "id_reg.sv"        // 0x000 ID
  `include "ctrl_reg.sv"      // 0x004 CTRL
  `include "status_reg.sv"    // 0x008 STATUS
  `include "int_en.sv"        // 0x00C INT_EN
  `include "int_stat.sv"      // 0x010 INT_STAT
  `include "clk_div.sv"       // 0x014 CLK_DIV
  `include "cs_ctrl.sv"       // 0x018 CS_CTRL
  `include "xip_cfg.sv"       // 0x01C XIP_CFG
  `include "xip_cmd.sv"       // 0x020 XIP_CMD
  `include "cmd_cfg.sv"       // 0x024 CMD_CFG
  `include "cmd_op.sv"        // 0x028 CMD_OP
  `include "cmd_addr.sv"      // 0x02C CMD_ADDR
  `include "cmd_len.sv"       // 0x030 CMD_LEN
  `include "cmd_dummy.sv"     // 0x034 CMD_DUMMY
  `include "dma_cfg.sv"       // 0x038 DMA_CFG
  `include "dma_addr.sv"      // 0x03C DMA_ADDR
  `include "dma_len.sv"       // 0x040 DMA_LEN
  `include "write_tx.sv"      // 0x044 WRITE_TX
  `include "read_rx.sv"       // 0x048 READ_RX
  `include "fifo_stat.sv"     // 0x04C FIFO_STAT
  `include "err_stat.sv"      // 0x050 ERR_STAT
  `include "lut_ctrl.sv"      // 0x054 LUT_CTRL
  `include "lut_cfg.sv"       // 0x058 LUT_CFG
  `include "lut_op.sv"        // 0x05C LUT_OP
  `include "lut_dummy.sv"     // 0x060 LUT_DUMMY

endpackage : qspi_reg_pkg

`endif // QSPI_REG_PKG_SV
