// Drives one APB request at a time; DUT checking belongs to monitor/SVA.
class apb_driver #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_driver #(apb_trans #(ADDR_WIDTH, DATA_WIDTH));
  `uvm_component_param_utils(apb_driver #(ADDR_WIDTH, DATA_WIDTH))

  typedef apb_trans #(ADDR_WIDTH, DATA_WIDTH) trans_t;
  typedef apb_cfg #(ADDR_WIDTH, DATA_WIDTH) cfg_t;

  cfg_t cfg;
  uvm_analysis_port #(trans_t) completed_ap;

  function new(string name = "apb_driver", uvm_component parent = null);
    super.new(name, parent);
    completed_ap=new("completed_ap",this);
  endfunction


  protected function bit reset_active();
    return cfg.apb_vif.rst_n !== 1'b1;
  endfunction

  protected task drive_idle();
    cfg.apb_vif.psel    <= 1'b0;
    cfg.apb_vif.penable <= 1'b0;
    cfg.apb_vif.pwrite  <= 1'b0;
    cfg.apb_vif.paddr   <= '0;
    cfg.apb_vif.pwdata  <= '0;
    cfg.apb_vif.pstrb   <= '0;
    cfg.apb_vif.pprot   <= '0;
  endtask

  protected task drive_setup(input trans_t req);
    cfg.apb_vif.psel    <= 1'b1;
    cfg.apb_vif.penable <= 1'b0;
    cfg.apb_vif.pwrite  <= req.write;
    cfg.apb_vif.paddr   <= req.addr;
    cfg.apb_vif.pwdata  <= req.wdata;
    cfg.apb_vif.pstrb   <= req.strb;
    cfg.apb_vif.pprot   <= req.prot;
  endtask

  protected task wait_clock_or_reset(output bit reset_seen);
    reset_seen = 1'b0;
    fork
      begin : isolated_clock_wait
        fork
          begin
            @(posedge cfg.apb_vif.clk);
          end
          begin
            wait (cfg.apb_vif.rst_n !== 1'b1);
            reset_seen = 1'b1;
          end
        join_any
        disable fork;
      end
    join
  endtask

  // Align SETUP to a rising edge unless this item was accepted immediately
  // after a completion edge and can use that edge's NBA update. An idle gap
  // is measured as complete clock intervals with the bus held IDLE.
  protected task prepare_setup(
    input trans_t       req,
    input int unsigned  idle_cycles,
    input bit           item_at_completion_edge,
    input bit           setup_now,
    output bit          setup_started
  );
    bit reset_seen;

    setup_started = 1'b0;
    if (reset_active())
      return;

    if (setup_now && idle_cycles == 0) begin
      drive_setup(req);
      setup_started = 1'b1;
      return;
    end

    // A request acquired between clock edges is aligned by the first future
    // edge. A request obtained at a completion edge can begin its gap on that
    // edge, but only an enabled zero-gap request may start SETUP immediately.
    drive_idle();
    if (!item_at_completion_edge) begin
      wait_clock_or_reset(reset_seen);
      if (reset_seen || reset_active())
        return;
    end

    repeat (idle_cycles) begin
      wait_clock_or_reset(reset_seen);
      if (reset_seen || reset_active())
        return;
    end

    // A same-edge request with zero idle cycles but back-to-back disabled must
    // wait for the next edge; the preceding drive_idle() is not SETUP.
    if (item_at_completion_edge && !setup_now && idle_cycles == 0) begin
      wait_clock_or_reset(reset_seen);
      if (reset_seen || reset_active())
        return;
    end

    if (reset_active())
      return;
    drive_setup(req);
    setup_started = 1'b1;
  endtask

  // Complete one transfer, returning only when the handshake is observed or
  // reset becomes active. Unknown PREADY is deliberately treated as a wait.
  protected task drive_transfer(
    input trans_t       req,
    input int unsigned  idle_cycles,
    input bit           item_at_completion_edge,
    input bit           setup_now,
    output bit          completed
  );
    bit setup_started;

    completed = 1'b0;
    setup_started = 1'b0;
    if (reset_active())
      return;

    prepare_setup(req, idle_cycles, item_at_completion_edge, setup_now,
                 setup_started);
    if (!setup_started)
      return;
    req.setup_started=1;

    @(posedge cfg.apb_vif.clk);
    if (reset_active())
      return;
    cfg.apb_vif.penable <= 1'b1;

    forever begin
      @(posedge cfg.apb_vif.clk);
      if (reset_active())
        return;

      if (cfg.apb_vif.pready === 1'b1) begin
        // Give reset priority if it is already observable at this sampling
        // point; otherwise this edge is the APB completion edge.
        if (reset_active())
          return;
        req.slverr = cfg.apb_vif.pslverr;
        if (!req.write)
          req.rdata = cfg.apb_vif.prdata;
        completed = 1'b1;
        return;
      end

      // This is a verification timeout, not an APB protocol rule. Count both
      // a driven zero and an unknown PREADY; only a known one completes.
      req.wait_cycles++;
      if (cfg.max_wait_cycles != 0 &&
          req.wait_cycles >= cfg.max_wait_cycles)
        `uvm_fatal("APB_DRV_WATCHDOG", $sformatf(
          "ACCESS timeout addr=%0h wait=%0d",
          req.addr, req.wait_cycles))
    end
  endtask

  protected task wait_reset_asserted();
    wait (cfg.apb_vif.rst_n !== 1'b1);
  endtask

  // Keep reset arbitration scoped to this transfer. The reset branch also
  // drives IDLE so a reset cannot leave a stale ACCESS phase on the bus.
  protected task execute_transfer(
    input trans_t       req,
    input int unsigned  idle_cycles,
    input bit           item_at_completion_edge,
    input bit           setup_now,
    output bit          completed,
    output bit          reset_seen
  );
    completed = 1'b0;
    reset_seen = 1'b0;
    fork
      begin : isolated_transfer
        fork
          begin : transfer_thread
            drive_transfer(req, idle_cycles, item_at_completion_edge, setup_now,
                           completed);
          end
          begin : reset_thread
            wait_reset_asserted();
            reset_seen = 1'b1;
            req.abort_in_access = cfg.apb_vif.penable === 1'b1;
            drive_idle();
          end
        join_any
        disable fork;
      end
    join
    if (reset_seen || reset_active()) begin
      completed = 1'b0;
      drive_idle();
    end
  endtask

  function void publish_result(trans_t req);
    trans_t snapshot;
    snapshot=trans_t::type_id::create("driver_result");
    req.completed_at=$time;
    snapshot.copy(req);
    completed_ap.write(snapshot);
  endfunction

  virtual task run_phase(uvm_phase phase);
    trans_t curr_req;
    trans_t next_req;
    bit transfer_done;
    bit reset_seen;
    bit item_at_completion_edge;
    bit setup_now;
    int unsigned idle_cycles;

    curr_req = null;
    item_at_completion_edge = 1'b0;
    drive_idle();

    forever begin
      // Do not drive a request while reset is unavailable. A request can
      // still be returned by a blocking get_next_item during reset, so the
      // post-arbitration check below remains necessary.
      if (reset_active()) begin
        item_at_completion_edge = 1'b0;
        // Retire items queued during reset as aborted. Holding them until
        // release can replay an old FIFO access into the new reset epoch.
        if (curr_req==null) seq_item_port.try_next_item(curr_req);
        if (curr_req==null) begin
          @(posedge cfg.apb_vif.clk or posedge cfg.apb_vif.rst_n);
          continue;
        end
      end

      if (curr_req == null) begin
        item_at_completion_edge = 1'b0;
        seq_item_port.get_next_item(curr_req);
      end

      // These fields are execution metadata on the driver-owned sequence
      // handle. The monitor independently fills its published observation.
      curr_req.rdata       = '0;
      curr_req.slverr      = 1'b0;
      curr_req.reset_abort = 1'b0;
      curr_req.abort_in_access = 1'b0;
      curr_req.wait_cycles = 0;
      curr_req.back_to_back = 1'b0;
      curr_req.setup_started = 0;

      // Reset may assert while get_next_item() is blocked. Retire the item
      // without driving SETUP if reset is active when arbitration returns.
      if (reset_active()) begin
        curr_req.reset_abort = 1'b1;
        curr_req.rdata       = '0;
        curr_req.slverr      = 1'b0;
        drive_idle();
        publish_result(curr_req);
        seq_item_port.item_done();
        curr_req = null;
        item_at_completion_edge = 1'b0;
        continue;
      end

      // The request's own gap is applied before its SETUP. The configured
      // inter-transfer gap is only a fallback after a prior completion.
      idle_cycles = curr_req.idle_cycles;
      if (item_at_completion_edge && idle_cycles == 0)
        idle_cycles = cfg.inter_transfer_idle_cycles;
      if (item_at_completion_edge && !cfg.enable_back_to_back &&
          idle_cycles == 0)
        idle_cycles = 1;

      // Only a request obtained by try_next_item() at the completion edge may
      // start SETUP on that same edge. Requests with a nonzero gap still begin
      // their gap on that edge, even though they are not back-to-back.
      setup_now = item_at_completion_edge && cfg.enable_back_to_back &&
                  idle_cycles == 0;
      curr_req.back_to_back = setup_now;

      transfer_done = 1'b0;
      reset_seen = 1'b0;
      execute_transfer(curr_req, idle_cycles, item_at_completion_edge,
                       setup_now, transfer_done, reset_seen);

      // Reset arbitration reports an abort even if reset deasserts before this
      // task returns. This avoids losing a reset pulse between clock samples.
      if (reset_seen || reset_active())
        transfer_done = 1'b0;

      if (!transfer_done) begin
        curr_req.reset_abort = 1'b1;
        curr_req.rdata       = '0;
        curr_req.slverr      = 1'b0;
        `uvm_info("APB_DRV_RESET", $sformatf(
          "Reset aborted addr=%0h write=%0b",
          curr_req.addr, curr_req.write), UVM_MEDIUM)
        drive_idle();
        publish_result(curr_req);
        seq_item_port.item_done();
        curr_req = null;
        item_at_completion_edge = 1'b0;
        continue;
      end

      if (curr_req.write) begin
        if (curr_req.strb != 4'hf)
          `uvm_info("apb_driver", $sformatf("APB write to addr =0x%03x wdata=0x%0x strb=%04b", curr_req.addr, curr_req.wdata, curr_req.strb), UVM_HIGH)
        else
          `uvm_info("apb_driver", $sformatf("APB write to addr =0x%03x wdata=0x%0x", curr_req.addr, curr_req.wdata), UVM_HIGH)
      end
      `uvm_info("APB_DRV", curr_req.sprint(), UVM_HIGH)
      publish_result(curr_req);
      seq_item_port.item_done();

      // Probe immediately after completion so an available request can use
      // the next cycle's SETUP phase. Its own idle_cycles is applied at the
      // top of the next loop, before that request is driven.
      next_req = null;
      seq_item_port.try_next_item(next_req);
      curr_req = null;
      if (next_req != null) begin
        curr_req = next_req;
        item_at_completion_edge = 1'b1;
        continue;
      end

      // No request is queued. The bus is already idle; a later request is
      // aligned to a future edge rather than treated as same-edge back-to-back.
      drive_idle();
      item_at_completion_edge = 1'b0;
    end
  endtask
endclass
