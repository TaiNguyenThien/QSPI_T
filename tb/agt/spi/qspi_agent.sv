`ifndef QSPI_AGENT_SV
`define QSPI_AGENT_SV

class qspi_agent extends uvm_agent;
  `uvm_component_utils(qspi_agent)

  qspi_cfg         cfg;
  qspi_monitor     monitor;
  qspi_flash_slave flash_slave;

  function new(string name = "qspi_agent", uvm_component parent = null);
    super.new(name, parent);
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
endclass : qspi_agent

`endif
