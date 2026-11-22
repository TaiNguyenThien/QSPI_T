// Configuration shared by the agent and its components; no QSPI CSR policy.
class apb_cfg #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_object;
  `uvm_object_param_utils(apb_cfg #(ADDR_WIDTH, DATA_WIDTH))

  virtual apb_if #(ADDR_WIDTH, DATA_WIDTH) apb_vif;

  uvm_active_passive_enum is_active = UVM_ACTIVE;

  // The next item must already be available for a zero-IDLE transfer.
  bit enable_back_to_back = 1'b1;
  int unsigned inter_transfer_idle_cycles = 0;

  // Testbench watchdog, not an APB protocol timing limit. 0 disables it.
  int unsigned max_wait_cycles = 1000;

  // Monitor-only controls; the external SVA checker is independent.
  bit checks_enable = 1'b1;
  bit check_read_data_known = 1'b0;

  function new(string name = "apb_cfg");
    super.new(name);
  endfunction

  virtual function void validate(string owner = "apb_agent");
    if (!(is_active inside {UVM_ACTIVE, UVM_PASSIVE}))
      `uvm_fatal("APB_CFG", {owner, ": invalid activity mode"})
    if (ADDR_WIDTH == 0 || !(DATA_WIDTH inside {8, 16, 32}))
      `uvm_fatal("APB_CFG", $sformatf(
        "%s: invalid widths ADDR_WIDTH=%0d DATA_WIDTH=%0d",
        owner, ADDR_WIDTH, DATA_WIDTH))
    if (apb_vif == null)
      `uvm_fatal("APB_CFG", $sformatf("%s: apb_vif is null", owner))
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "APB AW=%0d DW=%0d mode=%s b2b=%0b idle=%0d wait_limit=%0d checks=%0b known_rdata=%0b",
      ADDR_WIDTH, DATA_WIDTH, is_active.name(), enable_back_to_back,
      inter_transfer_idle_cycles, max_wait_cycles,
      checks_enable, check_read_data_known);
  endfunction
endclass
