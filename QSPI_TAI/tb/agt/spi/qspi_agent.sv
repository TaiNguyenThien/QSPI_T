`ifndef QSPI_AGENT_SV
`define QSPI_AGENT_SV

class qspi_agent extends uvm_agent;
  `uvm_component_utils(qspi_agent)

  qspi_cfg          cfg;
  qspi_monitor      monitor;
  qspi_flash_slave  flash_slave;
  string            my_name;

  // Analysis ports according to DMA Verification Architecture:
  // exp_ap: Expected transaction from Flash Slave Responder (DIR=1)
  // act_ap: Actual transaction captured by Monitor from physical bus (DIR=0)
  uvm_analysis_port #(qspi_transaction) exp_ap;
  uvm_analysis_port #(qspi_transaction) act_ap;

  function new(string name = "qspi_agent", uvm_component parent = null);
    super.new(name, parent);
    my_name = name;
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (!uvm_config_db #(qspi_cfg)::get(this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal("QSPI_AGENT_CFG", "Missing qspi_cfg configuration object")
    
    is_active = cfg.is_active;
    uvm_config_db #(qspi_cfg)::set(this, "*", "cfg", cfg);

    monitor = qspi_monitor::type_id::create("monitor", this);
    if (get_is_active() == UVM_ACTIVE) begin
      flash_slave = qspi_flash_slave::type_id::create("flash_slave", this);
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // Bind monitor port to agent actual port (Backward compatible with ref_port)
    act_ap = monitor.ref_port;
    if (get_is_active() == UVM_ACTIVE && flash_slave != null) begin
      exp_ap = flash_slave.exp_ap;
    end
  endfunction
endclass : qspi_agent

`endif