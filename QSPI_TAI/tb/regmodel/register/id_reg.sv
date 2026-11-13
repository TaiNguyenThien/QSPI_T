//==============================================================================
// Register : ID
// Offset   : 0x000
// Desc     : Identification/version register (Spec 4.2)
// Reset    : 32'h0A10_0102
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// MINOR             [7:0]    RO      Minor revision
// MAJOR             [15:8]   RO      Major revision
// ARCH_ID           [31:16]  RO      QSPI training architecture identifier
//==============================================================================
class id_reg extends uvm_reg;
  `uvm_object_utils(id_reg)

  rand uvm_reg_field MINOR;
  rand uvm_reg_field MAJOR;
  rand uvm_reg_field ARCH_ID;

  function new(string name = "id_reg");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    MINOR   = uvm_reg_field::type_id::create("MINOR");
    MAJOR   = uvm_reg_field::type_id::create("MAJOR");
    ARCH_ID = uvm_reg_field::type_id::create("ARCH_ID");

    //                parent  size lsb access  vol reset      has_rst rand indiv
    MINOR.configure(  this,  8,  0, "RO"  , 0, 8'h02    , 1, 0, 0);
    MAJOR.configure(  this,  8,  8, "RO"  , 0, 8'h01    , 1, 0, 0);
    ARCH_ID.configure(this, 16, 16, "RO"  , 0, 16'h0A10 , 1, 0, 0);
  endfunction

endclass : id_reg
