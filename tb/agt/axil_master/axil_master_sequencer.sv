// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_master_sequencer.sv
// Role   : Sequencer for AXI4-Lite Master Agent
// =============================================================================

`ifndef AXIL_MASTER_SEQUENCER_SV
`define AXIL_MASTER_SEQUENCER_SV

class axil_master_sequencer extends uvm_sequencer #(axil_master_transaction);
  `uvm_component_utils(axil_master_sequencer)

  function new(string name = "axil_master_sequencer", uvm_component parent = null);
    super.new(name, parent);
  endfunction

endclass : axil_master_sequencer

`endif // AXIL_MASTER_SEQUENCER_SV
