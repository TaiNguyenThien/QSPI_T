`ifndef QSPI_ENV_SV
`define QSPI_ENV_SV

class qspi_env extends uvm_env;
  `uvm_component_utils(qspi_env)
  qspi_env_cfg cfg;
  qspi_vsequencer virtual_seqr;
  qspi_apb_agent_t apb_agt;
  qspi_agent flash_agt;
  qspi_flash_profile_sync flash_profile_sync;
  qspi_reg_block ral_model;
  qspi_apb_reg_adapter ral_adapter;
  qspi_apb_reg_predictor ral_predictor;
  qspi_apb_cov apb_cov;
  qspi_pio_cov pio_cov;
  qspi_spi_cov spi_cov;
  qspi_reg_cov reg_cov;
  qspi_irq_cov irq_cov;
  qspi_apb_csr_sb apb_sb;
  qspi_apb_contract_chk apb_contract;
  qspi_flow_sb flow_sb;
  qspi_sclk_timing_chk sclk_chk;
  qspi_status_chk status_chk;
  axi_slave_agent axi_agt;
  qspi_dma_sb dma_sb;
  qspi_dma_cov dma_cov;
  axil_master_agent axil_agt;
  qspi_xip_sb xip_sb;
  qspi_xip_cov xip_cov;
  qspi_tb_mem_service mem_svc;

  function new(string name = "qspi_env", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(qspi_env_cfg)::get(this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal("QSPI_ENV_BIND", "Missing qspi_env_cfg binding")
    cfg.apply_plusargs();
    cfg.validate();
    `uvm_info("QSPI_ENV_CFG", cfg.convert2string(), UVM_HIGH)

    // Each reusable agent receives only its own configuration object.
    uvm_config_db #(qspi_apb_cfg_t)::set(this, "apb_agt", "cfg", cfg.apb_cfg_h);
    uvm_config_db #(qspi_agent_pkg::qspi_cfg)::set(this, "flash_agt", "cfg", cfg.flash_cfg_h);
    apb_agt = qspi_apb_agent_t::type_id::create("apb_agt", this);
    if (cfg.enable_flash_agent) begin
      flash_agt = qspi_agent::type_id::create("flash_agt", this);
      flash_profile_sync = qspi_flash_profile_sync::type_id::create("flash_profile_sync", this);
      flash_profile_sync.cfg = cfg;
    end
    virtual_seqr = qspi_vsequencer::type_id::create("virtual_seqr", this);
    virtual_seqr.cfg = cfg;

    if (cfg.enable_apb_cov) begin
      apb_cov = qspi_apb_cov::type_id::create("apb_cov", this);
      apb_cov.cfg = cfg;
    end
    if (cfg.enable_flow_cov) begin
      pio_cov = qspi_pio_cov::type_id::create("pio_cov", this);
      spi_cov = qspi_spi_cov::type_id::create("spi_cov", this);
      pio_cov.cfg = cfg;
      spi_cov.cfg = cfg;
    end
    if (cfg.enable_reg_cov) begin
      reg_cov = qspi_reg_cov::type_id::create("reg_cov", this);
      reg_cov.cfg = cfg;
    end
    if (cfg.enable_irq_cov) begin
      irq_cov = qspi_irq_cov::type_id::create("irq_cov", this);
      irq_cov.cfg = cfg;
    end
    if (cfg.enable_apb_contract) begin
      apb_contract = qspi_apb_contract_chk::type_id::create("apb_contract", this);
      apb_contract.cfg = cfg;
    end
    if (cfg.enable_apb_sb) begin
      apb_sb = qspi_apb_csr_sb::type_id::create("apb_sb", this);
      apb_sb.cfg = cfg;
    end
    if (cfg.enable_status_chk) begin
      status_chk = qspi_status_chk::type_id::create("status_chk", this);
      status_chk.cfg = cfg;
    end
    if (cfg.enable_flow_sb) begin
      flow_sb = qspi_flow_sb::type_id::create("flow_sb", this);
      flow_sb.cfg = cfg;
    end
    if (cfg.enable_sclk_chk) begin
      sclk_chk = qspi_sclk_timing_chk::type_id::create("sclk_chk", this);
      sclk_chk.cfg = cfg;
    end
    if (cfg.enable_dma_agent) begin
      uvm_config_db #(axi_slave_cfg)::set(this, "axi_agt", "cfg", cfg.axi_cfg_h);
      axi_agt = axi_slave_agent::type_id::create("axi_agt", this);
    end
    if (cfg.enable_dma_sb) begin
      dma_sb = qspi_dma_sb::type_id::create("dma_sb", this);
      dma_sb.cfg = cfg;
    end
    if (cfg.enable_dma_cov) begin
      dma_cov = qspi_dma_cov::type_id::create("dma_cov", this);
      dma_cov.cfg = cfg;
    end
    if (cfg.enable_axil_agent) begin
      uvm_config_db #(axil_master_cfg)::set(this, "axil_agt", "cfg", cfg.axil_cfg_h);
      axil_agt = axil_master_agent::type_id::create("axil_agt", this);
    end
    if (cfg.enable_xip_sb) begin
      xip_sb = qspi_xip_sb::type_id::create("xip_sb", this);
      xip_sb.cfg = cfg;
    end
    if (cfg.enable_xip_cov) begin
      xip_cov = qspi_xip_cov::type_id::create("xip_cov", this);
      xip_cov.cfg = cfg;
    end
    ral_model = qspi_reg_block::type_id::create("ral_model");
    ral_model.build();
    virtual_seqr.ral_model = ral_model;
    ral_adapter = qspi_apb_reg_adapter::type_id::create("ral_adapter");
    ral_predictor = qspi_apb_reg_predictor::type_id::create("ral_predictor", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    virtual_seqr.apb_seqr = apb_agt.sequencer;
    if (flash_profile_sync != null) begin
      apb_agt.monitor.ap.connect(flash_profile_sync.apb_imp);
      if (axil_agt != null)
        axil_agt.monitor.ar_ap.connect(flash_profile_sync.axil_ar_imp);
    end
    if (axi_agt != null) begin
      if (dma_sb != null) begin
        axi_agt.monitor.item_collected_port.connect(dma_sb.axi_export);
        axi_agt.monitor.resp_ap.connect(dma_sb.axi_resp_export);
      end
      if (dma_cov != null) begin
        axi_agt.monitor.item_collected_port.connect(dma_cov.axi_export);
        axi_agt.monitor.resp_ap.connect(dma_cov.axi_resp_export);
      end
      if (xip_sb != null)
        axi_agt.monitor.item_collected_port.connect(xip_sb.dma_axi_export);
    end
    if (dma_sb != null) begin
      apb_agt.monitor.ap.connect(dma_sb.apb_export);
      if (flash_agt != null)
        flash_agt.monitor.ref_port.connect(dma_sb.spi_export);
    end
    if (dma_cov != null) begin
      apb_agt.monitor.ap.connect(dma_cov.apb_export);
    end
    if (axil_agt != null) begin
      virtual_seqr.axil_seqr = axil_agt.sequencer;
    end
    if (xip_sb != null) begin
      if (axil_agt != null) begin
        axil_agt.monitor.ar_ap.connect(xip_sb.axil_ar_export);
        axil_agt.monitor.ap.connect(xip_sb.axil_r_export);
      end
      apb_agt.monitor.ap.connect(xip_sb.apb_export);
      if (flash_agt != null)
        flash_agt.monitor.ref_port.connect(xip_sb.spi_export);
    end
    if (xip_cov != null) begin
      if (axil_agt != null) begin
        axil_agt.monitor.ar_ap.connect(xip_cov.axil_ar_export);
        axil_agt.monitor.ap.connect(xip_cov.axil_r_export);
        axil_agt.monitor.unacc_ap.connect(xip_cov.axil_r_export);
      end
      apb_agt.monitor.ap.connect(xip_cov.apb_export);
      if (flash_agt != null)
        flash_agt.monitor.ref_port.connect(xip_cov.spi_export);
    end
    if (apb_contract != null) begin
      apb_agt.monitor.ap.connect(apb_contract.monitor_imp);
      if (apb_agt.driver != null)
        apb_agt.driver.completed_ap.connect(apb_contract.driver_imp);
    end
    if (sclk_chk != null) begin
      apb_agt.monitor.ap.connect(sclk_chk.apb_imp);
      if (flash_agt != null)
        flash_agt.monitor.ref_port.connect(sclk_chk.spi_imp);
    end
    if (apb_cov != null) apb_agt.monitor.ap.connect(apb_cov.analysis_export);
    if (apb_sb != null) apb_agt.monitor.ap.connect(apb_sb.apb_imp);
    if (status_chk != null) begin
      apb_agt.monitor.ap.connect(status_chk.apb_imp);
      if (flash_agt != null)
        flash_agt.monitor.ref_port.connect(status_chk.spi_imp);
    end
    if (flow_sb != null) begin
      virtual_seqr.cmd_intent_ap.connect(flow_sb.cmd_intent_fifo.analysis_export);
      apb_agt.monitor.ap.connect(flow_sb.apb_fifo.analysis_export);
      if (flash_agt != null)
        flash_agt.monitor.ref_port.connect(flow_sb.agent_serial_fifo.analysis_export);
      if (axil_agt != null) begin
        axil_agt.monitor.ar_ap.connect(flow_sb.xip_ar_fifo.analysis_export);
        axil_agt.monitor.ap.connect(flow_sb.xip_r_fifo.analysis_export);
      end
    end
    // Independent subscribers; no coverage router or shared mutable sample.
    if (pio_cov != null && flow_sb != null)
      flow_sb.pio_result_ap.connect(pio_cov.analysis_export);
    if (reg_cov != null) apb_agt.monitor.ap.connect(reg_cov.analysis_export);
    if (irq_cov != null) apb_agt.monitor.ap.connect(irq_cov.analysis_export);
    if (spi_cov != null && flash_agt != null)
      flash_agt.monitor.ref_port.connect(spi_cov.analysis_export);
    ral_model.default_map.set_auto_predict(0);
    // Passive DUT checkers own functional expectations, including volatile CSRs.
    ral_model.default_map.set_check_on_read(0);
    if (apb_agt.sequencer != null)
      ral_model.default_map.set_sequencer(apb_agt.sequencer, ral_adapter);
    ral_predictor.map     = ral_model.default_map;
    ral_predictor.adapter = ral_adapter;
    apb_agt.monitor.ap.connect(ral_predictor.bus_in);

    // Build and bind abstract memory & responder service for sequences.
    mem_svc              = qspi_tb_mem_service::type_id::create("mem_svc");
    mem_svc.cfg          = cfg;
    mem_svc.flash_slave  = (flash_agt != null) ? flash_agt.flash_slave : null;
    mem_svc.axi_drv      = (axi_agt != null)   ? axi_agt.driver        : null;
    mem_svc.axi_cfg      = cfg.axi_cfg_h;
    mem_svc.xip_sb       = xip_sb;
    virtual_seqr.mem_svc = mem_svc;
  endfunction

  task run_phase(uvm_phase phase);
    ral_model.reset();
    fork
      forever begin
        @(negedge cfg.clk_vif.rst_n);
        ral_model.reset();
      end
      begin
        repeat (cfg.timeout_cycles) @(posedge cfg.clk_vif.clk);
        `uvm_fatal("QSPI_ENV_TIMEOUT", $sformatf(
          "Environment exceeded %0d CLK cycles", cfg.timeout_cycles))
      end
    join
  endtask
endclass : qspi_env
`endif
