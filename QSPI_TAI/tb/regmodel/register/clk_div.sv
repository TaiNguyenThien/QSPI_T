//==============================================================================
// Register : CLK_DIV
// Offset   : 0x014
// Desc     : QSPI clock divider register (Spec 4.7)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// DIV               [2:0]    RW      SCLK = CLK / 2^DIV
//==============================================================================
class clk_div extends uvm_reg;
  `uvm_object_utils(clk_div)

  rand uvm_reg_field DIV;

  function new(string name = "clk_div");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DIV = uvm_reg_field::type_id::create("DIV");

    //            parent  size lsb access  vol reset      has_rst rand indiv
    DIV.configure(this,  3,  0, "RW"  , 0, 3'b0     , 1, 1, 0);
  endfunction

endclass : clk_div
