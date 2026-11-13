//==============================================================================
// Register : INT_STAT
// Offset   : 0x010
// Desc     : Latched interrupt status register (Spec 4.6)
// Reset    : 32'h0000_0000
// Note     : RW1C. Each bit is cleared independently (Spec 5.9). HW sets bits -> volatile.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// CMD_DONE          [0]      W1C     Latched command-completion event
// DMA_DONE          [1]      W1C     Latched DMA-completion event
// ERR               [2]      W1C     Latched timeout/overrun/underrun event
// FIFO_TX_EMPTY     [3]      W1C     Latched TX FIFO empty event
// FIFO_RX_FULL      [4]      W1C     Latched RX FIFO full event
//==============================================================================
class int_stat extends uvm_reg;
  `uvm_object_utils(int_stat)

  rand uvm_reg_field CMD_DONE;
  rand uvm_reg_field DMA_DONE;
  rand uvm_reg_field ERR;
  rand uvm_reg_field FIFO_TX_EMPTY;
  rand uvm_reg_field FIFO_RX_FULL;

  function new(string name = "int_stat");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    CMD_DONE      = uvm_reg_field::type_id::create("CMD_DONE");
    DMA_DONE      = uvm_reg_field::type_id::create("DMA_DONE");
    ERR           = uvm_reg_field::type_id::create("ERR");
    FIFO_TX_EMPTY = uvm_reg_field::type_id::create("FIFO_TX_EMPTY");
    FIFO_RX_FULL  = uvm_reg_field::type_id::create("FIFO_RX_FULL");

    //                      parent  size lsb access  vol reset      has_rst rand indiv
    CMD_DONE.configure(     this,  1,  0, "W1C" , 1, 1'b0     , 1, 0, 0);
    DMA_DONE.configure(     this,  1,  1, "W1C" , 1, 1'b0     , 1, 0, 0);
    ERR.configure(          this,  1,  2, "W1C" , 1, 1'b0     , 1, 0, 0);
    FIFO_TX_EMPTY.configure(this,  1,  3, "W1C" , 1, 1'b0     , 1, 0, 0);
    FIFO_RX_FULL.configure( this,  1,  4, "W1C" , 1, 1'b0     , 1, 0, 0);
  endfunction

endclass : int_stat
