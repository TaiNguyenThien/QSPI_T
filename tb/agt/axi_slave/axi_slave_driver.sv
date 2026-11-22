`ifndef AXI_SLAVE_DRIVER_SV
`define AXI_SLAVE_DRIVER_SV

class axi_slave_driver extends uvm_component;
  `uvm_component_utils(axi_slave_driver)

  axi_slave_cfg          cfg;
  virtual axi_if         axi_vif;
  virtual clk_rst_irq_if clk_vif;

  // Byte-addressable slave memory model
  bit [7:0] mem[longint unsigned];

  // Write address information (captured per write request)
  bit [31:0] awaddr;
  bit [7:0]  awlen;
  bit [2:0]  awsize;
  bit [1:0]  awburst;

  // Write data queues (captured per write request)
  bit [31:0] wdata_queue[$];
  bit [3:0]  wstrb_queue[$];
  bit        wlast_queue[$];

  // Per-request frozen response/delay snapshot so mid-burst knob changes never corrupt active bursts
  protected bit [1:0]    req_bresp;
  protected bit [1:0]    req_rresp;
  protected int unsigned req_awready_delay;
  protected int unsigned req_wready_delay;
  protected int unsigned req_arready_delay;
  protected int unsigned req_bvalid_delay;
  protected int unsigned req_rvalid_delay;
  protected int          req_inject_error_beat;

  function new(string name = "axi_slave_driver", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db #(axi_slave_cfg)::get(this, "", "cfg", cfg));
    if (cfg != null) begin
      if (axi_vif == null) axi_vif = cfg.axi_vif;
      if (clk_vif == null) clk_vif = cfg.clk_vif;
    end
    if (axi_vif == null && !uvm_config_db #(virtual axi_if)::get(this, "", "axi_vif", axi_vif))
      `uvm_fatal("AXI_DRV", "Cannot get axi_vif")
    if (clk_vif == null && !uvm_config_db #(virtual clk_rst_irq_if)::get(this, "", "clk_vif", clk_vif))
      `uvm_fatal("AXI_DRV", "Cannot get clk_vif")
  endfunction

  protected function void snapshot_request_knobs();
    if (cfg != null) begin
      req_bresp             = cfg.default_bresp;
      req_rresp             = cfg.default_rresp;
      req_awready_delay     = cfg.awready_delay_knob;
      req_wready_delay      = cfg.wready_delay_knob;
      req_arready_delay     = cfg.arready_delay_knob;
      req_bvalid_delay      = cfg.bvalid_delay_knob;
      req_rvalid_delay      = cfg.rvalid_delay_knob;
      req_inject_error_beat = cfg.inject_error_beat;
    end else begin
      req_bresp             = 2'b00;
      req_rresp             = 2'b00;
      req_awready_delay     = 0;
      req_wready_delay      = 0;
      req_arready_delay     = 0;
      req_bvalid_delay      = 0;
      req_rvalid_delay      = 0;
      req_inject_error_beat = -1;
    end
  endfunction

  task run_phase(uvm_phase phase);
    reset_signals();

    forever begin
      wait (clk_vif.rst_n === 1'b1);

      fork
        begin : request_thread
          @(negedge clk_vif.clk);

          wait (axi_vif.m_awvalid === 1'b1 || axi_vif.m_wvalid === 1'b1 || axi_vif.m_arvalid === 1'b1);

          if (axi_vif.m_arvalid && (axi_vif.m_awvalid || axi_vif.m_wvalid)) begin
            `uvm_error("AXI_DRV", "Read and write requests overlap")
            if (axi_vif.m_arvalid)
              read_handler();
          end else if (axi_vif.m_awvalid || axi_vif.m_wvalid) begin
            write_handler();
          end else if (axi_vif.m_arvalid) begin
            read_handler();
          end
        end
        begin : reset_watcher
          wait (clk_vif.rst_n === 1'b0);
        end
      join_any
      disable fork;
      reset_signals();
    end
  endtask

  task reset_signals();
    axi_vif.m_awready = 1'b0;
    axi_vif.m_wready  = 1'b0;
    axi_vif.m_bvalid  = 1'b0;
    axi_vif.m_bresp   = 2'b00;

    axi_vif.m_arready = 1'b0;
    axi_vif.m_rvalid  = 1'b0;
    axi_vif.m_rdata   = 32'h0;
    axi_vif.m_rresp   = 2'b00;
    axi_vif.m_rlast   = 1'b0;
  endtask

  // WRITE HANDLER
  task write_handler();
    int unsigned num_beats;

    snapshot_request_knobs();
    wdata_queue.delete();
    wstrb_queue.delete();
    wlast_queue.delete();

    fork
      capture_aw();
      capture_w();
    join

    if (clk_vif.rst_n !== 1'b1) return;

    num_beats = awlen + 1;

    if (awburst != 2'b01)
      `uvm_error("AXI_WRITE", $sformatf("Unsupported AWBURST = %b", awburst))

    if (awsize != 3'b010)
      `uvm_error("AXI_WRITE", $sformatf("Unsupported AWSIZE = %b", awsize))

    if (wdata_queue.size() != num_beats)
      `uvm_error("AXI_WRITE", $sformatf("Expected %0d beats, received %0d beats", num_beats, wdata_queue.size()))

    // Only commit write bytes to slave RAM when response is OKAY (2'b00)
    if (req_bresp == 2'b00) begin
      for (int beat = 0; beat < wdata_queue.size(); beat++) begin
        for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
          if (wstrb_queue[beat][byte_idx]) begin
            mem[longint'(awaddr) + beat * 4 + byte_idx] = wdata_queue[beat][byte_idx*8 +: 8];
          end
        end
      end
    end

    for (int beat = 0; beat < wdata_queue.size(); beat++) begin
      if (beat == num_beats - 1) begin
        if (!wlast_queue[beat])
          `uvm_error("AXI_WRITE", "WLAST missing on final beat")
      end else begin
        if (wlast_queue[beat])
          `uvm_error("AXI_WRITE", "WLAST asserted before final beat")
      end
    end

    `uvm_info("AXI_WRITE", $sformatf("Write completed: ADDR=0x%08h, BEATS=%0d BRESP=%02b",
              awaddr, num_beats, req_bresp), UVM_HIGH)

    send_bresp();
  endtask

  task capture_aw();
    if (req_awready_delay > 0) begin
      repeat (req_awready_delay) @(posedge clk_vif.clk);
      @(negedge clk_vif.clk);
    end else if (axi_vif.m_awvalid !== 1'b1) begin
      @(negedge clk_vif.clk);
    end
    axi_vif.m_awready = 1'b1;

    do begin
      @(posedge clk_vif.clk);
      if (clk_vif.rst_n !== 1'b1) return;
    end while (!(axi_vif.m_awvalid && axi_vif.m_awready));

    awaddr  = axi_vif.m_awaddr;
    awlen   = axi_vif.m_awlen;
    awsize  = axi_vif.m_awsize;
    awburst = axi_vif.m_awburst;

    @(negedge clk_vif.clk);
    axi_vif.m_awready = 1'b0;
  endtask

  task capture_w();
    bit got_wlast;
    got_wlast = 1'b0;

    while (!got_wlast) begin
      if (req_wready_delay > 0)
        repeat (req_wready_delay) @(posedge clk_vif.clk);

      @(negedge clk_vif.clk);
      axi_vif.m_wready = 1'b1;

      do begin
        @(posedge clk_vif.clk);
        if (clk_vif.rst_n !== 1'b1) return;
      end while (!(axi_vif.m_wvalid && axi_vif.m_wready));

      wdata_queue.push_back(axi_vif.m_wdata);
      wstrb_queue.push_back(axi_vif.m_wstrb);
      wlast_queue.push_back(axi_vif.m_wlast);
      got_wlast = axi_vif.m_wlast;

      @(negedge clk_vif.clk);
      axi_vif.m_wready = 1'b0;
    end
  endtask

  task send_bresp();
    if (req_bvalid_delay > 0)
      repeat (req_bvalid_delay) @(posedge clk_vif.clk);

    @(negedge clk_vif.clk);
    axi_vif.m_bresp  = req_bresp;
    axi_vif.m_bvalid = 1'b1;

    do begin
      @(posedge clk_vif.clk);
      if (clk_vif.rst_n !== 1'b1) return;
    end while (!(axi_vif.m_bvalid && axi_vif.m_bready));

    @(negedge clk_vif.clk);
    axi_vif.m_bvalid = 1'b0;
    axi_vif.m_bresp  = 2'b00;
  endtask

  // READ HANDLER
  task read_handler();
    bit [31:0] araddr;
    bit [7:0]  arlen;
    bit [2:0]  arsize;
    bit [1:0]  arburst;
    bit [31:0] read_data;
    bit        saw_rresp_err;

    snapshot_request_knobs();
    saw_rresp_err = 1'b0;

    if (req_arready_delay > 0)
      repeat (req_arready_delay) @(posedge clk_vif.clk);

    @(negedge clk_vif.clk);
    axi_vif.m_arready = 1'b1;

    do begin
      @(posedge clk_vif.clk);
      if (clk_vif.rst_n !== 1'b1) return;
    end while (!(axi_vif.m_arvalid && axi_vif.m_arready));

    araddr  = axi_vif.m_araddr;
    arlen   = axi_vif.m_arlen;
    arsize  = axi_vif.m_arsize;
    arburst = axi_vif.m_arburst;

    @(negedge clk_vif.clk);
    axi_vif.m_arready = 1'b0;

    if (arburst != 2'b01)
      `uvm_error("AXI_READ", $sformatf("Unsupported ARBURST = %b", arburst))

    if (arsize != 3'b010)
      `uvm_error("AXI_READ", $sformatf("Unsupported ARSIZE = %b", arsize))

    for (int beat = 0; beat <= arlen; beat++) begin
      int unsigned err_abort_wait;
      bit          reported_err_stall;
      err_abort_wait     = 0;
      reported_err_stall = 1'b0;

      read_data = 32'h0;
      for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
        if (mem.exists(longint'(araddr) + beat * 4 + byte_idx))
          read_data[byte_idx*8 +: 8] = mem[longint'(araddr) + beat * 4 + byte_idx];
        else
          read_data[byte_idx*8 +: 8] = 8'h00;
      end

      if (req_rvalid_delay > 0)
        repeat (req_rvalid_delay) @(posedge clk_vif.clk);

      @(negedge clk_vif.clk);
      axi_vif.m_rdata  = read_data;
      if (req_inject_error_beat >= 0)
        axi_vif.m_rresp = (beat == req_inject_error_beat) ? req_rresp : 2'b00;
      else
        axi_vif.m_rresp = req_rresp;
      axi_vif.m_rlast  = (beat == arlen);
      axi_vif.m_rvalid = 1'b1;

      // AMBA AXI4 A3.2.1: Slave must hold RVALID stable until RREADY handshake or reset.
      do begin
        @(posedge clk_vif.clk);
        if (clk_vif.rst_n !== 1'b1) return;
        if (!(axi_vif.m_rvalid && axi_vif.m_rready) && saw_rresp_err) begin
          err_abort_wait++;
          if (err_abort_wait == 128 && !reported_err_stall) begin
            reported_err_stall = 1'b1;
            `uvm_warning("AXI_DRV_READ_STALL", $sformatf(
              "AXI master stalled RREADY >= 128 cycles after RRESP error on beat %0d/%0d (holding RVALID per AXI4)",
              beat, arlen + 1))
          end
        end
      end while (!(axi_vif.m_rvalid && axi_vif.m_rready));

      if (axi_vif.m_rresp == 2'b10 || axi_vif.m_rresp == 2'b11)
        saw_rresp_err = 1'b1;

      @(negedge clk_vif.clk);
      axi_vif.m_rvalid = 1'b0;
      axi_vif.m_rlast  = 1'b0;
    end

    @(negedge clk_vif.clk);
    axi_vif.m_rvalid = 1'b0;
    axi_vif.m_rlast  = 1'b0;
    axi_vif.m_rdata  = 32'h0;
    axi_vif.m_rresp  = 2'b00;

    `uvm_info("AXI_READ", $sformatf("Read completed: ADDR=0x%08h, BEATS=%0d", araddr, arlen + 1), UVM_HIGH)
  endtask

  task write_mem(bit [31:0] addr, bit [7:0] data);
    mem[longint'(addr)] = data;
  endtask

  function bit [7:0] read_mem(bit [31:0] addr);
    if (mem.exists(longint'(addr)))
      return mem[longint'(addr)];
    else
      return 8'h00;
  endfunction

  function void clear_mem();
    mem.delete();
  endfunction

endclass : axi_slave_driver

`endif // AXI_SLAVE_DRIVER_SV
