//==============================================================================
// Register : STATUS
// Offset   : 0x008
// Desc     : Controller status register (Spec 4.4)
// Reset    : 32'h0000_0000
// Note     : All fields are HW-driven -> volatile.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// BUSY              [0]      RO      Controller command path is active
// XIP_ACTIVE        [1]      RO      XIP transaction is active
// CMD_DONE          [2]      RO      Command completion indication
// DMA_DONE          [3]      RO      DMA completion indication
//==============================================================================
class status_reg extends uvm_reg;
  `uvm_object_utils(status_reg)

  rand uvm_reg_field BUSY;
  rand uvm_reg_field XIP_ACTIVE;
  rand uvm_reg_field CMD_DONE;
  rand uvm_reg_field DMA_DONE;

  function new(string name = "status_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    BUSY       = uvm_reg_field::type_id::create("BUSY");
    XIP_ACTIVE = uvm_reg_field::type_id::create("XIP_ACTIVE");
    CMD_DONE   = uvm_reg_field::type_id::create("CMD_DONE");
    DMA_DONE   = uvm_reg_field::type_id::create("DMA_DONE");

    //                   parent  size lsb access  vol reset      has_rst rand indiv
    BUSY.configure(      this,  1,  0, "RO"  , 1, 1'b0     , 1, 0, 0);
    XIP_ACTIVE.configure(this,  1,  1, "RO"  , 1, 1'b0     , 1, 0, 0);
    CMD_DONE.configure(  this,  1,  2, "RO"  , 1, 1'b0     , 1, 0, 0);
    DMA_DONE.configure(  this,  1,  3, "RO"  , 1, 1'b0     , 1, 0, 0);
  endfunction

endclass : status_reg
