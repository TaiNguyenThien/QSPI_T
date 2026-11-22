`ifndef QSPI_FLASH_PROFILE_SYNC_SV
`define QSPI_FLASH_PROFILE_SYNC_SV

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_flash_profile_sync.sv
// Role   : Passive APB/XIP-to-SPI Framing Translator for qspi_agent
// Notes  : Keeps qspi_agent project-agnostic while removing active-sequence
//          out-of-band mutation of cfg.flash_cfg_h. Preserves trigger-time
//          indirect snapshots and never sets payload_len or overrides.
// =============================================================================

`uvm_analysis_imp_decl(_fps_apb)
`uvm_analysis_imp_decl(_fps_ar)

class qspi_flash_profile_sync extends uvm_component;
  `uvm_component_utils(qspi_flash_profile_sync)

  qspi_env_cfg    cfg;
  qspi_csr_shadow shadow;

  uvm_analysis_imp_fps_apb #(qspi_apb_item_t,         qspi_flash_profile_sync) apb_imp;
  uvm_analysis_imp_fps_ar  #(axil_master_transaction, qspi_flash_profile_sync) axil_ar_imp;

  function new(string name = "qspi_flash_profile_sync", uvm_component parent = null);
    super.new(name, parent);
    apb_imp     = new("apb_imp", this);
    axil_ar_imp = new("axil_ar_imp", this);
    shadow      = qspi_csr_shadow::type_id::create("fps_csr_shadow");
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null || cfg.clk_vif == null || cfg.flash_cfg_h == null)
      `uvm_fatal("QSPI_FPS_CFG", "Missing cfg / clk_vif / flash_cfg_h")
  endfunction

  protected function void apply_cmd_profile(qspi_cmd_profile_t p);
    qspi_agent_pkg::qspi_cfg f;
    if (cfg == null || cfg.flash_cfg_h == null) return;
    f              = cfg.flash_cfg_h;
    f.cpol         = p.cpol;
    f.cpha         = p.cpha;
    f.cmd_lanes    = qspi_is_legal_lane_enc(p.cmd_lanes_enc)  ? qspi_eff_lane_enc(p.cmd_lanes_enc,  p.quad_en) : 2'b00;
    f.addr_lanes   = qspi_is_legal_lane_enc(p.addr_lanes_enc) ? qspi_eff_lane_enc(p.addr_lanes_enc, p.quad_en) : 2'b00;
    f.data_lanes   = qspi_is_legal_lane_enc(p.data_lanes_enc) ? qspi_eff_lane_enc(p.data_lanes_enc, p.quad_en) : 2'b00;
    f.addr_bytes   = qspi_is_legal_addr_enc(p.addr_bytes_enc) ? p.addr_bytes_enc : 2'b00;
    f.mode_en      = p.mode_en;
    f.dummy_cycles = p.dummy_cycles;
    f.extra_dummy  = p.extra_dummy;
    f.dir          = p.dir;
    f.cs_delay     = p.cs_delay;
  endfunction

  protected function void apply_xip_profile(qspi_xip_profile_t p);
    qspi_agent_pkg::qspi_cfg f;
    if (cfg == null || cfg.flash_cfg_h == null) return;
    f              = cfg.flash_cfg_h;
    f.cpol         = p.cpol;
    f.cpha         = p.cpha;
    f.cmd_lanes    = qspi_is_legal_lane_enc(p.cmd_lanes_enc)  ? qspi_eff_lane_enc(p.cmd_lanes_enc,  p.quad_en) : 2'b00;
    f.addr_lanes   = qspi_is_legal_lane_enc(p.addr_lanes_enc) ? qspi_eff_lane_enc(p.addr_lanes_enc, p.quad_en) : 2'b00;
    f.data_lanes   = qspi_is_legal_lane_enc(p.data_lanes_enc) ? qspi_eff_lane_enc(p.data_lanes_enc, p.quad_en) : 2'b00;
    f.addr_bytes   = qspi_is_legal_addr_enc(p.addr_bytes_enc) ? p.addr_bytes_enc : 2'b01;
    f.mode_en      = p.mode_en;
    f.dummy_cycles = p.dummy_cycles;
    f.extra_dummy  = 8'h00;
    f.dir          = 1'b1;
    f.cs_delay     = p.cs_delay;
  endfunction

  protected function bit cs_is_idle();
    return (cfg == null || cfg.flash_vif == null || cfg.flash_vif.qspi_cs_n !== 1'b0);
  endfunction

  function void write_fps_apb(qspi_apb_item_t t);
    bit triggered;
    if (cfg == null || cfg.clk_vif == null || cfg.clk_vif.rst_n !== 1'b1)
      return;
    triggered = shadow.apply_apb_write(t);
    if (triggered) begin
      apply_cmd_profile(shadow.get_cmd_snapshot());
    end else if (shadow.ctrl[0] && shadow.ctrl[1] && cs_is_idle()) begin
      apply_xip_profile(shadow.get_xip_snapshot());
    end
  endfunction

  function void write_fps_ar(axil_master_transaction tr);
    if (tr == null || tr.reset_abort || tr.timed_out)
      return;
    if (cfg == null || cfg.clk_vif == null || cfg.clk_vif.rst_n !== 1'b1)
      return;
    if (shadow.ctrl[0] && shadow.ctrl[1] && cs_is_idle()) begin
      apply_xip_profile(shadow.get_xip_snapshot());
    end
  endfunction

  task run_phase(uvm_phase phase);
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      shadow.reset();
    end
  endtask

endclass : qspi_flash_profile_sync

`endif // QSPI_FLASH_PROFILE_SYNC_SV
