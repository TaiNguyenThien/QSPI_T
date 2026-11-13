//==============================================================================
// Register : XIP_CMD
// Offset   : 0x020
// Desc     : XIP opcode and mode value register (Spec 4.10)
// Reset    : 32'h0000_0000
// Note     : Bits [15:8] and [31:24] are reserved.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// READ_OPCODE       [7:0]    RW      QSPI read opcode
// MODE_BITS         [23:16]  RW      Mode value when XIP_CFG.MODE_EN=1
//==============================================================================
class xip_cmd extends uvm_reg;
  `uvm_object_utils(xip_cmd)

  rand uvm_reg_field READ_OPCODE;
  rand uvm_reg_field MODE_BITS;

  function new(string name = "xip_cmd");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    READ_OPCODE = uvm_reg_field::type_id::create("READ_OPCODE");
    MODE_BITS   = uvm_reg_field::type_id::create("MODE_BITS");

    //                    parent  size lsb access  vol reset      has_rst rand indiv
    READ_OPCODE.configure(this,  8,  0, "RW"  , 0, 8'h00    , 1, 1, 0);
    MODE_BITS.configure(  this,  8, 16, "RW"  , 0, 8'h00    , 1, 1, 0);
  endfunction

endclass : xip_cmd
