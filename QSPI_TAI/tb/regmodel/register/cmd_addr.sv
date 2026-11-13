//==============================================================================
// Register : CMD_ADDR
// Offset   : 0x02C
// Desc     : Flash address register (Spec 4.13)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// ADDR              [31:0]   RW      Flash address value
//==============================================================================
class cmd_addr extends uvm_reg;
  `uvm_object_utils(cmd_addr)

  rand uvm_reg_field ADDR;

  function new(string name = "cmd_addr");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    ADDR = uvm_reg_field::type_id::create("ADDR");

    //             parent  size lsb access  vol reset      has_rst rand indiv
    ADDR.configure(this, 32,  0, "RW"  , 0, 32'h0    , 1, 1, 0);
  endfunction

endclass : cmd_addr
