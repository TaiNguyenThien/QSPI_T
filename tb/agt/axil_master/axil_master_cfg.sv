// =============================================================================
// Project: Generic Reusable VIP (Read-Only AXI4-Lite Master Agent)
// File   : axil_master_cfg.sv
// Role   : Project-agnostic configuration object for AXI4-Lite Master VIP
// Spec   : ARM AMBA AXI4-Lite Protocol (Read-Only Master capability)
// =============================================================================

`ifndef AXIL_MASTER_CFG_SV
`define AXIL_MASTER_CFG_SV

class axil_master_cfg extends uvm_object;
  `uvm_object_utils(axil_master_cfg)

  virtual axil_if         vif;
  uvm_active_passive_enum is_active                          = UVM_ACTIVE;

  // --- Generic Multi-Tiered Timeout Budgets (in ACLK cycles) ---
  longint unsigned        default_ar_timeout_cycles          = 10000;
  longint unsigned        default_rvalid_timeout_cycles      = 25000;
  longint unsigned        default_completion_timeout_cycles  = 350000;

  function new(string name = "axil_master_cfg");
    super.new(name);
  endfunction

  virtual function void validate(string owner = "axil_master_agent");
    if (vif == null)
      `uvm_fatal("AXIL_CFG", {owner, ": missing AXI4-Lite virtual interface (vif)"})
    if (!(is_active inside {UVM_ACTIVE, UVM_PASSIVE}))
      `uvm_fatal("AXIL_CFG", {owner, ": invalid activity mode"})
  endfunction

  // Protocol-generic helper: apply caller-computed timeout overrides to a transaction
  function void apply_timeout_budget(
    axil_master_transaction trans,
    longint unsigned        ar_budget,
    longint unsigned        rvalid_budget,
    longint unsigned        completion_budget
  );
    if (trans == null) return;
    trans.has_timeout_override         = 1'b1;
    trans.ar_timeout_override          = (ar_budget > default_ar_timeout_cycles) ? ar_budget : default_ar_timeout_cycles;
    trans.rvalid_timeout_override      = rvalid_budget;
    trans.completion_timeout_override  = completion_budget;
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "mode=%s ar_timeout=%0d rvalid_timeout=%0d completion_timeout=%0d",
      is_active.name(), default_ar_timeout_cycles, default_rvalid_timeout_cycles,
      default_completion_timeout_cycles);
  endfunction

endclass : axil_master_cfg

`endif // AXIL_MASTER_CFG_SV
