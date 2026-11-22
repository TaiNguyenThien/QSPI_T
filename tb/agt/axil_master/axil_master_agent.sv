// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_master_agent.sv
// Role   : AXI4-Lite Master Agent
// =============================================================================

`ifndef AXIL_MASTER_AGENT_SV
`define AXIL_MASTER_AGENT_SV

class axil_master_agent extends uvm_agent;
  `uvm_component_utils(axil_master_agent)

  axil_master_cfg       cfg;
  axil_master_driver    driver;
  axil_master_sequencer sequencer;
  axil_master_monitor   monitor;

  function new(string name = "axil_master_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(axil_master_cfg)::get(this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal("AXIL_AGENT_CFG", "Missing axil_master_cfg configuration object")

    cfg.validate(get_full_name());
    is_active = cfg.is_active;

    // Monitor is always instantiated in both active and passive modes
    monitor = axil_master_monitor::type_id::create("monitor", this);
    monitor.cfg = cfg;

    if (is_active == UVM_ACTIVE) begin
      sequencer = axil_master_sequencer::type_id::create("sequencer", this);
      driver    = axil_master_driver::type_id::create("driver", this);
      driver.cfg = cfg;
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE) begin
      driver.seq_item_port.connect(sequencer.seq_item_export);
    end
  endfunction

endclass : axil_master_agent

`endif // AXIL_MASTER_AGENT_SV
