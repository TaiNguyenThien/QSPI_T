//==============================================================================
// Register : INT_EN
// Offset   : 0x00C
// Desc     : Interrupt enable register (Spec 4.5)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// CMD_DONE_EN       [0]      RW      Enable command-completion interrupt
// DMA_DONE_EN       [1]      RW      Enable DMA-completion interrupt
// ERR_EN            [2]      RW      Enable error interrupt
// FIFO_TX_EMPTY_EN  [3]      RW      Enable TX-empty interrupt
// FIFO_RX_FULL_EN   [4]      RW      Enable RX-full interrupt
//==============================================================================
class int_en extends uvm_reg;
  `uvm_object_utils(int_en)

  rand uvm_reg_field CMD_DONE_EN;
  rand uvm_reg_field DMA_DONE_EN;
  rand uvm_reg_field ERR_EN;
  rand uvm_reg_field FIFO_TX_EMPTY_EN;
  rand uvm_reg_field FIFO_RX_FULL_EN;

  function new(string name = "int_en");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    CMD_DONE_EN      = uvm_reg_field::type_id::create("CMD_DONE_EN");
    DMA_DONE_EN      = uvm_reg_field::type_id::create("DMA_DONE_EN");
    ERR_EN           = uvm_reg_field::type_id::create("ERR_EN");
    FIFO_TX_EMPTY_EN = uvm_reg_field::type_id::create("FIFO_TX_EMPTY_EN");
    FIFO_RX_FULL_EN  = uvm_reg_field::type_id::create("FIFO_RX_FULL_EN");

    //                         parent  size lsb access  vol reset      has_rst rand indiv
    CMD_DONE_EN.configure(     this,  1,  0, "RW"  , 0, 1'b0     , 1, 1, 0);
    DMA_DONE_EN.configure(     this,  1,  1, "RW"  , 0, 1'b0     , 1, 1, 0);
    ERR_EN.configure(          this,  1,  2, "RW"  , 0, 1'b0     , 1, 1, 0);
    FIFO_TX_EMPTY_EN.configure(this,  1,  3, "RW"  , 0, 1'b0     , 1, 1, 0);
    FIFO_RX_FULL_EN.configure( this,  1,  4, "RW"  , 0, 1'b0     , 1, 1, 0);
  endfunction

endclass : int_en
