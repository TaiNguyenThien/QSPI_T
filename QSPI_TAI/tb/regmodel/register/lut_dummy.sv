//==============================================================================
// Register : LUT_DUMMY
// Offset   : 0x060
// Desc     : Selected LUT entry dummy-cycle value (Spec 4.26)
// Reset    : 32'h0000_0000
// Note     : Indirect register: the value accessed depends on LUT_CTRL.LUT_INDEX (4 entries).
//           A single mirror cannot track 4 entries, so the field is volatile (no auto-check).
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// DUMMY             [7:0]    RW      Stored additional dummy-cycle value
//==============================================================================
class lut_dummy extends uvm_reg;
  `uvm_object_utils(lut_dummy)

  rand uvm_reg_field DUMMY;

  function new(string name = "lut_dummy");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DUMMY = uvm_reg_field::type_id::create("DUMMY");

    //              parent  size lsb access  vol reset      has_rst rand indiv
    DUMMY.configure(this,  8,  0, "RW"  , 1, 8'h00    , 1, 1, 0);
  endfunction

endclass : lut_dummy
