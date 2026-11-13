//==============================================================================
// Register : WRITE_TX
// Offset   : 0x044
// Desc     : TX FIFO data port (Spec 4.19)
// Reset    : 32'h0000_0000
// Note     : WO FIFO port: each write pushes one word into the TX FIFO.
//           Excluded from built-in register tests because accesses have side effects.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// DATA              [31:0]   WO      TX FIFO write data
//==============================================================================
class write_tx extends uvm_reg;
  `uvm_object_utils(write_tx)

  rand uvm_reg_field DATA;

  function new(string name = "write_tx");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DATA = uvm_reg_field::type_id::create("DATA");

    //             parent  size lsb access  vol reset      has_rst rand indiv
    DATA.configure(this, 32,  0, "WO"  , 1, 32'h0    , 1, 1, 0);

    // Exclude from UVM built-in register test sequences
    uvm_resource_db#(bit)::set({"REG::", get_full_name()}, "NO_REG_TESTS", 1, this);
  endfunction

endclass : write_tx
