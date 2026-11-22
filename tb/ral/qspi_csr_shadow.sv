`ifndef QSPI_CSR_SHADOW_SV
`define QSPI_CSR_SHADOW_SV

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_csr_shadow.sv
// Role   : Reusable Spec-Compliant Passive APB CSR Shadow Helper
// Notes  : Each checker/coverage subscriber owns its own instance so
//          independent evaluation and reset/batch ordering are preserved,
//          while sharing one normative PSTRB, LUT, and snapshot implementation.
// =============================================================================

typedef struct {
  bit [31:0] ctrl;
  bit [2:0]  clk_div;
  bit        cs_auto;
  bit        cs_level;
  bit [1:0]  cs_delay;
  bit        enable;
  bit        xip_en;
  bit        quad_en;
  bit        cpol;
  bit        cpha;
  bit        use_lut;
  bit [1:0]  lut_index;
  bit [31:0] cmd_cfg;
  bit [31:0] cmd_op;
  bit [31:0] cmd_addr;
  bit [31:0] cmd_len;
  bit [31:0] cmd_dummy;
  bit [1:0]  cmd_lanes_enc;
  bit [1:0]  addr_lanes_enc;
  bit [1:0]  data_lanes_enc;
  bit [1:0]  addr_bytes_enc;
  bit        mode_en;
  bit [3:0]  dummy_cycles;
  bit [7:0]  extra_dummy;
  bit        dir;
  bit [7:0]  opcode;
  bit [7:0]  mode_bits;
  bit [31:0] dma_cfg;
  bit [31:0] dma_addr;
  bit [31:0] dma_len;
  bit        dma_dir;
  bit        dma_incr_addr;
} qspi_cmd_profile_t;

typedef struct {
  bit [31:0] ctrl;
  bit [2:0]  clk_div;
  bit        cs_auto;
  bit        cs_level;
  bit [1:0]  cs_delay;
  bit        enable;
  bit        xip_en;
  bit        quad_en;
  bit        cpol;
  bit        cpha;
  bit [31:0] xip_cfg;
  bit [31:0] xip_cmd;
  bit [1:0]  cmd_lanes_enc;
  bit [1:0]  addr_lanes_enc;
  bit [1:0]  data_lanes_enc;
  bit [1:0]  addr_bytes_enc;
  bit        mode_en;
  bit [3:0]  dummy_cycles;
  bit [7:0]  read_opcode;
  bit [7:0]  mode_bits;
} qspi_xip_profile_t;

