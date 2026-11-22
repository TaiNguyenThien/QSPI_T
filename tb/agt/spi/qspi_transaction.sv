`ifndef QSPI_TRANSACTION_SV
`define QSPI_TRANSACTION_SV

class qspi_transaction extends uvm_sequence_item;
  rand logic [7:0]  opcode;
  rand logic [31:0] addr;
  rand logic [7:0]  data[];
  rand logic [7:0]  mode_bits;
  rand bit          dir;

  // Framing & pin-level telemetry populated by qspi_monitor
  // end_phase: 0=Opcode, 1=Address, 2=Mode, 3=Dummy, 4=Data(partial), 5=Complete
  bit [1:0]         cmd_lanes;
  bit [1:0]         addr_lanes;
  bit [1:0]         data_lanes;
  bit [1:0]         addr_bytes;
  bit               mode_en;
  int unsigned      sclk_edges_total;
  int unsigned      end_phase;
  bit               aborted_early;
  int unsigned      trailing_edges;
  time              started_at;
  time              data_completed_at;
  time              byte_completed_at[];
  time              completed_at;

  `uvm_object_utils_begin(qspi_transaction)
    `uvm_field_int(opcode,           UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(addr,             UVM_ALL_ON | UVM_HEX)
    `uvm_field_array_int(data,       UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(mode_bits,        UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(dir,              UVM_ALL_ON)
    `uvm_field_int(cmd_lanes,        UVM_ALL_ON)
    `uvm_field_int(addr_lanes,       UVM_ALL_ON)
    `uvm_field_int(data_lanes,       UVM_ALL_ON)
    `uvm_field_int(addr_bytes,       UVM_ALL_ON)
    `uvm_field_int(mode_en,          UVM_ALL_ON)
    `uvm_field_int(sclk_edges_total, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(end_phase,        UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(aborted_early,     UVM_ALL_ON)
    `uvm_field_int(trailing_edges,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(started_at,        UVM_ALL_ON | UVM_TIME)
    `uvm_field_int(data_completed_at, UVM_ALL_ON | UVM_TIME)
    `uvm_field_array_int(byte_completed_at, UVM_ALL_ON | UVM_TIME)
    `uvm_field_int(completed_at,      UVM_ALL_ON | UVM_TIME)
  `uvm_object_utils_end

  function new(string name = "qspi_transaction");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "op=%02h addr=%08h data_bytes=%0d mode=%02h(en=%0b) sclk_edges=%0d end_phase=%0d aborted=%0b dir=%0b lanes=%0d/%0d/%0d",
      opcode, addr, data.size(), mode_bits, mode_en,
      sclk_edges_total, end_phase, aborted_early, dir, cmd_lanes, addr_lanes, data_lanes);
  endfunction
endclass : qspi_transaction

`endif
