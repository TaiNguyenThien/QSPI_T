//==============================================================================
// Register : CMD_DUMMY
// Offset   : 0x034
// Desc     : Additional dummy-cycle register (Spec 4.15)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// EXTRA_DUMMY       [7:0]    RW      Additional dummy-cycle value
//==============================================================================
class cmd_dummy extends uvm_reg;
  `uvm_object_utils(cmd_dummy)

  rand uvm_reg_field EXTRA_DUMMY;

  function new(string name = "cmd_dummy");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    EXTRA_DUMMY = uvm_reg_field::type_id::create("EXTRA_DUMMY");

    //                    parent  size lsb access  vol reset      has_rst rand indiv
    EXTRA_DUMMY.configure(this,  8,  0, "RW"  , 0, 8'h00    , 1, 1, 0);
  endfunction

endclass : cmd_dummy
