`ifndef AXI_SLAVE_CFG_SV
`define AXI_SLAVE_CFG_SV

class axi_slave_cfg extends uvm_object;
  `uvm_object_utils(axi_slave_cfg)

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  virtual axi_if          axi_vif;
  virtual clk_rst_irq_if  clk_vif;

  // Encapsulated slave response & protocol delay policy knobs
  bit [1:0]    default_bresp      = 2'b00; // 2'b00: OKAY, 2'b10: SLVERR, 2'b11: DECERR
  bit [1:0]    default_rresp      = 2'b00;
  int unsigned awready_delay_knob = 0;
  int unsigned wready_delay_knob  = 0;
  int unsigned arready_delay_knob = 0;
  int unsigned bvalid_delay_knob  = 0;
  int unsigned rvalid_delay_knob  = 0;
  int          inject_error_beat  = -1;    // -1: all beats use default, >=0: inject on beat

  function new(string name = "axi_slave_cfg");
    super.new(name);
  endfunction

  function void reset_knobs();
    default_bresp      = 2'b00;
    default_rresp      = 2'b00;
    awready_delay_knob = 0;
    wready_delay_knob  = 0;
    arready_delay_knob = 0;
    bvalid_delay_knob  = 0;
    rvalid_delay_knob  = 0;
    inject_error_beat  = -1;
  endfunction

  function void validate(string ctx = "axi_slave_cfg");
    if (axi_vif == null)
      `uvm_fatal("AXI_CFG", $sformatf("%s: missing axi_vif binding", ctx))
    if (clk_vif == null)
      `uvm_fatal("AXI_CFG", $sformatf("%s: missing clk_vif binding", ctx))
  endfunction

  function string convert2string();
    return $sformatf(
      "active=%s bresp=%02b rresp=%02b err_beat=%0d delays(aw=%0d w=%0d ar=%0d b=%0d r=%0d)",
      is_active.name(), default_bresp, default_rresp, inject_error_beat,
      awready_delay_knob, wready_delay_knob, arready_delay_knob,
      bvalid_delay_knob, rvalid_delay_knob);
  endfunction
endclass : axi_slave_cfg

`endif // AXI_SLAVE_CFG_SV
