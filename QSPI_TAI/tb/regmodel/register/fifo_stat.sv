//==============================================================================
// Register : FIFO_STAT
// Offset   : 0x04C
// Desc     : FIFO status register (Spec 4.21)
// Reset    : 32'h0000_0000
// Note     : All fields are HW-driven -> volatile.
//           NOTE: Spec Table 4-21 lists TX_EMPTY reset = 0, although an empty FIFO after reset
//           would normally report 1. Value kept per spec; field is volatile so it is not checked.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// TX_LEVEL          [3:0]    RO      Current TX FIFO level
// RX_LEVEL          [7:4]    RO      Current RX FIFO level
// TX_EMPTY          [8]      RO      TX FIFO empty indication (spec reset = 0, see note)
// RX_FULL           [9]      RO      RX FIFO full indication
//==============================================================================
class fifo_stat extends uvm_reg;
  `uvm_object_utils(fifo_stat)

  rand uvm_reg_field TX_LEVEL;
  rand uvm_reg_field RX_LEVEL;
  rand uvm_reg_field TX_EMPTY;
  rand uvm_reg_field RX_FULL;

  function new(string name = "fifo_stat");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    TX_LEVEL = uvm_reg_field::type_id::create("TX_LEVEL");
    RX_LEVEL = uvm_reg_field::type_id::create("RX_LEVEL");
    TX_EMPTY = uvm_reg_field::type_id::create("TX_EMPTY");
    RX_FULL  = uvm_reg_field::type_id::create("RX_FULL");

    //                 parent  size lsb access  vol reset      has_rst rand indiv
    TX_LEVEL.configure(this,  4,  0, "RO"  , 1, 4'h0     , 1, 0, 0);
    RX_LEVEL.configure(this,  4,  4, "RO"  , 1, 4'h0     , 1, 0, 0);
    TX_EMPTY.configure(this,  1,  8, "RO"  , 1, 1'b0     , 1, 0, 0);
    RX_FULL.configure( this,  1,  9, "RO"  , 1, 1'b0     , 1, 0, 0);
  endfunction

endclass : fifo_stat
