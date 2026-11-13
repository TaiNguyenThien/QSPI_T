`ifndef QSPI_TRANSACTION_SV
`define QSPI_TRANSACTION_SV

class qspi_transaction extends uvm_sequence_item;
  rand logic [7:0]  opcode;
  rand logic [31:0] addr;
  rand logic [7:0]  data[];
  rand logic [7:0]  mode_bits;
  rand bit          dir;
  rand bit [1:0]    lane_mode;

  `uvm_object_utils_begin(qspi_transaction)
    `uvm_field_int(opcode, UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(addr, UVM_ALL_ON | UVM_HEX)
    `uvm_field_array_int(data, UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(mode_bits, UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(dir, UVM_ALL_ON)
    `uvm_field_int(lane_mode, UVM_ALL_ON)
  `uvm_object_utils_end

  function new(string name = "qspi_transaction");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("op=%02h addr=%08h data_bytes=%0d mode=%02h dir=%0b lane_mode=%0d",
      opcode, addr, data.size(), mode_bits, dir, lane_mode);
  endfunction
endclass : qspi_transaction

`endif
