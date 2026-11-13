//==============================================================================
// Register : CMD_LEN
// Offset   : 0x030
// Desc     : Command payload length register (Spec 4.14)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// LENGTH            [31:0]   RW      Payload length in bytes (0 = no data phase)
//==============================================================================
class cmd_len extends uvm_reg;
  `uvm_object_utils(cmd_len)

  rand uvm_reg_field LENGTH;

  function new(string name = "cmd_len");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    LENGTH = uvm_reg_field::type_id::create("LENGTH");

    //               parent  size lsb access  vol reset      has_rst rand indiv
    LENGTH.configure(this, 32,  0, "RW"  , 0, 32'h0    , 1, 1, 0);
  endfunction

endclass : cmd_len
