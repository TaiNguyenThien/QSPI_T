`ifndef APB_SEQ_LIB_SV
`define APB_SEQ_LIB_SV

// Reusable APB read/write sequence library; results are checked by callers/scoreboards.
class apb_base_seq #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_sequence #(apb_trans #(ADDR_WIDTH, DATA_WIDTH));
  `uvm_object_param_utils(apb_base_seq #(ADDR_WIDTH, DATA_WIDTH))

  typedef apb_trans #(ADDR_WIDTH, DATA_WIDTH) trans_t;

  function new(string name = "apb_base_seq");
    super.new(name);
  endfunction

  // The returned handle carries driver response and execution fields. The
  // monitor publishes an independent observation of sampled bus activity;
  // its timing metadata is authoritative for scoreboard/coverage consumers.
  task apb_write(
    input  bit [ADDR_WIDTH-1:0]   addr,
    input  bit [DATA_WIDTH-1:0]   data,
    output trans_t                result,
    input  bit [DATA_WIDTH/8-1:0] strb = '1,
    input  bit [2:0]              prot = '0
  );
    trans_t req;
    req = trans_t::type_id::create("write_req");
    start_item(req);
    req.write = 1'b1;
    req.addr  = addr;
    req.wdata = data;
    req.strb  = strb;
    req.prot  = prot;
    finish_item(req);
    result = req;
  endtask

  task apb_read(
    input  bit [ADDR_WIDTH-1:0] addr,
    output trans_t              result,
    input  bit [2:0]            prot = '0
  );
    trans_t req;
    req = trans_t::type_id::create("read_req");
    start_item(req);
    req.write = 1'b0;
    req.addr  = addr;
    req.wdata = '0;
    req.strb  = '0;
    req.prot  = prot;
    finish_item(req);
    result = req;
  endtask
endclass : apb_base_seq

// One directed READ; no DUT checking in the sequence.
class apb_single_read_seq #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends apb_base_seq #(ADDR_WIDTH, DATA_WIDTH);
  `uvm_object_param_utils(apb_single_read_seq #(ADDR_WIDTH, DATA_WIDTH))

  typedef apb_trans #(ADDR_WIDTH, DATA_WIDTH) trans_t;
  bit [ADDR_WIDTH-1:0] addr;
  bit [2:0]            prot = '0;
  trans_t              result;

  function new(string name = "apb_single_read_seq");
    super.new(name);
  endfunction

  virtual task body();
    apb_read(addr, result, prot);
  endtask
endclass : apb_single_read_seq

// One directed WRITE; no DUT checking in the sequence.
class apb_single_write_seq #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends apb_base_seq #(ADDR_WIDTH, DATA_WIDTH);
  `uvm_object_param_utils(apb_single_write_seq #(ADDR_WIDTH, DATA_WIDTH))

  typedef apb_trans #(ADDR_WIDTH, DATA_WIDTH) trans_t;
  bit [ADDR_WIDTH-1:0]   addr;
  bit [DATA_WIDTH-1:0]   data;
  bit [DATA_WIDTH/8-1:0] strb = '1;
  bit [2:0]              prot = '0;
  trans_t                result;

  function new(string name = "apb_single_write_seq");
    super.new(name);
  endfunction

  virtual task body();
    apb_write(addr, data, result, strb, prot);
  endtask
endclass : apb_single_write_seq

`endif // APB_SEQ_LIB_SV
