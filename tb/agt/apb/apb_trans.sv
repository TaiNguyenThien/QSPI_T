// One APB transfer: randomized request fields and sampled result fields.
class apb_trans #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_sequence_item;
  localparam int unsigned STRB_WIDTH = DATA_WIDTH / 8;

  // REQUEST. logic preserves X/Z values when this type is populated by the
  // monitor, while normal sequence randomization still produces 0/1 values.
  rand logic                  write;
  rand logic [ADDR_WIDTH-1:0] addr;
  rand logic [DATA_WIDTH-1:0] wdata;
  rand logic [STRB_WIDTH-1:0] strb;
  rand logic [2:0]            prot;
  rand int unsigned          idle_cycles = 0;

  // RESPONSE (filled by the driver for sequence-level compatibility).
  logic [DATA_WIDTH-1:0]    rdata;
  logic                     slverr;

  // EXECUTION METADATA. The driver fills these fields on the sequence item
  // returned by finish_item(); the monitor fills the same fields on its own
  // independently published observation.
  bit                       reset_abort;
  bit                       abort_in_access;
  int unsigned              wait_cycles;
  bit                       back_to_back;
  bit                       setup_started;
  int unsigned              observed_idle_cycles;
  time                      completed_at; // Monitor handshake time, not sequence intent.

  // Valid READs use zero strobes by default; negative tests may override.
  constraint c_read_strobes {
    if (!write) soft strb == '0;
  }

  constraint c_idle_cycles {
    soft idle_cycles == 0;
  }

  // idle_cycles is an unconstrained generic scheduling request. Stimulus
  // sequences may impose a narrower profile when appropriate.

  `uvm_object_param_utils(apb_trans #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_trans");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    apb_trans #(ADDR_WIDTH, DATA_WIDTH) rhs_trans;
    if (!$cast(rhs_trans, rhs)) begin
      `uvm_fatal("APB_TRANS_COPY", "Cannot copy from incompatible object")
    end
    super.do_copy(rhs);
    write        = rhs_trans.write;
    addr         = rhs_trans.addr;
    wdata        = rhs_trans.wdata;
    strb         = rhs_trans.strb;
    prot         = rhs_trans.prot;
    idle_cycles  = rhs_trans.idle_cycles;
    rdata        = rhs_trans.rdata;
    slverr       = rhs_trans.slverr;
    reset_abort  = rhs_trans.reset_abort;
    abort_in_access = rhs_trans.abort_in_access;
    wait_cycles  = rhs_trans.wait_cycles;
    back_to_back = rhs_trans.back_to_back;
    setup_started = rhs_trans.setup_started;
    observed_idle_cycles = rhs_trans.observed_idle_cycles;
    completed_at = rhs_trans.completed_at;
  endfunction

  // Compare request intent and meaningful response/outcome fields. Scheduling
  // hints and observed timing metadata are intentionally not equality fields.
  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    apb_trans #(ADDR_WIDTH, DATA_WIDTH) rhs_trans;
    bit same;

    if (!$cast(rhs_trans, rhs))
      return 0;
    same = super.do_compare(rhs, comparer);
    same &= comparer.compare_field("write", write, rhs_trans.write, 1);
    same &= comparer.compare_field("addr", addr, rhs_trans.addr, ADDR_WIDTH);
    same &= comparer.compare_field("strb", strb, rhs_trans.strb, STRB_WIDTH);
    same &= comparer.compare_field("prot", prot, rhs_trans.prot, 3);
    if (write)
      same &= comparer.compare_field("wdata", wdata, rhs_trans.wdata, DATA_WIDTH);
    if (!write)
      same &= comparer.compare_field("rdata", rdata, rhs_trans.rdata, DATA_WIDTH);
    same &= comparer.compare_field("slverr", slverr, rhs_trans.slverr, 1);
    same &= comparer.compare_field(
      "reset_abort", reset_abort, rhs_trans.reset_abort, 1);
    return same;
  endfunction

  virtual function void do_print(uvm_printer printer);
    super.do_print(printer);
    printer.print_field("write", write, 1, UVM_BIN);
    printer.print_field("addr", addr, ADDR_WIDTH, UVM_HEX);
    printer.print_field("wdata", wdata, DATA_WIDTH, UVM_HEX);
    printer.print_field("strb", strb, STRB_WIDTH, UVM_BIN);
    printer.print_field("prot", prot, 3, UVM_BIN);
    printer.print_field("idle_cycles", idle_cycles, 32, UVM_DEC);
    printer.print_field("rdata", rdata, DATA_WIDTH, UVM_HEX);
    printer.print_field("slverr", slverr, 1, UVM_BIN);
    printer.print_field("reset_abort", reset_abort, 1, UVM_BIN);
    printer.print_field("wait_cycles", wait_cycles, 32, UVM_DEC);
    printer.print_field("back_to_back", back_to_back, 1, UVM_BIN);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "%s addr=0x%0h wdata=0x%0h strb=%b prot=%03b idle=%0d | rdata=0x%0h slverr=%0b | wait=%0d b2b=%0b abort=%0b",
      write ? "WR" : "RD", addr, wdata, strb, prot, idle_cycles,
      rdata, slverr, wait_cycles, back_to_back, reset_abort);
  endfunction
endclass
