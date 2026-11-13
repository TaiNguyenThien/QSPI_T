//==============================================================================
// Register : CTRL
// Offset   : 0x004
// Desc     : Controller and command control register (Spec 4.3)
// Reset    : 32'h0000_0000
// Note     : Bits [7:5] and [31:10] are reserved.
//           Writing CMD_TRIGGER/ENABLE has side effects (launches a command),
//           so bit-bash and access tests are disabled; hw_reset (read-only) still runs.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// ENABLE            [0]      RW      Enables controller operation
// XIP_EN            [1]      RW      Enables XIP operation
// QUAD_EN           [2]      RW      Enables quad-capable operation
// CPOL              [3]      RW      QSPI clock polarity
// CPHA              [4]      RW      QSPI clock phase
// CMD_TRIGGER       [8]      RW      RW/Pulse: write 1 while ENABLE=1 to start an indirect command; cleared by CE clear (HW) -> volatile
// DMA_EN            [9]      RW      Associates DMA with command; cleared by HW on command completion -> volatile
//==============================================================================
class ctrl_reg extends uvm_reg;
  `uvm_object_utils(ctrl_reg)

  rand uvm_reg_field ENABLE;
  rand uvm_reg_field XIP_EN;
  rand uvm_reg_field QUAD_EN;
  rand uvm_reg_field CPOL;
  rand uvm_reg_field CPHA;
  rand uvm_reg_field CMD_TRIGGER;
  rand uvm_reg_field DMA_EN;

  function new(string name = "ctrl_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    ENABLE      = uvm_reg_field::type_id::create("ENABLE");
    XIP_EN      = uvm_reg_field::type_id::create("XIP_EN");
    QUAD_EN     = uvm_reg_field::type_id::create("QUAD_EN");
    CPOL        = uvm_reg_field::type_id::create("CPOL");
    CPHA        = uvm_reg_field::type_id::create("CPHA");
    CMD_TRIGGER = uvm_reg_field::type_id::create("CMD_TRIGGER");
    DMA_EN      = uvm_reg_field::type_id::create("DMA_EN");

    //                    parent  size lsb access  vol reset      has_rst rand indiv
    ENABLE.configure(     this,  1,  0, "RW"  , 0, 1'b0     , 1, 1, 0);
    XIP_EN.configure(     this,  1,  1, "RW"  , 0, 1'b0     , 1, 1, 0);
    QUAD_EN.configure(    this,  1,  2, "RW"  , 0, 1'b0     , 1, 1, 0);
    CPOL.configure(       this,  1,  3, "RW"  , 0, 1'b0     , 1, 1, 0);
    CPHA.configure(       this,  1,  4, "RW"  , 0, 1'b0     , 1, 1, 0);
    CMD_TRIGGER.configure(this,  1,  8, "RW"  , 1, 1'b0     , 1, 1, 0);
    DMA_EN.configure(     this,  1,  9, "RW"  , 1, 1'b0     , 1, 1, 0);

    // Exclude from UVM built-in register test sequences
    uvm_resource_db#(bit)::set({"REG::", get_full_name()}, "NO_REG_BIT_BASH_TEST", 1, this);
    uvm_resource_db#(bit)::set({"REG::", get_full_name()}, "NO_REG_ACCESS_TEST", 1, this);
  endfunction

endclass : ctrl_reg
