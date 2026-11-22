class axi_slave_transaction extends uvm_sequence_item;

  // --- Address Phase ---
  rand logic [31:0] addr;
  rand logic [7:0]  len;
  rand logic [2:0]  size;
  rand logic [1:0]  burst;
  rand bit          is_write;

  // --- Data Phase ---
  rand logic [31:0] data[];
  rand logic [3:0]  wstrb[];
  bit               wlast_seen;
  bit               rlast_seen;

  // --- Response Phase ---
  rand logic [1:0] bresp;
  rand logic [1:0] rresp[];
  int            error_beat_pos;
  int            bresp_burst_pos;

  // --- Handshake Timing ---
  int unsigned awready_delay;
  int unsigned wready_delay;
  int unsigned arready_delay;
  int unsigned bvalid_delay;
  int unsigned rvalid_delay;
  time         started_at;
  time         completed_at;

  `uvm_object_utils_begin(axi_slave_transaction)
    `uvm_field_int(addr,            UVM_ALL_ON | UVM_HEX)
    `uvm_field_int(len,             UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(size,            UVM_ALL_ON)
    `uvm_field_int(burst,           UVM_ALL_ON)
    `uvm_field_int(is_write,        UVM_ALL_ON)
    `uvm_field_array_int(data,      UVM_ALL_ON | UVM_HEX)
    `uvm_field_array_int(wstrb,     UVM_ALL_ON)
    `uvm_field_int(wlast_seen,      UVM_ALL_ON)
    `uvm_field_int(rlast_seen,      UVM_ALL_ON)
    `uvm_field_int(bresp,           UVM_ALL_ON)
    `uvm_field_array_int(rresp,     UVM_ALL_ON)
    `uvm_field_int(error_beat_pos,  UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(bresp_burst_pos, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(awready_delay,   UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(wready_delay,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(arready_delay,   UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(bvalid_delay,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(rvalid_delay,    UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(started_at,      UVM_ALL_ON | UVM_TIME)
    `uvm_field_int(completed_at,    UVM_ALL_ON | UVM_TIME)
  `uvm_object_utils_end

  function new(string name = "axi_slave_transaction");
    super.new(name);
  endfunction

endclass

class axi_slave_resp_event extends uvm_object;
  bit          is_write;
  logic [1:0]  resp;
  int unsigned beat_idx;
  time         obs_time;

  `uvm_object_utils_begin(axi_slave_resp_event)
    `uvm_field_int(is_write, UVM_ALL_ON)
    `uvm_field_int(resp,     UVM_ALL_ON)
    `uvm_field_int(beat_idx, UVM_ALL_ON | UVM_DEC)
    `uvm_field_int(obs_time, UVM_ALL_ON | UVM_TIME)
  `uvm_object_utils_end

  function new(string name = "axi_slave_resp_event");
    super.new(name);
  endfunction
endclass
