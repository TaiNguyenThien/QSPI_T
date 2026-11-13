//==============================================================================
// Register : READ_RX
// Offset   : 0x048
// Desc     : RX FIFO data port (Spec 4.20)
// Reset    : 32'h0000_0000
// Note     : RO FIFO port: each read pops one word from the RX FIFO (destructive read).
//           Excluded from built-in register tests because accesses have side effects.
//------------------------------------------------------------------------------
// Field             Bits     Access  Description
// DATA              [31:0]   RO      RX FIFO read data
//==============================================================================
class read_rx extends uvm_reg;
  `uvm_object_utils(read_rx)

  rand uvm_reg_field DATA;

  function new(string name = "read_rx");
    super.new(name, 32, UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DATA = uvm_reg_field::type_id::create("DATA");

    //             parent  size lsb access  vol reset      has_rst rand indiv
    DATA.configure(this, 32,  0, "RO"  , 1, 32'h0    , 1, 0, 0);

    // Exclude from UVM built-in register test sequences
    uvm_resource_db#(bit)::set({"REG::", get_full_name()}, "NO_REG_TESTS", 1, this);
  endfunction

endclass : read_rx
