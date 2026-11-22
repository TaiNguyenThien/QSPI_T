`ifndef QSPI_BASE_VSEQ_SV
`define QSPI_BASE_VSEQ_SV

// A single raw APB transfer; register-specific expectations belong to passive checkers.
class qspi_apb_raw_seq extends qspi_apb_base_seq_t;
  `uvm_object_utils(qspi_apb_raw_seq)
  typedef qspi_apb_item_t apb_item_t;
  bit          do_write;
  bit [11:0]   address;
  bit [31:0]   data;
  bit [3:0]    strb;
  bit [2:0]    protection;
  int unsigned idle_cycles = 0;
  apb_item_t   result;

  function new(string name = "qspi_apb_raw_seq");
    super.new(name);
  endfunction

  task body();
    apb_item_t req;
    req = apb_item_t::type_id::create("req");
    start_item(req);
    req.write       = do_write;
    req.addr        = address;
    req.wdata       = do_write ? data : '0;
    req.strb        = do_write ? strb : '0;
    req.prot        = protection;
    req.idle_cycles = idle_cycles;
    finish_item(req);
    result = req;
  endtask
endclass : qspi_apb_raw_seq

// Shared base virtual sequence across PIO, DMA, and XIP modes.
// Centralizes RAL/APB CSR access, reset-abort handling, and top reset requests.
class qspi_base_vseq extends uvm_sequence #(uvm_sequence_item);
  `uvm_object_utils(qspi_base_vseq)
  `uvm_declare_p_sequencer(qspi_vsequencer)

  typedef apb_single_read_seq  #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) read_seq_t;
  typedef apb_single_write_seq #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) write_seq_t;

  bit allow_reset_abort;
  bit reset_aborted;
  bit check_read_data_known;

  function new(string name = "qspi_base_vseq");
    super.new(name);
    allow_reset_abort     = 1'b0;
    reset_aborted         = 1'b0;
    check_read_data_known = 1'b0;
  endfunction

  virtual task pre_body();
    if (p_sequencer == null || p_sequencer.cfg == null ||
        p_sequencer.cfg.clk_vif == null || p_sequencer.apb_seqr == null ||
        p_sequencer.mem_svc == null)
      `uvm_fatal("QSPI_VSEQ_BIND",
        "Virtual sequence requires active qspi_vsequencer (cfg, clk_vif, apb_seqr, mem_svc)")
  endtask

  // Bus acceptance/progress is required to execute stimulus. Functional data,
  // CSR, IRQ, and timing expectations remain in passive project checkers.
  virtual task read_csr(
    input  bit [QSPI_APB_ADDR_WIDTH-1:0] address,
    output logic [31:0]                  data
  );
    read_seq_t     s;
    uvm_reg        r;
    uvm_status_e   status;
    uvm_reg_data_t value;

    if (allow_reset_abort && p_sequencer.cfg.clk_vif.rst_n !== 1'b1)
      reset_aborted = 1'b1;
    if (reset_aborted) begin
      data = 32'h0;
      return;
    end

    r = (p_sequencer.ral_model != null) ?
        p_sequencer.ral_model.get_fixed_csr(qspi_reg_offset_t'(address), 1'b1) : null;
    // Reset-abort scenarios keep the raw item's explicit reset_abort result.
    // A RAL read performs a frontdoor bus access, never a mirror-only get().
    if (r != null && !allow_reset_abort) begin
      r.read(status, value, UVM_FRONTDOOR,
             p_sequencer.ral_model.default_map, this);
      data = value[31:0];
      if (status != UVM_IS_OK && !(status == UVM_HAS_X && !check_read_data_known))
        `uvm_fatal("QSPI_VSEQ_RAL_RD", $sformatf(
          "Cannot execute RAL read at 0x%03h (status=%s)", address, status.name()))
      if (check_read_data_known && $isunknown(data))
        `uvm_fatal("QSPI_VSEQ_RAL_RD", $sformatf("Unknown CSR read at 0x%03h", address))
      return;
    end

    s      = read_seq_t::type_id::create("vseq_apb_read");
    s.addr = address;
    s.prot = 3'b000;
    s.start(p_sequencer.apb_seqr, this);
    if (s.result != null && s.result.reset_abort && allow_reset_abort) begin
      reset_aborted = 1'b1;
      data          = 32'h0;
      return;
    end
    if (s.result == null || s.result.reset_abort || s.result.slverr !== 1'b0)
      `uvm_fatal("QSPI_VSEQ_APB_RD", $sformatf("Cannot execute read at 0x%03h", address))
    data = s.result.rdata;
    if (check_read_data_known && address != QSPI_REG_READ_RX && $isunknown(data))
      `uvm_fatal("QSPI_VSEQ_APB_RD", $sformatf("Cannot use unknown software read at 0x%03h", address))
  endtask

  virtual task write_csr(
    input bit [QSPI_APB_ADDR_WIDTH-1:0] address,
    input logic [31:0]                  data,
    input logic [3:0]                   strb = 4'hF
  );
    write_seq_t  s;
    uvm_reg      r;
    uvm_status_e status;

    if (allow_reset_abort && p_sequencer.cfg.clk_vif.rst_n !== 1'b1)
      reset_aborted = 1'b1;
    if (reset_aborted) return;

    r = (p_sequencer.ral_model != null) ?
        p_sequencer.ral_model.get_fixed_csr(qspi_reg_offset_t'(address), 1'b0) : null;
    // Whole-register writes use RAL. Explicit partial strobes remain raw APB
    // because uvm_reg::write does not expose the bus byte-enable argument.
    if (r != null && strb === 4'hF && !allow_reset_abort) begin
      r.write(status, uvm_reg_data_t'(data), UVM_FRONTDOOR,
              p_sequencer.ral_model.default_map, this);
      if (status != UVM_IS_OK)
        `uvm_fatal("QSPI_VSEQ_RAL_WR", $sformatf(
          "Cannot execute RAL write at 0x%03h wdata=0x%08h (status=%s)",
          address, data, status.name()))
      return;
    end

    s      = write_seq_t::type_id::create("vseq_apb_write");
    s.addr = address;
    s.data = data;
    s.strb = strb;
    s.prot = 3'b000;
    s.start(p_sequencer.apb_seqr, this);
    if (s.result != null && s.result.reset_abort && allow_reset_abort) begin
      reset_aborted = 1'b1;
      return;
    end
    if (s.result == null || s.result.reset_abort || s.result.slverr !== 1'b0)
      `uvm_fatal("QSPI_VSEQ_APB_WR", $sformatf(
        "Cannot execute write at 0x%03h wdata=0x%08h strb=%04b", address, data, strb))
  endtask

  // Request the top's reset service; no protocol agent drives clocks/reset.
  protected task do_request_reset(input int unsigned settle_cycles);
    p_sequencer.cfg.reset_request.trigger();
    wait (p_sequencer.cfg.clk_vif.rst_n === 1'b0);
    wait (p_sequencer.cfg.clk_vif.rst_n === 1'b1);
    repeat (settle_cycles) @(posedge p_sequencer.cfg.clk_vif.clk);
  endtask

  virtual task request_reset();
    do_request_reset(2);
  endtask
endclass : qspi_base_vseq

`endif // QSPI_BASE_VSEQ_SV
