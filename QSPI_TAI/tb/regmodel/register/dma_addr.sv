//==============================================================================
// Register : DMA_ADDR
// Offset   : 0x03C
// Desc     : DMA system-memory start address register (Spec 4.17)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// ADDR              [31:0]   RW      DMA system-memory start address
//==============================================================================
class dma_addr extends uvm_reg;
  `uvm_object_utils(dma_addr)

  rand uvm_reg_field ADDR;

  function new(string name = "dma_addr");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    ADDR = uvm_reg_field::type_id::create("ADDR");

    //             parent  size lsb access  vol reset      has_rst rand indiv
    ADDR.configure(this, 32,  0, "RW"  , 0, 32'h0    , 1, 1, 0);
  endfunction

endclass : dma_addr
