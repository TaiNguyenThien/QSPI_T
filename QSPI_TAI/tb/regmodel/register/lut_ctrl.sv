//==============================================================================
// Register : LUT_CTRL
// Offset   : 0x054
// Desc     : LUT enable and entry index register (Spec 4.23)
// Reset    : 32'h0000_0000
// Note     : Bit [1] and bits [31:4] are reserved.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// LUT_EN            [0]      RW      1=use selected LUT entry, 0=use direct command registers
// LUT_INDEX         [3:2]    RW      Selects LUT entry 0..3
//==============================================================================
class lut_ctrl extends uvm_reg;
  `uvm_object_utils(lut_ctrl)

  rand uvm_reg_field LUT_EN;
  rand uvm_reg_field LUT_INDEX;

  function new(string name = "lut_ctrl");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    LUT_EN    = uvm_reg_field::type_id::create("LUT_EN");
    LUT_INDEX = uvm_reg_field::type_id::create("LUT_INDEX");

    //                  parent  size lsb access  vol reset      has_rst rand indiv
    LUT_EN.configure(   this,  1,  0, "RW"  , 0, 1'b0     , 1, 1, 0);
    LUT_INDEX.configure(this,  2,  2, "RW"  , 0, 2'b0     , 1, 1, 0);
  endfunction

endclass : lut_ctrl
