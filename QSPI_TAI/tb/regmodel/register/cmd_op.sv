//==============================================================================
// Register : CMD_OP
// Offset   : 0x028
// Desc     : Indirect opcode and mode value register (Spec 4.12)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// OPCODE            [7:0]    RW      QSPI command opcode
// MODE_BITS         [15:8]   RW      Mode value when CMD_CFG.MODE_EN=1
//==============================================================================
class cmd_op extends uvm_reg;
  `uvm_object_utils(cmd_op)

  rand uvm_reg_field OPCODE;
  rand uvm_reg_field MODE_BITS;

  function new(string name = "cmd_op");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    OPCODE    = uvm_reg_field::type_id::create("OPCODE");
    MODE_BITS = uvm_reg_field::type_id::create("MODE_BITS");

    //                  parent  size lsb access  vol reset      has_rst rand indiv
    OPCODE.configure(   this,  8,  0, "RW"  , 0, 8'h00    , 1, 1, 0);
    MODE_BITS.configure(this,  8,  8, "RW"  , 0, 8'h00    , 1, 1, 0);
  endfunction

endclass : cmd_op
