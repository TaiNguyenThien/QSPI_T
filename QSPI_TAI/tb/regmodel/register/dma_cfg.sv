//==============================================================================
// Register : DMA_CFG
// Offset   : 0x038
// Desc     : DMA direction and address control register (Spec 4.16)
// Reset    : 32'h0000_0000
// Note     : Bits [3:0] and [31:6] are reserved.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// DIR               [4]      RW      0=RAM-to-QSPI, 1=QSPI-to-RAM
// INCR_ADDR         [5]      RW      Enable system-memory address increment
//==============================================================================
class dma_cfg extends uvm_reg;
  `uvm_object_utils(dma_cfg)

  rand uvm_reg_field DIR;
  rand uvm_reg_field INCR_ADDR;

  function new(string name = "dma_cfg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DIR       = uvm_reg_field::type_id::create("DIR");
    INCR_ADDR = uvm_reg_field::type_id::create("INCR_ADDR");

    //                  parent  size lsb access  vol reset      has_rst rand indiv
    DIR.configure(      this,  1,  4, "RW"  , 0, 1'b0     , 1, 1, 0);
    INCR_ADDR.configure(this,  1,  5, "RW"  , 0, 1'b0     , 1, 1, 0);
  endfunction

endclass : dma_cfg
