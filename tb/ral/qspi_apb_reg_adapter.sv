`ifndef QSPI_APB_REG_ADAPTER_SV
`define QSPI_APB_REG_ADAPTER_SV

class qspi_apb_reg_adapter extends uvm_reg_adapter;
  `uvm_object_utils(qspi_apb_reg_adapter)
  typedef qspi_apb_item_t apb_item_t;

  function new(string name = "qspi_apb_reg_adapter");
    super.new(name);
    supports_byte_enable = 1;
    provides_responses = 0;
  endfunction

  virtual function uvm_sequence_item reg2bus(const ref uvm_reg_bus_op rw);
    apb_item_t t;
    t = apb_item_t::type_id::create("ral_apb_request");
    t.write = (rw.kind == UVM_WRITE);
    t.addr = rw.addr[QSPI_APB_ADDR_WIDTH-1:0];
    t.wdata = rw.data[QSPI_APB_DATA_WIDTH-1:0];
    t.strb = t.write ? rw.byte_en[QSPI_APB_STRB_WIDTH-1:0] : '0;
    t.prot = 3'b000;
    t.idle_cycles = 0;
    return t;
  endfunction

  virtual function void bus2reg(uvm_sequence_item bus_item,
                                ref uvm_reg_bus_op rw);
    apb_item_t t;
    if (!$cast(t, bus_item))
      `uvm_fatal("QSPI_RAL_ADAPTER", "Expected qspi_apb_item_t")
    rw.kind = t.write ? UVM_WRITE : UVM_READ;
    rw.addr = t.addr;
    rw.data = t.write ? t.wdata : t.rdata;
    rw.byte_en = t.write ? t.strb : {QSPI_APB_STRB_WIDTH{1'b1}};
    if (t.reset_abort || t.slverr !== 1'b0)
      rw.status = UVM_NOT_OK;
    else if (!t.write && $isunknown(t.rdata))
      rw.status = UVM_HAS_X;
    else
      rw.status = UVM_IS_OK;
  endfunction
endclass : qspi_apb_reg_adapter

// Adapt the standard predictor to the subset intentionally modeled by RAL.
// Failed/aborted accesses and FIFO/banked windows cannot update fixed mirrors.
class qspi_apb_reg_predictor extends uvm_reg_predictor #(qspi_apb_item_t);
  `uvm_component_utils(qspi_apb_reg_predictor)

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // Match the formal name "tr" in uvm_reg_predictor::write(BUSTYPE tr).
  virtual function void write(qspi_apb_item_t tr);
    if (tr == null || tr.reset_abort || tr.slverr !== 1'b0 ||
        $isunknown({tr.addr, tr.write, tr.strb}) || map == null) return;
    if (map.get_reg_by_offset(tr.addr, !tr.write) == null) return;
    super.write(tr);
  endfunction
endclass : qspi_apb_reg_predictor
`endif
