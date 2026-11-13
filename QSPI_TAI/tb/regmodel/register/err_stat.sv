//==============================================================================
// Register : ERR_STAT
// Offset   : 0x050
// Desc     : Error status register (Spec 4.22)
// Reset    : 32'h0000_0000
// Note     : All fields are HW-driven -> volatile.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// TIMEOUT           [0]      RO      Controller timeout indication
// OVERRUN           [1]      RO      RX overrun indication
// UNDERRUN          [2]      RO      TX underrun indication
//==============================================================================
class err_stat extends uvm_reg;
  `uvm_object_utils(err_stat)

  rand uvm_reg_field TIMEOUT;
  rand uvm_reg_field OVERRUN;
  rand uvm_reg_field UNDERRUN;

  function new(string name = "err_stat");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    TIMEOUT  = uvm_reg_field::type_id::create("TIMEOUT");
    OVERRUN  = uvm_reg_field::type_id::create("OVERRUN");
    UNDERRUN = uvm_reg_field::type_id::create("UNDERRUN");

    //                 parent  size lsb access  vol reset      has_rst rand indiv
    TIMEOUT.configure( this,  1,  0, "RO"  , 1, 1'b0     , 1, 0, 0);
    OVERRUN.configure( this,  1,  1, "RO"  , 1, 1'b0     , 1, 0, 0);
    UNDERRUN.configure(this,  1,  2, "RO"  , 1, 1'b0     , 1, 0, 0);
  endfunction

endclass : err_stat