class qspi_csr_shadow extends uvm_object;
  `uvm_object_utils(qspi_csr_shadow)

  bit [31:0] ctrl;
  bit [31:0] int_en;
  bit [31:0] clk_div;
  bit [31:0] cs_ctrl;
  bit [31:0] xip_cfg;
  bit [31:0] xip_cmd;
  bit [31:0] cmd_cfg;
  bit [31:0] cmd_op;
  bit [31:0] cmd_addr;
  bit [31:0] cmd_len;
  bit [31:0] cmd_dummy;
  bit [31:0] dma_cfg;
  bit [31:0] dma_addr;
  bit [31:0] dma_len;
  bit [31:0] lut_ctrl;
  bit [31:0] lut_cfg[4];
  bit [31:0] lut_op[4];
  bit [31:0] lut_dummy[4];

  function new(string name = "qspi_csr_shadow");
    super.new(name);
    reset();
  endfunction

  function void reset();
    ctrl      = 32'h0;
    int_en    = 32'h0;
    clk_div   = 32'h0;
    cs_ctrl   = 32'h0;
    xip_cfg   = 32'h0;
    xip_cmd   = 32'h0;
    cmd_cfg   = 32'h0;
    cmd_op    = 32'h0;
    cmd_addr  = 32'h0;
    cmd_len   = 32'h0;
    cmd_dummy = 32'h0;
    dma_cfg   = 32'h0;
    dma_addr  = 32'h0;
    dma_len   = 32'h0;
    lut_ctrl  = 32'h0;
    for (int i = 0; i < 4; i++) begin
      lut_cfg[i]   = 32'h0;
      lut_op[i]    = 32'h0;
      lut_dummy[i] = 32'h0;
    end
  endfunction

  // Spec APB4 PSTRB byte-lane update with writable-field masking
  static function bit [31:0] merge_pstrb(
    input bit [31:0]   cur_val,
    input logic [31:0] wdata,
    input logic [3:0]  strb,
    input bit [31:0]   mask
  );
    bit [31:0] nxt;
    nxt = cur_val;
    for (int lane = 0; lane < 4; lane++) begin
      if (strb[lane] === 1'b1)
        nxt[8*lane +: 8] = wdata[8*lane +: 8];
    end
    return (nxt & mask);
  endfunction

  // Spec per-bit W1C mask gated by PSTRB[0]
  static function bit [4:0] apply_w1c_mask(
    input bit [4:0]    cur_stat,
    input logic [31:0] wdata,
    input logic [3:0]  strb
  );
    if (strb[0] !== 1'b1 || $isunknown(wdata[4:0]))
      return cur_stat;
    return (cur_stat & ~wdata[4:0]);
  endfunction

  // Apply an accepted, completed, non-aborted APB write transaction.
  // Returns 1 if this write triggers an indirect command (CMD_TRIGGER=1 with ENABLE=1 and XIP_EN=0).
  function bit apply_apb_write(qspi_apb_item_t t);
    int unsigned lut_idx;
    bit          eff_enable;
    bit          triggered;
    triggered = 1'b0;

    if (t == null || t.reset_abort || t.write !== 1'b1 || t.slverr !== 1'b0)
      return 1'b0;
    if ($isunknown({t.addr, t.strb}))
      return 1'b0;
    for (int lane = 0; lane < 4; lane++) begin
      if (t.strb[lane] === 1'b1 && $isunknown(t.wdata[8*lane +: 8]))
        return 1'b0;
    end

    lut_idx = int'(lut_ctrl[3:2]);
    case (t.addr)
      QSPI_REG_CTRL: begin
        bit [31:0] merged_ctrl;
        eff_enable  = (t.strb[0] === 1'b1) ? t.wdata[0] : ctrl[0];
        merged_ctrl = merge_pstrb(ctrl, t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CTRL));
        ctrl        = merged_ctrl & 32'h0000_001F; // Keep persistent [4:0]; [9:8] are pulse/self-clear
        if ((t.strb[1] === 1'b1) && (t.wdata[8] === 1'b1) && eff_enable) begin
          if (lut_ctrl[0]) begin
            cmd_cfg   = lut_cfg[lut_idx];
            cmd_op    = lut_op[lut_idx];
            cmd_dummy = lut_dummy[lut_idx];
          end
          if (!ctrl[1])
            triggered = 1'b1;
        end
      end
      QSPI_REG_INT_EN:    int_en    = merge_pstrb(int_en,    t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_INT_EN));
      QSPI_REG_CLK_DIV:   clk_div   = merge_pstrb(clk_div,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CLK_DIV));
      QSPI_REG_CS_CTRL:   cs_ctrl   = merge_pstrb(cs_ctrl,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CS_CTRL));
      QSPI_REG_XIP_CFG:   xip_cfg   = merge_pstrb(xip_cfg,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_XIP_CFG));
      QSPI_REG_XIP_CMD:   xip_cmd   = merge_pstrb(xip_cmd,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_XIP_CMD));
      QSPI_REG_CMD_CFG:   cmd_cfg   = merge_pstrb(cmd_cfg,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CMD_CFG));
      QSPI_REG_CMD_OP:    cmd_op    = merge_pstrb(cmd_op,    t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CMD_OP));
      QSPI_REG_CMD_ADDR:  cmd_addr  = merge_pstrb(cmd_addr,  t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CMD_ADDR));
      QSPI_REG_CMD_LEN:   cmd_len   = merge_pstrb(cmd_len,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CMD_LEN));
      QSPI_REG_CMD_DUMMY: cmd_dummy = merge_pstrb(cmd_dummy, t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_CMD_DUMMY));
      QSPI_REG_DMA_CFG:   dma_cfg   = merge_pstrb(dma_cfg,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_DMA_CFG));
      QSPI_REG_DMA_ADDR:  dma_addr  = merge_pstrb(dma_addr,  t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_DMA_ADDR));
      QSPI_REG_DMA_LEN:   dma_len   = merge_pstrb(dma_len,   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_DMA_LEN));
      QSPI_REG_LUT_CTRL:  lut_ctrl  = merge_pstrb(lut_ctrl,  t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_LUT_CTRL));
      QSPI_REG_LUT_CFG:   lut_cfg[lut_idx]   = merge_pstrb(lut_cfg[lut_idx],   t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_LUT_CFG));
      QSPI_REG_LUT_OP:    lut_op[lut_idx]    = merge_pstrb(lut_op[lut_idx],    t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_LUT_OP));
      QSPI_REG_LUT_DUMMY: lut_dummy[lut_idx] = merge_pstrb(lut_dummy[lut_idx], t.wdata, t.strb, qspi_csr_writable_mask(QSPI_REG_LUT_DUMMY));
      default: ;
    endcase
    return triggered;
  endfunction

  function bit [31:0] get_reg(qspi_reg_offset_t addr);
    int unsigned lut_idx;
    lut_idx = int'(lut_ctrl[3:2]);
    case (addr)
      QSPI_REG_CTRL:      return ctrl;
      QSPI_REG_INT_EN:    return int_en;
      QSPI_REG_CLK_DIV:   return clk_div;
      QSPI_REG_CS_CTRL:   return cs_ctrl;
      QSPI_REG_XIP_CFG:   return xip_cfg;
      QSPI_REG_XIP_CMD:   return xip_cmd;
      QSPI_REG_CMD_CFG:   return cmd_cfg;
      QSPI_REG_CMD_OP:    return cmd_op;
      QSPI_REG_CMD_ADDR:  return cmd_addr;
      QSPI_REG_CMD_LEN:   return cmd_len;
      QSPI_REG_CMD_DUMMY: return cmd_dummy;
      QSPI_REG_DMA_CFG:   return dma_cfg;
      QSPI_REG_DMA_ADDR:  return dma_addr;
      QSPI_REG_DMA_LEN:   return dma_len;
      QSPI_REG_LUT_CTRL:  return lut_ctrl;
      QSPI_REG_LUT_CFG:   return lut_cfg[lut_idx];
      QSPI_REG_LUT_OP:    return lut_op[lut_idx];
      QSPI_REG_LUT_DUMMY: return lut_dummy[lut_idx];
      default:            return 32'h0;
    endcase
  endfunction

  function qspi_cmd_profile_t get_cmd_snapshot();
    qspi_cmd_profile_t p;
    int unsigned       idx;
    idx              = int'(lut_ctrl[3:2]);
    p.ctrl           = ctrl;
    p.clk_div        = clk_div[2:0];
    p.cs_auto        = cs_ctrl[0];
    p.cs_level       = cs_ctrl[1];
    p.cs_delay       = cs_ctrl[3:2];
    p.enable         = ctrl[0];
    p.xip_en         = ctrl[1];
    p.quad_en        = ctrl[2];
    p.cpol           = ctrl[3];
    p.cpha           = ctrl[4];
    p.use_lut        = lut_ctrl[0];
    p.lut_index      = lut_ctrl[3:2];
    p.cmd_cfg        = p.use_lut ? lut_cfg[idx]   : cmd_cfg;
    p.cmd_op         = p.use_lut ? lut_op[idx]    : cmd_op;
    p.cmd_dummy      = p.use_lut ? lut_dummy[idx] : cmd_dummy;
    p.cmd_addr       = cmd_addr;
    p.cmd_len        = cmd_len;
    p.cmd_lanes_enc  = p.cmd_cfg[1:0];
    p.addr_lanes_enc = p.cmd_cfg[3:2];
    p.data_lanes_enc = p.cmd_cfg[5:4];
    p.addr_bytes_enc = p.cmd_cfg[7:6];
    p.mode_en        = p.cmd_cfg[8];
    p.dummy_cycles   = p.cmd_cfg[12:9];
    p.dir            = p.cmd_cfg[13];
    p.opcode         = p.cmd_op[7:0];
    p.mode_bits      = p.cmd_op[15:8];
    p.extra_dummy    = p.cmd_dummy[7:0];
    p.dma_cfg        = dma_cfg;
    p.dma_addr       = dma_addr;
    p.dma_len        = dma_len;
    p.dma_dir        = dma_cfg[4];
    p.dma_incr_addr  = dma_cfg[5];
    return p;
  endfunction

  function qspi_xip_profile_t get_xip_snapshot();
    qspi_xip_profile_t p;
    p.ctrl           = ctrl;
    p.clk_div        = clk_div[2:0];
    p.cs_auto        = cs_ctrl[0];
    p.cs_level       = cs_ctrl[1];
    p.cs_delay       = cs_ctrl[3:2];
    p.enable         = ctrl[0];
    p.xip_en         = ctrl[1];
    p.quad_en        = ctrl[2];
    p.cpol           = ctrl[3];
    p.cpha           = ctrl[4];
    p.xip_cfg        = xip_cfg;
    p.xip_cmd        = xip_cmd;
    p.cmd_lanes_enc  = xip_cfg[1:0];
    p.addr_lanes_enc = xip_cfg[3:2];
    p.data_lanes_enc = xip_cfg[5:4];
    p.addr_bytes_enc = xip_cfg[7:6];
    p.mode_en        = xip_cfg[8];
    p.dummy_cycles   = xip_cfg[12:9];
    p.read_opcode    = xip_cmd[7:0];
    p.mode_bits      = xip_cmd[23:16];
    return p;
  endfunction
endclass : qspi_csr_shadow

`endif // QSPI_CSR_SHADOW_SV
