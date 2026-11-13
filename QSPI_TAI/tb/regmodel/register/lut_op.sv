//==============================================================================
// Register : LUT_OP
// Offset   : 0x05C
// Desc     : Selected LUT entry opcode/mode value (Spec 4.25)
// Reset    : 32'h0000_0000
// Note     : Indirect register: the value accessed depends on LUT_CTRL.LUT_INDEX (4 entries).
//           A single mirror cannot track 4 entries, so the field is volatile (no auto-check).
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// OP                [15:0]   RW      Stored opcode [7:0] and mode value [15:8] (same layout as CMD_OP[15:0])
//==============================================================================
class lut_op extends uvm_reg;
  `uvm_object_utils(lut_op)

  rand uvm_reg_field OP;

  function new(string name = "lut_op");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    OP = uvm_reg_field::type_id::create("OP");

    //           parent  size lsb access  vol reset      has_rst rand indiv
    OP.configure(this, 16,  0, "RW"  , 1, 16'h0    , 1, 1, 0);
  endfunction

endclass : lut_op
