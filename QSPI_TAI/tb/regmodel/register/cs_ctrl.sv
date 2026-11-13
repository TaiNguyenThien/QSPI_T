//==============================================================================
// Register : CS_CTRL
// Offset   : 0x018
// Desc     : Chip-select control register (Spec 4.8)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// CS_AUTO           [0]      RW      Automatic chip-select control
// CS_LEVEL          [1]      RW      Manual chip-select level
// CS_DELAY          [3:2]    RW      Chip-select timing/delay control
//==============================================================================
class cs_ctrl extends uvm_reg;
  `uvm_object_utils(cs_ctrl)

  rand uvm_reg_field CS_AUTO;
  rand uvm_reg_field CS_LEVEL;
  rand uvm_reg_field CS_DELAY;

  function new(string name = "cs_ctrl");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    CS_AUTO  = uvm_reg_field::type_id::create("CS_AUTO");
    CS_LEVEL = uvm_reg_field::type_id::create("CS_LEVEL");
    CS_DELAY = uvm_reg_field::type_id::create("CS_DELAY");

    //                 parent  size lsb access  vol reset      has_rst rand indiv
    CS_AUTO.configure( this,  1,  0, "RW"  , 0, 1'b0     , 1, 1, 0);
    CS_LEVEL.configure(this,  1,  1, "RW"  , 0, 1'b0     , 1, 1, 0);
    CS_DELAY.configure(this,  2,  2, "RW"  , 0, 2'b0     , 1, 1, 0);
  endfunction

endclass : cs_ctrl
