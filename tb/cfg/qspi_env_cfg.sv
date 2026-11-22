`ifndef QSPI_ENV_CFG_SV
`define QSPI_ENV_CFG_SV

class qspi_env_cfg extends uvm_object;
  `uvm_object_utils(qspi_env_cfg)

  qspi_apb_cfg_t            apb_cfg_h;
  qspi_agent_pkg::qspi_cfg  flash_cfg_h;
  axi_slave_cfg             axi_cfg_h;
  axil_master_cfg           axil_cfg_h;

  virtual qspi_if        flash_vif;
  virtual clk_rst_irq_if clk_vif;
  virtual axi_if         axi_vif;
  virtual axil_if        axil_vif;
  uvm_event              reset_request;

  bit enable_apb_sb       = 1;
  bit enable_flow_sb      = 1;
  bit enable_dma_sb       = 0;
  bit enable_xip_sb       = 0;
  bit enable_apb_cov      = 1;
  bit enable_flow_cov     = 1;
  bit enable_reg_cov      = 1;
  bit enable_irq_cov      = 1;
  bit enable_dma_cov      = 0;
  bit enable_xip_cov      = 0;
  bit enable_flash_agent  = 1;
  bit enable_dma_agent    = 0;
  bit enable_axil_agent   = 0;
  bit enable_sclk_chk     = 1;
  bit enable_status_chk   = 1;
  bit enable_apb_contract = 1;

  // Pure black-box Spec policy knobs
  bit          xip_allow_unaligned_char = 1; // Dedicated characterization path (XIP_TC_012)
  bit          enforce_xip_max_os       = 1;
  int unsigned xip_max_outstanding      = 1;
  int unsigned active_seed              = 0;

  int unsigned timeout_cycles             = 100000;
  int unsigned transaction_timeout_cycles = 10000;

  function new(string name = "qspi_env_cfg");
    super.new(name);
    apb_cfg_h   = qspi_apb_cfg_t::type_id::create("apb_cfg_h");
    flash_cfg_h = qspi_agent_pkg::qspi_cfg::type_id::create("flash_cfg_h");
    axi_cfg_h   = axi_slave_cfg::type_id::create("axi_cfg_h");
    axil_cfg_h  = axil_master_cfg::type_id::create("axil_cfg_h");
  endfunction

  protected function bit get_uint_arg(string prefix, output int unsigned value);
    uvm_cmdline_processor cli;
    string values[$];
    string raw;
    longint unsigned parsed;
    cli = uvm_cmdline_processor::get_inst();
    if (cli.get_arg_values(prefix, values) == 0) return 0;
    if (values.size() != 1)
      `uvm_fatal("QSPI_CFG_PLUSARG", {"Duplicate argument: ", prefix})
    raw = values[0];
    if (raw.len() == 0)
      `uvm_fatal("QSPI_CFG_PLUSARG", {"Missing value: ", prefix})
    parsed = 0;
    for (int i = 0; i < raw.len(); i++) begin
      if (raw.getc(i) < 8'h30 || raw.getc(i) > 8'h39)
        `uvm_fatal("QSPI_CFG_PLUSARG", {"Expected unsigned decimal: ", prefix, raw})
      parsed = parsed * 10 + (raw.getc(i) - 8'h30);
      if (parsed > 64'hFFFF_FFFF)
        `uvm_fatal("QSPI_CFG_PLUSARG", {"Value exceeds 32 bits: ", prefix, raw})
    end
    value = int'(parsed);
    return 1;
  endfunction

  protected function bit parse_uint_str(string raw, output int unsigned value);
    longint unsigned parsed;
    if (raw.len() == 0)
      return 1'b0;
    parsed = 0;
    for (int i = 0; i < raw.len(); i++) begin
      if (raw.getc(i) < 8'h30 || raw.getc(i) > 8'h39)
        return 1'b0;
      parsed = parsed * 10 + (raw.getc(i) - 8'h30);
      if (parsed > 64'hFFFF_FFFF)
        return 1'b0;
    end
    value = int'(parsed);
    return 1'b1;
  endfunction

  function void apply_plusargs();
    uvm_cmdline_processor cli;
    string all_args[$];
    int unsigned value;
    bit has_seed_arg;
    has_seed_arg = 1'b0;
    cli          = uvm_cmdline_processor::get_inst();

    if ($test$plusargs("QSPI_NO_COV")) begin
      enable_apb_cov  = 0;
      enable_flow_cov = 0;
      enable_reg_cov  = 0;
      enable_irq_cov  = 0;
      enable_dma_cov  = 0;
      enable_xip_cov  = 0;
    end
    if (get_uint_arg("+XIP_ALLOW_UNALIGNED_CHAR=", value))
      xip_allow_unaligned_char = (value != 0);
    if (get_uint_arg("+QSPI_ENFORCE_XIP_MAX_OS=", value))
      enforce_xip_max_os = (value != 0);
    if (get_uint_arg("+QSPI_XIP_MAX_OUTSTANDING=", value))
      xip_max_outstanding = value;
    if (get_uint_arg("+QSPI_SEED=", value)) begin
      has_seed_arg = 1'b1;
      active_seed  = value;
    end
    if (!has_seed_arg) begin
      string vals[$];
      if (cli.get_arg_values("+ntb_random_seed=", vals) > 0 &&
          parse_uint_str(vals[0], value)) begin
        has_seed_arg = 1'b1;
        active_seed  = value;
      end else if (cli.get_arg_values("+sv_seed=", vals) > 0 &&
                   parse_uint_str(vals[0], value)) begin
        has_seed_arg = 1'b1;
        active_seed  = value;
      end else begin
        cli.get_args(all_args);
        foreach (all_args[i]) begin
          if ((all_args[i] == "-svseed" || all_args[i] == "-sv_seed") &&
              (i + 1 < all_args.size()) && parse_uint_str(all_args[i + 1], value)) begin
            has_seed_arg = 1'b1;
            active_seed  = value;
            break;
          end
        end
      end
    end
    if (!has_seed_arg)
      active_seed = 0;

    if (get_uint_arg("+QSPI_TIMEOUT_CYCLES=", value))
      timeout_cycles = value;
    if (get_uint_arg("+QSPI_TRANSACTION_TIMEOUT_CYCLES=", value))
      transaction_timeout_cycles = value;
    if (get_uint_arg("+QSPI_APB_TIMEOUT_CYCLES=", value) && apb_cfg_h != null)
      apb_cfg_h.max_wait_cycles = value;
  endfunction

  virtual function string policy_summary();
    return $sformatf(
      "spec_blind=1 unaligned_char=%0b enforce_max_os=%0b max_os=%0d seed=%0d",
      xip_allow_unaligned_char, enforce_xip_max_os, xip_max_outstanding, active_seed);
  endfunction

  function void validate();
    if (apb_cfg_h == null || flash_cfg_h == null)
      `uvm_fatal("QSPI_ENV_CFG", "Agent configuration handle is null")
    if (clk_vif == null)
      `uvm_fatal("QSPI_ENV_CFG", "Missing clock/reset/IRQ interface")
    if (reset_request == null)
      `uvm_fatal("QSPI_ENV_CFG", "Missing testbench reset service event")
    if (timeout_cycles == 0)
      `uvm_fatal("QSPI_ENV_CFG", "QSPI_TIMEOUT_CYCLES must be greater than zero")
    if (transaction_timeout_cycles == 0)
      `uvm_fatal("QSPI_ENV_CFG", "QSPI_TRANSACTION_TIMEOUT_CYCLES must be greater than zero")
    apb_cfg_h.validate(get_full_name());
    if (flash_vif == null)
      `uvm_fatal("QSPI_ENV_CFG", "Missing QSPI pin interface")
    if (flash_cfg_h.cmd_lanes == 3 || flash_cfg_h.addr_lanes == 3 ||
        flash_cfg_h.data_lanes == 3 || flash_cfg_h.addr_bytes == 3)
      `uvm_fatal("QSPI_ENV_CFG", "Reserved QSPI lane/address encoding")
    if ((enable_flow_sb || enable_flow_cov || enable_sclk_chk) && !enable_flash_agent)
      `uvm_fatal("QSPI_ENV_CFG", "Flow/SCLK checks or coverage require enable_flash_agent=1")
    if (enable_flow_cov && !enable_flow_sb)
      `uvm_fatal("QSPI_ENV_CFG", "enable_flow_cov=1 requires enable_flow_sb=1")
    if (enable_dma_agent || enable_dma_sb || enable_dma_cov) begin
      if (!enable_dma_agent)
        `uvm_fatal("QSPI_ENV_CFG", "DMA scoreboard/coverage require enable_dma_agent=1")
      if (axi_cfg_h == null)
        `uvm_fatal("QSPI_ENV_CFG", "axi_cfg_h handle is null")
      if (axi_vif == null && axi_cfg_h.axi_vif != null)
        axi_vif = axi_cfg_h.axi_vif;
      else if (axi_cfg_h.axi_vif == null && axi_vif != null)
        axi_cfg_h.axi_vif = axi_vif;
      if (axi_cfg_h.clk_vif == null)
        axi_cfg_h.clk_vif = clk_vif;
      axi_cfg_h.validate(get_full_name());
    end
    if (enable_axil_agent || enable_xip_sb || enable_xip_cov) begin
      if (axil_cfg_h == null)
        `uvm_fatal("QSPI_ENV_CFG", "axil_cfg_h handle is null")
      if (axil_vif == null && axil_cfg_h.vif != null)
        axil_vif = axil_cfg_h.vif;
      else if (axil_cfg_h.vif == null && axil_vif != null)
        axil_cfg_h.vif = axil_vif;
      else if (axil_vif != axil_cfg_h.vif)
        `uvm_fatal("QSPI_ENV_CFG", "Inconsistent axil_vif and axil_cfg_h.vif bindings")
      axil_cfg_h.validate(get_full_name());
      if (timeout_cycles < axil_cfg_h.default_rvalid_timeout_cycles ||
          timeout_cycles < axil_cfg_h.default_completion_timeout_cycles) begin
        `uvm_warning("QSPI_ENV_CFG", $sformatf(
          "timeout_cycles (%0d) < AXI-Lite budgets (rvalid=%0d, completion=%0d); high-DIV/SLVERR XIP tests (DIV=7 error ~%0d ACLK) must raise +QSPI_TIMEOUT_CYCLES",
          timeout_cycles, axil_cfg_h.default_rvalid_timeout_cycles,
          axil_cfg_h.default_completion_timeout_cycles,
          qspi_compute_xip_budget(7, 75, 1'b1)))
      end
    end
    if ((enable_xip_sb || enable_xip_cov) && (!enable_axil_agent || !enable_flash_agent))
      `uvm_fatal("QSPI_ENV_CFG", "XIP scoreboard/coverage require enable_axil_agent=1 and enable_flash_agent=1")
  endfunction

  static function void install(uvm_component owner, qspi_env_cfg cfg,
                               uvm_component target);
    if (owner == null || target == null || cfg == null)
      `uvm_fatal("QSPI_CFG_BIND", "install requires owner, cfg and target")
    // Missing interfaces remain null for the single validation pass in env build.
    if (cfg.apb_cfg_h != null)
      void'(uvm_config_db #(qspi_apb_vif_t)::get(
        owner, "", "apb_vif", cfg.apb_cfg_h.apb_vif));
    void'(uvm_config_db #(virtual clk_rst_irq_if)::get(
      owner, "", "clk_vif", cfg.clk_vif));
    void'(uvm_config_db #(uvm_event)::get(
      owner, "", "reset_request", cfg.reset_request));
    if (cfg.flash_cfg_h != null)
      void'(uvm_config_db #(virtual qspi_if)::get(
        owner, "", "flash_vif", cfg.flash_vif));
    if (cfg.flash_cfg_h != null)
      uvm_config_db #(virtual qspi_if)::set(
        target, "flash_agt*", "qspi_vif", cfg.flash_vif);
    void'(uvm_config_db #(virtual axi_if)::get(
      owner, "", "axi_vif", cfg.axi_vif));
    if (cfg.axi_cfg_h != null) begin
      if (cfg.axi_cfg_h.axi_vif == null)
        cfg.axi_cfg_h.axi_vif = cfg.axi_vif;
      if (cfg.axi_cfg_h.clk_vif == null)
        cfg.axi_cfg_h.clk_vif = cfg.clk_vif;
    end
    if (cfg.axil_cfg_h != null && cfg.axil_cfg_h.vif != null) begin
      if (cfg.axil_vif == null)
        cfg.axil_vif = cfg.axil_cfg_h.vif;
    end else begin
      void'(uvm_config_db #(virtual axil_if)::get(
        owner, "", "axil_vif", cfg.axil_vif));
      if (cfg.axil_cfg_h != null && cfg.axil_cfg_h.vif == null)
        cfg.axil_cfg_h.vif = cfg.axil_vif;
    end
    uvm_config_db #(qspi_env_cfg)::set(target, "", "cfg", cfg);
  endfunction

  virtual function string convert2string();
    string description;
    description = $sformatf(
      "checks: APB=%0b FLOW=%0b DMA=%0b XIP=%0b SCLK=%0b STATUS=%0b CONTRACT=%0b; coverage: APB=%0b FLOW=%0b REG=%0b IRQ=%0b DMA=%0b XIP=%0b; flash_agent=%0b dma_agent=%0b axil_agent=%0b; policy: [%s]; timeout=%0d transaction_timeout=%0d CLK cycles\n  APB: %s",
      enable_apb_sb, enable_flow_sb, enable_dma_sb, enable_xip_sb, enable_sclk_chk, enable_status_chk, enable_apb_contract,
      enable_apb_cov, enable_flow_cov, enable_reg_cov, enable_irq_cov, enable_dma_cov, enable_xip_cov,
      enable_flash_agent, enable_dma_agent, enable_axil_agent,
      policy_summary(), timeout_cycles, transaction_timeout_cycles,
      apb_cfg_h.convert2string());
    if (enable_dma_agent && axi_cfg_h != null)
      description = {description, "\n  AXI4: ", axi_cfg_h.convert2string()};
    if (enable_axil_agent && axil_cfg_h != null)
      description = {description, "\n  AXIL: ", axil_cfg_h.convert2string()};
    return description;
  endfunction
endclass : qspi_env_cfg
`endif
