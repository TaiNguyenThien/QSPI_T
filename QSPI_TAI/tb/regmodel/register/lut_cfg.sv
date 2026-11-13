//==============================================================================
// Register : LUT_CFG
// Offset   : 0x058
// Desc     : Selected LUT entry command configuration (Spec 4.24)
// Reset    : 32'h0000_0000
// Note     : Indirect register: the value accessed depends on LUT_CTRL.LUT_INDEX (4 entries).
//           A single mirror cannot track 4 entries, so the field is volatile (no auto-check).
//           Track per-entry contents in the scoreboard/sequence when checking LUT persistence.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// CFG               [13:0]   RW      Stored command-format configuration (same layout as CMD_CFG[13:0])
//==============================================================================
class lut_cfg extends uvm_reg;
  `uvm_object_utils(lut_cfg)

  rand uvm_reg_field CFG;

  function new(string name = "lut_cfg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    CFG = uvm_reg_field::type_id::create("CFG");

    //            parent  size lsb access  vol reset      has_rst rand indiv
    CFG.configure(this, 14,  0, "RW"  , 1, 14'h0    , 1, 1, 0);
  endfunction

endclass : lut_cfg
