// The monitor is always present; driver and sequencer exist only in ACTIVE mode.
class apb_agent #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_agent;
  `uvm_component_param_utils(apb_agent #(ADDR_WIDTH, DATA_WIDTH))

  typedef apb_cfg #(ADDR_WIDTH, DATA_WIDTH) cfg_t;

  cfg_t cfg;
  apb_sequencer #(ADDR_WIDTH, DATA_WIDTH) sequencer;
  apb_driver #(ADDR_WIDTH, DATA_WIDTH) driver;
  apb_monitor #(ADDR_WIDTH, DATA_WIDTH) monitor;

  function new(string name = "apb_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(cfg_t)::get(this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal("APB_AGENT", "Missing apb_cfg (config_db key: cfg)")
    cfg.validate(get_full_name());
    is_active = cfg.is_active;

    monitor = apb_monitor #(ADDR_WIDTH, DATA_WIDTH)::type_id::create(
      "monitor", this);
    monitor.cfg = cfg;

    if (is_active == UVM_ACTIVE) begin
      sequencer = apb_sequencer #(ADDR_WIDTH, DATA_WIDTH)::type_id::create(
        "sequencer", this);
      driver = apb_driver #(ADDR_WIDTH, DATA_WIDTH)::type_id::create(
        "driver", this);
      driver.cfg = cfg;
    end
  endfunction

  virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (is_active == UVM_ACTIVE)
      driver.seq_item_port.connect(sequencer.seq_item_export);
  endfunction
endclass
