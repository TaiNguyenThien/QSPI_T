class apb_sequencer #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_sequencer #(apb_trans #(ADDR_WIDTH, DATA_WIDTH));
  `uvm_component_param_utils(apb_sequencer #(ADDR_WIDTH, DATA_WIDTH))

  function new(string name = "apb_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction
endclass
