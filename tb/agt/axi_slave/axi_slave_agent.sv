`ifndef AXI_SLAVE_AGENT_SV
`define AXI_SLAVE_AGENT_SV

class axi_slave_agent extends uvm_agent;
  `uvm_component_utils(axi_slave_agent)

  axi_slave_cfg          cfg;
  virtual axi_if         axi_vif;
  virtual clk_rst_irq_if clk_vif;

  axi_slave_driver  driver;
  axi_slave_monitor monitor;

  function new(string name = "axi_slave_agent", uvm_component parent = null);
    super.new(name, parent);
  endfunction : new

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);

    if (!uvm_config_db #(axi_slave_cfg)::get(this, "", "cfg", cfg) || cfg == null) begin
      cfg = axi_slave_cfg::type_id::create("cfg");
      cfg.is_active = get_is_active();
    end
    if (cfg.axi_vif == null)
      void'(uvm_config_db #(virtual axi_if)::get(this, "", "axi_vif", cfg.axi_vif));
    if (cfg.clk_vif == null)
      void'(uvm_config_db #(virtual clk_rst_irq_if)::get(this, "", "clk_vif", cfg.clk_vif));

    cfg.validate(get_full_name());
    axi_vif   = cfg.axi_vif;
    clk_vif   = cfg.clk_vif;
    is_active = cfg.is_active;

    monitor = axi_slave_monitor::type_id::create("monitor", this);
    monitor.cfg     = cfg;
    monitor.axi_vif = axi_vif;
    monitor.clk_vif = clk_vif;

    if (get_is_active() == UVM_ACTIVE) begin
      driver = axi_slave_driver::type_id::create("driver", this);
      driver.cfg     = cfg;
      driver.axi_vif = axi_vif;
      driver.clk_vif = clk_vif;
    end
  endfunction : build_phase

endclass : axi_slave_agent

`endif // AXI_SLAVE_AGENT_SV
