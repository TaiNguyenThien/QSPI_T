`ifndef QSPI_SHARED_ITEMS_SV
`define QSPI_SHARED_ITEMS_SV

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_shared_items.sv
// Role   : Neutral cross-layer TLM contract items shared across seq/chk/cov
//          (Breaks reverse package dependency qspi_vseq_pkg/qspi_cov_pkg -> qspi_chk_pkg)
// =============================================================================

// Immutable summary published after a PIO command's flow checks complete.
class qspi_pio_result_item extends uvm_sequence_item;
  `uvm_object_utils(qspi_pio_result_item)
  longint unsigned issue_order;
  bit success, checked_ok;
  bit [7:0] opcode;
  bit cpol, cpha, read_direction;
  bit [2:0] clk_div;
  int unsigned length, addr_bytes, data_lanes;
  int unsigned cmd_lanes, addr_lanes, mode_lanes, dummy_base, dummy_extra, dummy_total;
  bit use_lut, mode_enable;
  bit [1:0] lut_index;
  bit [1:0] cs_delay;
  bit [7:0] mode_value;

  function new(string name = "qspi_pio_result_item");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    qspi_pio_result_item other;
    if (!$cast(other, rhs)) begin
      `uvm_fatal("QSPI_PIO_RESULT_COPY", "Incompatible result item")
      return;
    end
    super.do_copy(rhs);
    issue_order    = other.issue_order;
    success        = other.success;
    checked_ok     = other.checked_ok;
    opcode         = other.opcode;
    cpol           = other.cpol;
    cpha           = other.cpha;
    read_direction = other.read_direction;
    clk_div        = other.clk_div;
    length         = other.length;
    addr_bytes     = other.addr_bytes;
    data_lanes     = other.data_lanes;
    cmd_lanes      = other.cmd_lanes;
    addr_lanes     = other.addr_lanes;
    mode_lanes     = other.mode_lanes;
    dummy_base     = other.dummy_base;
    dummy_extra    = other.dummy_extra;
    dummy_total    = other.dummy_total;
    use_lut        = other.use_lut;
    lut_index      = other.lut_index;
    cs_delay       = other.cs_delay;
    mode_enable    = other.mode_enable;
    mode_value     = other.mode_value;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    qspi_pio_result_item other;
    if (!$cast(other, rhs)) return 0;
    return super.do_compare(rhs, comparer) &&
      issue_order    == other.issue_order &&
      success        == other.success &&
      checked_ok     == other.checked_ok &&
      opcode         == other.opcode &&
      cpol           == other.cpol &&
      cpha           == other.cpha &&
      read_direction == other.read_direction &&
      clk_div        == other.clk_div &&
      length         == other.length &&
      addr_bytes     == other.addr_bytes &&
      data_lanes     == other.data_lanes &&
      cmd_lanes      == other.cmd_lanes &&
      addr_lanes     == other.addr_lanes &&
      mode_lanes     == other.mode_lanes &&
      dummy_base     == other.dummy_base &&
      dummy_extra    == other.dummy_extra &&
      dummy_total    == other.dummy_total &&
      use_lut        == other.use_lut &&
      lut_index      == other.lut_index &&
      cs_delay       == other.cs_delay &&
      mode_enable    == other.mode_enable &&
      mode_value     == other.mode_value;
  endfunction

  virtual function string convert2string();
    return $sformatf("command=%0d success=%0b flow_checks_ok=%0b",
                     issue_order, success, checked_ok);
  endfunction
endclass : qspi_pio_result_item

// Stimulus intent passed from PIO virtual sequences to flow scoreboard via TLM.
class qspi_cmd_intent extends uvm_sequence_item;
  `uvm_object_utils(qspi_cmd_intent)
  bit expect_error;
  bit [2:0] required_err_bits;
  bit [2:0] any_err_bits;
  bit allow_no_serial;
  byte unsigned flash_bytes[$];

  function new(string name = "qspi_cmd_intent");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    qspi_cmd_intent other;
    if (!$cast(other, rhs)) return;
    super.do_copy(rhs);
    expect_error      = other.expect_error;
    required_err_bits = other.required_err_bits;
    any_err_bits      = other.any_err_bits;
    allow_no_serial   = other.allow_no_serial;
    flash_bytes       = other.flash_bytes;
  endfunction
endclass : qspi_cmd_intent

`endif // QSPI_SHARED_ITEMS_SV
