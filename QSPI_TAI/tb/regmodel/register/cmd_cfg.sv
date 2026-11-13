//==============================================================================
// Register : CMD_CFG
// Offset   : 0x024
// Desc     : Indirect command format register (Spec 4.11)
// Reset    : 32'h0000_0000
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// CMD_LANES         [1:0]    RW      00=single, 01=dual, 10=quad, 11=reserved
// ADDR_LANES        [3:2]    RW      00=single, 01=dual, 10=quad, 11=reserved
// DATA_LANES        [5:4]    RW      00=single, 01=dual, 10=quad, 11=reserved
// ADDR_BYTES        [7:6]    RW      00=no address, 01=3-byte, 10=4-byte
// MODE_EN           [8]      RW      Enables optional mode phase
// DUMMY_CYCLES      [12:9]   RW      Dummy-cycle count
// DIR               [13]     RW      0=TX/write data phase, 1=RX/read data phase
//==============================================================================
class cmd_cfg extends uvm_reg;
  `uvm_object_utils(cmd_cfg)

  rand uvm_reg_field CMD_LANES;
  rand uvm_reg_field ADDR_LANES;
  rand uvm_reg_field DATA_LANES;
  rand uvm_reg_field ADDR_BYTES;
  rand uvm_reg_field MODE_EN;
  rand uvm_reg_field DUMMY_CYCLES;
  rand uvm_reg_field DIR;

  // Avoid reserved encoding 2'b11 when the register is randomized
  constraint c_no_reserved_enc {
    CMD_LANES.value != 2'b11;
    ADDR_LANES.value != 2'b11;
    DATA_LANES.value != 2'b11;
    ADDR_BYTES.value != 2'b11;
  }

  function new(string name = "cmd_cfg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    CMD_LANES    = uvm_reg_field::type_id::create("CMD_LANES");
    ADDR_LANES   = uvm_reg_field::type_id::create("ADDR_LANES");
    DATA_LANES   = uvm_reg_field::type_id::create("DATA_LANES");
    ADDR_BYTES   = uvm_reg_field::type_id::create("ADDR_BYTES");
    MODE_EN      = uvm_reg_field::type_id::create("MODE_EN");
    DUMMY_CYCLES = uvm_reg_field::type_id::create("DUMMY_CYCLES");
    DIR          = uvm_reg_field::type_id::create("DIR");

    //                     parent  size lsb access  vol reset      has_rst rand indiv
    CMD_LANES.configure(   this,  2,  0, "RW"  , 0, 2'b0     , 1, 1, 0);
    ADDR_LANES.configure(  this,  2,  2, "RW"  , 0, 2'b0     , 1, 1, 0);
    DATA_LANES.configure(  this,  2,  4, "RW"  , 0, 2'b0     , 1, 1, 0);
    ADDR_BYTES.configure(  this,  2,  6, "RW"  , 0, 2'b0     , 1, 1, 0);
    MODE_EN.configure(     this,  1,  8, "RW"  , 0, 1'b0     , 1, 1, 0);
    DUMMY_CYCLES.configure(this,  4,  9, "RW"  , 0, 4'b0     , 1, 1, 0);
    DIR.configure(         this,  1, 13, "RW"  , 0, 1'b0     , 1, 1, 0);
  endfunction

endclass : cmd_cfg
