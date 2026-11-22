`ifndef QSPI_TB_MEM_SERVICE_SV
`define QSPI_TB_MEM_SERVICE_SV

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_tb_mem_service.sv
// Role   : Concrete Testbench Memory & Responder Service Implementation
// =============================================================================

class qspi_tb_mem_service extends qspi_mem_service;
  `uvm_object_utils(qspi_tb_mem_service)

  qspi_env_cfg                     cfg;
  qspi_agent_pkg::qspi_flash_slave flash_slave;
  axi_slave_driver                 axi_drv;
  axi_slave_cfg                    axi_cfg;
  qspi_xip_sb                      xip_sb;

  function new(string name = "qspi_tb_mem_service");
    super.new(name);
  endfunction

  virtual function void clear_ram();
    if (axi_drv != null)
      axi_drv.clear_mem();
  endfunction

  virtual task write_ram_byte(bit [31:0] addr, bit [7:0] data);
    if (axi_drv == null)
      `uvm_fatal("QSPI_MEM_SVC", "write_ram_byte called with null axi_drv")
    axi_drv.write_mem(addr, data);
  endtask

  virtual function bit [7:0] read_ram_byte(bit [31:0] addr);
    if (axi_drv == null) begin
      `uvm_fatal("QSPI_MEM_SVC", "read_ram_byte called with null axi_drv")
      return 8'hFF;
    end
    return axi_drv.read_mem(addr);
  endfunction

  virtual task fill_ram_range(bit [31:0] base_addr, int unsigned len, bit [7:0] seed_base);
    if (axi_drv == null)
      `uvm_fatal("QSPI_MEM_SVC", "fill_ram_range called with null axi_drv")
    for (int unsigned i = 0; i < len; i++)
      axi_drv.write_mem(base_addr + i, 8'(seed_base + i));
  endtask

  virtual function void clear_flash(bit reset_device = 1'b0);
    if (flash_slave != null) begin
      flash_slave.flash_mem.delete();
      if (reset_device)
        flash_slave.reset_device_state();
    end
    if (xip_sb != null)
      xip_sb.clear_flash_ref(reset_device);
  endfunction

  virtual function void preload_flash_byte(bit [31:0] addr, bit [7:0] data, bit mirror_sb = 1'b1);
    if (flash_slave == null)
      `uvm_fatal("QSPI_MEM_SVC", "preload_flash_byte called with null flash_slave")
    flash_slave.set_mem_byte(addr, data);
    if (mirror_sb && xip_sb != null)
      xip_sb.preload_byte(addr, data);
  endfunction

  virtual function void preload_flash_word(
    bit [31:0] addr,
    bit [31:0] data,
    bit        mirror_sb = 1'b1
  );
    // Pure AMBA Little-Endian word preload: byte0 = data[7:0] .. byte3 = data[31:24]
    preload_flash_byte(addr + 32'd0, data[7:0],   mirror_sb);
    preload_flash_byte(addr + 32'd1, data[15:8],  mirror_sb);
    preload_flash_byte(addr + 32'd2, data[23:16], mirror_sb);
    preload_flash_byte(addr + 32'd3, data[31:24], mirror_sb);
  endfunction

  virtual function void preload_flash_range(
    bit [31:0]   base_addr,
    int unsigned len,
    bit [7:0]    seed_base,
    bit          mirror_sb = 1'b1
  );
    for (int unsigned i = 0; i < len; i++)
      preload_flash_byte(base_addr + i, 8'(seed_base + i), mirror_sb);
  endfunction

  virtual function bit [7:0] get_flash_byte(bit [31:0] addr);
    if (flash_slave == null) begin
      `uvm_fatal("QSPI_MEM_SVC", "get_flash_byte called with null flash_slave")
      return 8'hFF;
    end
    return flash_slave.get_mem_byte(addr);
  endfunction

  virtual function void set_flash_override(bit [7:0] bytes[$], bit [7:0] pad = 8'hFF);
    if (cfg == null || cfg.flash_cfg_h == null)
      `uvm_fatal("QSPI_MEM_SVC", "set_flash_override called with null flash_cfg_h")
    cfg.flash_cfg_h.response_source = qspi_agent_pkg::qspi_cfg::OVERRIDE_BUFFER;
    cfg.flash_cfg_h.read_bytes      = bytes;
    cfg.flash_cfg_h.override_pad    = pad;
  endfunction

  virtual function void clear_flash_override();
    if (cfg != null && cfg.flash_cfg_h != null)
      cfg.flash_cfg_h.clear_override();
  endfunction

  virtual function void set_axi_resp(
    bit [1:0] default_bresp,
    bit [1:0] default_rresp,
    int       inject_beat = -1
  );
    if (axi_cfg == null)
      `uvm_fatal("QSPI_MEM_SVC", "set_axi_resp called with null axi_cfg")
    axi_cfg.default_bresp     = default_bresp;
    axi_cfg.default_rresp     = default_rresp;
    axi_cfg.inject_error_beat = inject_beat;
  endfunction

  virtual function void set_axi_delays(
    int unsigned awready_d,
    int unsigned wready_d,
    int unsigned arready_d,
    int unsigned bvalid_d,
    int unsigned rvalid_d
  );
    if (axi_cfg == null)
      `uvm_fatal("QSPI_MEM_SVC", "set_axi_delays called with null axi_cfg")
    axi_cfg.awready_delay_knob = awready_d;
    axi_cfg.wready_delay_knob  = wready_d;
    axi_cfg.arready_delay_knob = arready_d;
    axi_cfg.bvalid_delay_knob  = bvalid_d;
    axi_cfg.rvalid_delay_knob  = rvalid_d;
  endfunction

  virtual function void reset_axi_knobs();
    if (axi_cfg != null)
      axi_cfg.reset_knobs();
  endfunction

endclass : qspi_tb_mem_service

`endif // QSPI_TB_MEM_SERVICE_SV
