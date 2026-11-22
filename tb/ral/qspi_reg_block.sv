`ifndef QSPI_REG_BLOCK_SV
`define QSPI_REG_BLOCK_SV

// A CSR's UVM fields describe access policy; no bus protocol lives here.
class qspi_csr_reg extends uvm_reg;
  `uvm_object_utils(qspi_csr_reg)
  protected bit [31:0] occupied;

  function new(string name = "qspi_csr_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  function void define_field(string field_name, int unsigned width,
                             int unsigned lsb, string access,
                             bit is_volatile = 0,
                             uvm_reg_data_t reset_value = 0);
    uvm_reg_field f;
    bit [31:0] mask;
    if (width == 0 || width > 32 || lsb + width > 32)
      `uvm_fatal("QSPI_RAL_LAYOUT", {get_name(), ": invalid field bounds"})
    mask = ((32'hFFFF_FFFF >> (32-width)) << lsb);
    if ((occupied & mask) != 0)
      `uvm_fatal("QSPI_RAL_LAYOUT", {get_name(), ": overlapping fields"})
    occupied |= mask;
    f = uvm_reg_field::type_id::create(field_name);
    f.configure(this, width, lsb, access, is_volatile,
                reset_value, 1, 0, 0);
    if (is_volatile) f.set_compare(UVM_NO_CHECK);
  endfunction

  // Reserved bits are read-only zero; split holes into contiguous fields.
  function void add_reserved();
    int unsigned lsb, width;
    lsb = 0;
    while (lsb < 32) begin
      if (occupied[lsb]) begin
        lsb++;
        continue;
      end
      width = 0;
      while (lsb + width < 32 && !occupied[lsb + width]) width++;
      define_field($sformatf("RESERVED_%0d", lsb), width, lsb, "RO");
      lsb += width;
    end
  endfunction
endclass : qspi_csr_reg

// Fixed CSR addresses from VNCHIP QSPI spec, chapter 4. LUT data windows are
// banked through LUT_CTRL.INDEX and therefore deliberately use raw APB access.
class qspi_self_clear_field_cb extends uvm_reg_cbs;
  `uvm_object_utils(qspi_self_clear_field_cb)

  function new(string name = "qspi_self_clear_field_cb");
    super.new(name);
  endfunction

  virtual function void post_predict(input uvm_reg_field fld,
                                     input uvm_reg_data_t previous,
                                     inout uvm_reg_data_t value,
                                     input uvm_predict_e kind,
                                     input uvm_path_e path,
                                     input uvm_reg_map map);
    if (kind == UVM_PREDICT_WRITE || kind == UVM_PREDICT_DIRECT)
      value = 0;
  endfunction
endclass : qspi_self_clear_field_cb

class qspi_reg_block extends uvm_reg_block;
  `uvm_object_utils(qspi_reg_block)
  qspi_csr_reg id_reg, ctrl, status, int_en, int_stat, clk_div, cs_ctrl;
  qspi_csr_reg xip_cfg, xip_cmd, cmd_cfg, cmd_op, cmd_addr, cmd_len;
  qspi_csr_reg cmd_dummy, dma_cfg, dma_addr, dma_len;
  qspi_csr_reg fifo_stat, err_stat, lut_ctrl;

  function new(string name = "qspi_reg_block");
    super.new(name, UVM_NO_COVERAGE);
  endfunction

  function qspi_csr_reg make_reg(string name, uvm_reg_addr_t offset,
                                  string rights = "RW");
    qspi_csr_reg r;
    r = qspi_csr_reg::type_id::create(name);
    r.configure(this, null, "");
    default_map.add_reg(r, offset, rights);
    return r;
  endfunction

  // FIFO side effects and selected LUT windows have no fixed mirror.
  function uvm_reg get_fixed_csr(qspi_reg_offset_t address, bit read_direction);
    case (address)
      QSPI_REG_WRITE_TX, QSPI_REG_READ_RX,
      QSPI_REG_LUT_CFG, QSPI_REG_LUT_OP, QSPI_REG_LUT_DUMMY: return null;
      default: return default_map.get_reg_by_offset(address, read_direction);
    endcase
  endfunction

  virtual function void build();
    qspi_self_clear_field_cb sc_cb;
    default_map = create_map("apb_map", 'h0, 4, UVM_LITTLE_ENDIAN, 1);

    id_reg = make_reg("ID", QSPI_REG_ID, "RO");
    id_reg.define_field("ARCH_ID", 16, 16, "RO", 0, 'h0A10);
    id_reg.define_field("MAJOR", 8, 8, "RO", 0, 'h01);
    id_reg.define_field("MINOR", 8, 0, "RO", 0, 'h02);

    ctrl = make_reg("CTRL", QSPI_REG_CTRL);
    ctrl.define_field("ENABLE", 1, 0, "RW");
    ctrl.define_field("XIP_EN", 1, 1, "RW");
    ctrl.define_field("QUAD_EN", 1, 2, "RW");
    ctrl.define_field("CPOL", 1, 3, "RW");
    ctrl.define_field("CPHA", 1, 4, "RW");
    ctrl.define_field("CMD_TRIGGER", 1, 8, "RW", 1);
    ctrl.define_field("DMA_EN", 1, 9, "RW", 1);
    sc_cb = qspi_self_clear_field_cb::type_id::create("sc_cb");
    uvm_reg_field_cb::add(ctrl.get_field_by_name("CMD_TRIGGER"), sc_cb);
    uvm_reg_field_cb::add(ctrl.get_field_by_name("DMA_EN"), sc_cb);

    status = make_reg("STATUS", QSPI_REG_STATUS, "RO");
    status.define_field("BUSY", 1, 0, "RO", 1);
    status.define_field("XIP_ACTIVE", 1, 1, "RO", 1);
    status.define_field("CMD_DONE", 1, 2, "RO", 1);
    status.define_field("DMA_DONE", 1, 3, "RO", 1);

    int_en = make_reg("INT_EN", QSPI_REG_INT_EN);
    int_en.define_field("CMD_DONE_EN", 1, 0, "RW");
    int_en.define_field("DMA_DONE_EN", 1, 1, "RW");
    int_en.define_field("ERR_EN", 1, 2, "RW");
    int_en.define_field("FIFO_TX_EMPTY_EN", 1, 3, "RW");
    int_en.define_field("FIFO_RX_FULL_EN", 1, 4, "RW");

    int_stat = make_reg("INT_STAT", QSPI_REG_INT_STAT);
    int_stat.define_field("CMD_DONE", 1, 0, "W1C", 1);
    int_stat.define_field("DMA_DONE", 1, 1, "W1C", 1);
    int_stat.define_field("ERR", 1, 2, "W1C", 1);
    int_stat.define_field("FIFO_TX_EMPTY", 1, 3, "W1C", 1);
    int_stat.define_field("FIFO_RX_FULL", 1, 4, "W1C", 1);

    clk_div = make_reg("CLK_DIV", QSPI_REG_CLK_DIV);
    clk_div.define_field("DIV", 3, 0, "RW");
    cs_ctrl = make_reg("CS_CTRL", QSPI_REG_CS_CTRL);
    cs_ctrl.define_field("CS_AUTO", 1, 0, "RW");
    cs_ctrl.define_field("CS_LEVEL", 1, 1, "RW");
    cs_ctrl.define_field("CS_DELAY", 2, 2, "RW");

    xip_cfg = make_reg("XIP_CFG", QSPI_REG_XIP_CFG);
    xip_cfg.define_field("CMD_LANES", 2, 0, "RW");
    xip_cfg.define_field("ADDR_LANES", 2, 2, "RW");
    xip_cfg.define_field("DATA_LANES", 2, 4, "RW");
    xip_cfg.define_field("ADDR_BYTES", 2, 6, "RW");
    xip_cfg.define_field("MODE_EN", 1, 8, "RW");
    xip_cfg.define_field("DUMMY_CYCLES", 4, 9, "RW");
    xip_cmd = make_reg("XIP_CMD", QSPI_REG_XIP_CMD);
    xip_cmd.define_field("READ_OPCODE", 8, 0, "RW");
    xip_cmd.define_field("MODE_BITS", 8, 16, "RW");

    cmd_cfg = make_reg("CMD_CFG", QSPI_REG_CMD_CFG);
    cmd_cfg.define_field("CMD_LANES", 2, 0, "RW");
    cmd_cfg.define_field("ADDR_LANES", 2, 2, "RW");
    cmd_cfg.define_field("DATA_LANES", 2, 4, "RW");
    cmd_cfg.define_field("ADDR_BYTES", 2, 6, "RW");
    cmd_cfg.define_field("MODE_EN", 1, 8, "RW");
    cmd_cfg.define_field("DUMMY_CYCLES", 4, 9, "RW");
    cmd_cfg.define_field("DIR", 1, 13, "RW");
    cmd_op = make_reg("CMD_OP", QSPI_REG_CMD_OP);
    cmd_op.define_field("OPCODE", 8, 0, "RW");
    cmd_op.define_field("MODE_BITS", 8, 8, "RW");
    cmd_addr = make_reg("CMD_ADDR", QSPI_REG_CMD_ADDR);
    cmd_addr.define_field("ADDR", 32, 0, "RW");
    cmd_len = make_reg("CMD_LEN", QSPI_REG_CMD_LEN);
    cmd_len.define_field("LENGTH", 32, 0, "RW");
    cmd_dummy = make_reg("CMD_DUMMY", QSPI_REG_CMD_DUMMY);
    cmd_dummy.define_field("EXTRA_DUMMY", 8, 0, "RW");

    dma_cfg = make_reg("DMA_CFG", QSPI_REG_DMA_CFG);
    dma_cfg.define_field("DIR", 1, 4, "RW");
    dma_cfg.define_field("INCR_ADDR", 1, 5, "RW");
    dma_addr = make_reg("DMA_ADDR", QSPI_REG_DMA_ADDR);
    dma_addr.define_field("ADDR", 32, 0, "RW");
    dma_len = make_reg("DMA_LEN", QSPI_REG_DMA_LEN);
    dma_len.define_field("LENGTH", 32, 0, "RW");

    fifo_stat = make_reg("FIFO_STAT", QSPI_REG_FIFO_STAT, "RO");
    fifo_stat.define_field("TX_LEVEL", 4, 0, "RO", 1);
    fifo_stat.define_field("RX_LEVEL", 4, 4, "RO", 1);
    fifo_stat.define_field("TX_EMPTY", 1, 8, "RO", 1);
    fifo_stat.define_field("RX_FULL", 1, 9, "RO", 1);
    err_stat = make_reg("ERR_STAT", QSPI_REG_ERR_STAT, "RO");
    err_stat.define_field("TIMEOUT", 1, 0, "RO", 1);
    err_stat.define_field("OVERRUN", 1, 1, "RO", 1);
    err_stat.define_field("UNDERRUN", 1, 2, "RO", 1);
    lut_ctrl = make_reg("LUT_CTRL", QSPI_REG_LUT_CTRL);
    lut_ctrl.define_field("ENABLE", 1, 0, "RW");
    lut_ctrl.define_field("INDEX", 2, 2, "RW");

    id_reg.add_reserved(); ctrl.add_reserved(); status.add_reserved();
    int_en.add_reserved(); int_stat.add_reserved(); clk_div.add_reserved();
    cs_ctrl.add_reserved(); xip_cfg.add_reserved(); xip_cmd.add_reserved();
    cmd_cfg.add_reserved(); cmd_op.add_reserved(); cmd_addr.add_reserved();
    cmd_len.add_reserved(); cmd_dummy.add_reserved(); dma_cfg.add_reserved();
    dma_addr.add_reserved(); dma_len.add_reserved();
    fifo_stat.add_reserved(); err_stat.add_reserved(); lut_ctrl.add_reserved();
    lock_model();
  endfunction
endclass : qspi_reg_block
`endif
