// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_master_driver.sv
// Role   : Enterprise Decoupled AR/R Driver for AXI4-Lite Master Agent
// Spec   : ARM AMBA AXI4-Lite Protocol & VNCHIP Spec Rev 1.0 (Section 3.3, 5.7)
// =============================================================================

`ifndef AXIL_MASTER_DRIVER_SV
`define AXIL_MASTER_DRIVER_SV

class axil_master_driver extends uvm_driver #(axil_master_transaction);
  `uvm_component_utils(axil_master_driver)

  axil_master_cfg         cfg;
  axil_master_transaction pending_r_q[$];
  axil_master_transaction active_ar_req;
  realtime                last_ar_hs_time     = -1.0;
  bit                     ar_wedged           = 1'b0;
  bit                     ar_expected_timeout = 1'b0;
  bit                     r_wedged            = 1'b0;
  int unsigned            orphan_r_pending    = 0;
  bit                     in_reset            = 1'b1;
  bit                     reset_recovery_done = 1'b0;
  bit                     reset_pulse_active  = 1'b0;
  bit                     arvalid_driven      = 1'b0;
  bit                     rready_driven       = 1'b0;
  longint unsigned        current_epoch       = 0;
  longint unsigned        aclk_cycle_cnt      = 0;

  event                   cycle_advanced;
  event                   reset_asserted_ev;
  event                   reset_deasserted_ev;
  event                   pending_r_ev;
  semaphore               reg_lock;

  function new(string name = "axil_master_driver", uvm_component parent = null);
    super.new(name, parent);
    reg_lock = new(1);
  endfunction

  // Synchronous idle drive via clocking block
  task automatic drive_cb_idle();
    cfg.vif.master_cb.araddr  <= '0;
    cfg.vif.master_cb.arprot  <= '0;
    cfg.vif.master_cb.arvalid <= 1'b0;
    cfg.vif.master_cb.rready  <= 1'b0;
    arvalid_driven            = 1'b0;
    rready_driven             = 1'b0;
  endtask

  function automatic void init_req_status(axil_master_transaction req);
    req.data               = '0;
    req.resp               = '0;
    req.completion_status  = AXIL_STATUS_IDLE;
    req.reset_abort        = 1'b0;
    req.timed_out          = 1'b0;
    req.ar_accepted        = 1'b0;
    req.r_completed        = 1'b0;
    req.driver_done        = 1'b0;
    req.ar_wait            = 0;
    req.r_stall            = 0;
    req.birth_epoch        = current_epoch;
    req.abort_epoch        = 0;
    req.ar_accept_cycle    = 0;
    req.first_rvalid_cycle = 0;
    req.r_complete_cycle   = 0;
  endfunction

  function automatic void sync_req_from_ctx(axil_master_transaction req, axil_master_transaction ctx);
    req.data               = ctx.data;
    req.resp               = ctx.resp;
    req.completion_status  = ctx.completion_status;
    req.reset_abort        = ctx.reset_abort;
    req.timed_out          = ctx.timed_out;
    req.ar_accepted        = ctx.ar_accepted;
    req.r_completed        = ctx.r_completed;
    req.driver_done        = 1'b1;
    req.ar_wait            = ctx.ar_wait;
    req.r_stall            = ctx.r_stall;
    req.birth_epoch        = ctx.birth_epoch;
    req.abort_epoch        = ctx.abort_epoch;
    req.ar_accept_cycle    = ctx.ar_accept_cycle;
    req.first_rvalid_cycle = ctx.first_rvalid_cycle;
    req.r_complete_cycle   = ctx.r_complete_cycle;
  endfunction

  function void finish_once(axil_master_transaction ctx);
    axil_master_transaction rsp;
    if (ctx == null || ctx.driver_done) return;
    ctx.driver_done = 1'b1;
    if (ctx.pipeline_ar) begin
      if (!$cast(rsp, ctx.clone()))
        `uvm_fatal("AXIL_RSP_CLONE", "Cannot create response object")
      rsp.set_id_info(ctx);
      seq_item_port.put_response(rsp);
    end
  endfunction

  function automatic void abort_active_ar();
    if (active_ar_req != null && !active_ar_req.driver_done) begin
      active_ar_req.reset_abort       = 1'b1;
      active_ar_req.completion_status = AXIL_STATUS_RESET_ABORT;
      active_ar_req.abort_epoch       = current_epoch;
      finish_once(active_ar_req);
    end
  endfunction

  // Shared recovery barrier: checks physical reset under reg_lock BEFORE any abort
  // so re-assertion yields to epoch increment instead of aborting with stale epoch.
  task automatic recovery_barrier();
    while (1) begin
      reg_lock.get(1);
      if (cfg.vif.aresetn !== 1'b1) begin
        reg_lock.put(1);
        break;
      end
      if (active_ar_req != null && !active_ar_req.driver_done) begin
        abort_active_ar();
      end
      if (active_ar_req == null) begin
        in_reset            = 1'b0;
        reset_pulse_active  = 1'b0;
        reset_recovery_done = 1'b1;
        -> reset_deasserted_ev;
        reg_lock.put(1);
        break;
      end
      reg_lock.put(1);
      wait (active_ar_req == null || cfg.vif.aresetn !== 1'b1);
    end
  endtask

  // Dedicated authoritative ACLK cycle counter
  task automatic clock_tracker();
    forever begin
      @(cfg.vif.master_cb);
      aclk_cycle_cnt++;
      -> cycle_advanced;
    end
  endtask

  // Dedicated background watcher: holds AR stable on bus until handshake or reset (ARM AXI §A3.2.2 & a_ar_stable)
  task automatic ar_hold_watcher();
    forever begin
      @(cycle_advanced);
      if (ar_wedged && arvalid_driven && !in_reset) begin
        if (cfg.vif.master_cb.arready === 1'b1) begin
          // Deassert ARVALID on the very first handshake, preventing duplicate requests
          cfg.vif.master_cb.arvalid <= 1'b0;
          arvalid_driven            = 1'b0;
          if (ar_expected_timeout) begin
            orphan_r_pending++;
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Read Address Channel (AR) Phase with Clocking Block & Dynamic Timeout
  // ---------------------------------------------------------------------------
  task automatic drive_ar_phase(axil_master_transaction req, output bit ar_accepted);
    longint unsigned ar_budget;
    ar_accepted = 1'b0;

    ar_budget = (req.has_timeout_override && req.ar_timeout_override > 0) ?
                req.ar_timeout_override : cfg.default_ar_timeout_cycles;

    if ($realtime != last_ar_hs_time) begin
      @(cycle_advanced or reset_asserted_ev);
    end

    if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged || req.reset_abort || req.birth_epoch != current_epoch) begin
      return;
    end

    if (req.ar_delay > 0) begin
      cfg.vif.master_cb.arvalid <= 1'b0;
      arvalid_driven            = 1'b0;
      repeat (req.ar_delay) begin
        @(cycle_advanced or reset_asserted_ev);
        if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged || req.reset_abort || req.birth_epoch != current_epoch) return;
      end
    end

    if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged || req.reset_abort || req.birth_epoch != current_epoch) begin
      return;
    end

    cfg.vif.master_cb.araddr  <= req.addr;
    cfg.vif.master_cb.arprot  <= req.prot;
    cfg.vif.master_cb.arvalid <= 1'b1;
    arvalid_driven            = 1'b1;

    forever begin
      @(cycle_advanced or reset_asserted_ev);

      if (in_reset || cfg.vif.aresetn !== 1'b1) begin
        return;
      end

      // Priority 1: Check physical handshake on the bus
      if (cfg.vif.master_cb.arready === 1'b1) begin
        ar_accepted               = 1'b1;
        req.ar_accepted           = 1'b1;
        req.ar_accept_cycle       = aclk_cycle_cnt;
        last_ar_hs_time           = $realtime;
        cfg.vif.master_cb.arvalid <= 1'b0;
        arvalid_driven            = 1'b0;
        if (r_wedged) begin
          req.timed_out         = 1'b1;
          req.completion_status = AXIL_STATUS_REJECTED;
        end
        return;
      end

      // Priority 2: Check if R channel wedged while waiting
      if (r_wedged) begin
        req.timed_out         = 1'b1;
        req.completion_status = AXIL_STATUS_REJECTED;
        ar_wedged             = 1'b1;
        ar_accepted           = 1'b0;
        return;
      end

      // Priority 3: AR timeout budget check
      req.ar_wait++;
      if (ar_budget != 0 && req.ar_wait >= ar_budget) begin
        req.timed_out         = 1'b1;
        req.completion_status = AXIL_STATUS_AR_TIMEOUT;
        ar_wedged             = 1'b1;
        ar_expected_timeout   = req.expect_ar_timeout;
        ar_accepted           = 1'b0;
        if (req.expect_ar_timeout) begin
          `uvm_info("AXIL_AR_TIMEOUT", $sformatf(
            "Expected AR timeout observed at addr=0x%08h after %0d cycles (budget=%0d); holding ARVALID until handshake or reset",
            req.addr, req.ar_wait, ar_budget), UVM_MEDIUM)
        end else begin
          `uvm_error("AXIL_AR_TIMEOUT", $sformatf(
            "DUT did not accept AR at addr=0x%08h after %0d cycles (budget=%0d); holding AR stable on bus until handshake or reset",
            req.addr, req.ar_wait, ar_budget))
        end
        return;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Read Data Channel (R) Phase with Dynamic Multi-Tiered Timeout
  // ---------------------------------------------------------------------------
  task automatic drive_r_phase(axil_master_transaction req);
    longint unsigned rvalid_budget;
    longint unsigned completion_budget;
    longint unsigned elapsed_from_accept;
    bit              saw_first_rvalid = 1'b0;

    rvalid_budget = (req.has_timeout_override && req.rvalid_timeout_override > 0) ?
                    req.rvalid_timeout_override : cfg.default_rvalid_timeout_cycles;

    completion_budget = (req.has_timeout_override && req.completion_timeout_override > 0) ?
                        req.completion_timeout_override : cfg.default_completion_timeout_cycles;

    // Phase A: Master stall delay before asserting RREADY (if applicable)
    if (req.rready_mode == AXIL_RREADY_POST_VALID && req.ready_delay == 0) begin
      // Zero stall contract: Assert RREADY immediately before waiting for RVALID
      // Handshake occurs on the very first cycle RVALID is asserted (0 stall cycles)
      cfg.vif.master_cb.rready <= 1'b1;
      rready_driven             = 1'b1;
    end else if (req.rready_mode == AXIL_RREADY_POST_VALID) begin
      cfg.vif.master_cb.rready <= 1'b0;
      rready_driven             = 1'b0;
      while (1) begin
        @(cycle_advanced or reset_asserted_ev);
        if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged) return;

        elapsed_from_accept = aclk_cycle_cnt - req.ar_accept_cycle;

        if (cfg.vif.master_cb.rvalid === 1'b1) begin
          if (rvalid_budget == 0 || elapsed_from_accept <= rvalid_budget) begin
            saw_first_rvalid = 1'b1;
            if (req.first_rvalid_cycle == 0) req.first_rvalid_cycle = aclk_cycle_cnt;
            break;
          end else begin
            req.timed_out         = 1'b1;
            req.completion_status = AXIL_STATUS_R_TIMEOUT;
            r_wedged              = 1'b1;
            `uvm_error("AXIL_RVALID_TIMEOUT", $sformatf(
              "DUT asserted RVALID late at addr=0x%08h (%0d cycles > rvalid_budget=%0d)",
              req.addr, elapsed_from_accept, rvalid_budget))
            return;
          end
        end

        if (rvalid_budget != 0 && elapsed_from_accept > rvalid_budget) begin
          req.timed_out         = 1'b1;
          req.completion_status = AXIL_STATUS_R_TIMEOUT;
          r_wedged              = 1'b1;
          `uvm_error("AXIL_RVALID_TIMEOUT", $sformatf(
            "DUT did not assert RVALID at addr=0x%08h after %0d cycles from AR accept (rvalid_budget=%0d)",
            req.addr, elapsed_from_accept, rvalid_budget))
          return;
        end
        if (completion_budget != 0 && elapsed_from_accept > completion_budget) begin
          req.timed_out         = 1'b1;
          req.completion_status = AXIL_STATUS_R_TIMEOUT;
          r_wedged              = 1'b1;
          `uvm_error("AXIL_COMPLETION_TIMEOUT", $sformatf(
            "Read transaction at addr=0x%08h exceeded completion budget (%0d cycles from AR accept)",
            req.addr, completion_budget))
          return;
        end
      end

      // Stall post-valid for exactly ready_delay cycles where RVALID=1 && RREADY=0
      req.r_stall++;
      if (req.ready_delay > 1) begin
        repeat (req.ready_delay - 1) begin
          @(cycle_advanced or reset_asserted_ev);
          if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged) return;
          if (cfg.vif.master_cb.rvalid === 1'b1) req.r_stall++;

          elapsed_from_accept = aclk_cycle_cnt - req.ar_accept_cycle;
          if (completion_budget != 0 && elapsed_from_accept > completion_budget) begin
            req.timed_out         = 1'b1;
            req.completion_status = AXIL_STATUS_R_TIMEOUT;
            r_wedged              = 1'b1;
            `uvm_error("AXIL_COMPLETION_TIMEOUT", $sformatf(
              "Read transaction at addr=0x%08h exceeded completion budget during master stall (%0d cycles)",
              req.addr, completion_budget))
            return;
          end
        end
      end
    end else if (req.ready_delay > 0) begin
      // In PRE_ASSERT mode with initial stall
      cfg.vif.master_cb.rready <= 1'b0;
      rready_driven             = 1'b0;
      repeat (req.ready_delay) begin
        @(cycle_advanced or reset_asserted_ev);
        if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged) return;

        elapsed_from_accept = aclk_cycle_cnt - req.ar_accept_cycle;

        if (cfg.vif.master_cb.rvalid === 1'b1) begin
          if (!saw_first_rvalid) begin
            if (rvalid_budget != 0 && elapsed_from_accept > rvalid_budget) begin
              req.timed_out         = 1'b1;
              req.completion_status = AXIL_STATUS_R_TIMEOUT;
              r_wedged              = 1'b1;
              `uvm_error("AXIL_RVALID_TIMEOUT", $sformatf(
                "DUT asserted RVALID late during ready_delay at addr=0x%08h (%0d cycles > rvalid_budget=%0d)",
                req.addr, elapsed_from_accept, rvalid_budget))
              return;
            end
            saw_first_rvalid = 1'b1;
            if (req.first_rvalid_cycle == 0) req.first_rvalid_cycle = aclk_cycle_cnt;
          end
          req.r_stall++;
        end

        if (!saw_first_rvalid && rvalid_budget != 0 && elapsed_from_accept > rvalid_budget) begin
          req.timed_out         = 1'b1;
          req.completion_status = AXIL_STATUS_R_TIMEOUT;
          r_wedged              = 1'b1;
          `uvm_error("AXIL_RVALID_TIMEOUT", $sformatf(
            "DUT did not assert RVALID at addr=0x%08h after %0d cycles (rvalid_budget=%0d)",
            req.addr, elapsed_from_accept, rvalid_budget))
          return;
        end
        if (completion_budget != 0 && elapsed_from_accept > completion_budget) begin
          req.timed_out         = 1'b1;
          req.completion_status = AXIL_STATUS_R_TIMEOUT;
          r_wedged              = 1'b1;
          `uvm_error("AXIL_COMPLETION_TIMEOUT", $sformatf(
            "Read transaction at addr=0x%08h exceeded completion budget during ready_delay (%0d cycles)",
            req.addr, completion_budget))
          return;
        end
      end
    end

    if (in_reset || cfg.vif.aresetn !== 1'b1 || r_wedged) return;

    // Phase B: Assert RREADY=1 and wait for RVALID handshake
    cfg.vif.master_cb.rready <= 1'b1;
    rready_driven             = 1'b1;
    forever begin
      @(cycle_advanced or reset_asserted_ev);

      if (in_reset || cfg.vif.aresetn !== 1'b1) begin
        return;
      end

      elapsed_from_accept = aclk_cycle_cnt - req.ar_accept_cycle;

      // Priority 1: Check physical handshake on the bus at this clock edge
      if (cfg.vif.master_cb.rvalid === 1'b1) begin
        bit rvalid_ok     = (saw_first_rvalid || rvalid_budget == 0 || elapsed_from_accept <= rvalid_budget);
        bit completion_ok = (completion_budget == 0 || elapsed_from_accept <= completion_budget);

        if (rvalid_ok && completion_ok) begin
          if (!saw_first_rvalid) begin
            saw_first_rvalid = 1'b1;
            if (req.first_rvalid_cycle == 0) req.first_rvalid_cycle = aclk_cycle_cnt;
          end
          req.data                  = cfg.vif.master_cb.rdata;
          req.resp                  = cfg.vif.master_cb.rresp;
          req.r_completed           = 1'b1;
          req.completion_status     = AXIL_STATUS_OK;
          req.r_complete_cycle      = aclk_cycle_cnt;
          cfg.vif.master_cb.rready <= 1'b0;
          rready_driven             = 1'b0;
          return;
        end else begin
          req.timed_out            = 1'b1;
          req.completion_status    = AXIL_STATUS_R_TIMEOUT;
          r_wedged                 = 1'b1;
          cfg.vif.master_cb.rready <= 1'b0;
          rready_driven             = 1'b0;
          `uvm_error("AXIL_COMPLETION_TIMEOUT", $sformatf(
            "Read transaction at addr=0x%08h completed late (%0d cycles > budget)",
            req.addr, elapsed_from_accept))
          return;
        end
      end

      // Priority 2: Check if R channel was wedged by timeout of another transaction
      if (r_wedged) begin
        return;
      end

      // Priority 3: Check timeouts for this transaction
      if (!saw_first_rvalid && rvalid_budget != 0 && elapsed_from_accept > rvalid_budget) begin
        req.timed_out            = 1'b1;
        req.completion_status    = AXIL_STATUS_R_TIMEOUT;
        r_wedged                 = 1'b1;
        cfg.vif.master_cb.rready <= 1'b0;
        rready_driven             = 1'b0;
        `uvm_error("AXIL_RVALID_TIMEOUT", $sformatf(
          "DUT did not assert RVALID at addr=0x%08h after %0d cycles (rvalid_budget=%0d)",
          req.addr, elapsed_from_accept, rvalid_budget))
        return;
      end
      if (completion_budget != 0 && elapsed_from_accept > completion_budget) begin
        req.timed_out            = 1'b1;
        req.completion_status    = AXIL_STATUS_R_TIMEOUT;
        r_wedged                 = 1'b1;
        cfg.vif.master_cb.rready <= 1'b0;
        rready_driven             = 1'b0;
        `uvm_error("AXIL_COMPLETION_TIMEOUT", $sformatf(
          "Read transaction at addr=0x%08h exceeded completion budget (%0d cycles)",
          req.addr, completion_budget))
        return;
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Continuous Active Queue Timeout Watcher (Evaluates strictly after handshake)
  // ---------------------------------------------------------------------------
  task automatic queue_timeout_watcher();
    forever begin
      @(cycle_advanced);
      if (!in_reset && cfg.vif.aresetn === 1'b1 && !r_wedged) begin
        // Check queued items starting from position [1] (since position [0] is evaluated by drive_r_phase)
        for (int i = 1; i < pending_r_q.size(); i++) begin
          axil_master_transaction item = pending_r_q[i];
          longint unsigned elapsed;
          longint unsigned comp_budget;
          longint unsigned rval_budget;

          if (item == null || item.r_completed || item.timed_out) continue;

          elapsed     = aclk_cycle_cnt - item.ar_accept_cycle;
          comp_budget = (item.has_timeout_override && item.completion_timeout_override > 0) ?
                        item.completion_timeout_override : cfg.default_completion_timeout_cycles;
          rval_budget = (item.has_timeout_override && item.rvalid_timeout_override > 0) ?
                        item.rvalid_timeout_override : cfg.default_rvalid_timeout_cycles;

          if (comp_budget != 0 && elapsed > comp_budget) begin
            item.timed_out         = 1'b1;
            item.completion_status = AXIL_STATUS_R_TIMEOUT;
            r_wedged               = 1'b1;
            `uvm_error("AXIL_QUEUE_TIMEOUT", $sformatf(
              "Transaction at addr=0x%08h in queue position [%0d] exceeded completion budget (%0d cycles)",
              item.addr, i, comp_budget))
            break;
          end

          if (rval_budget != 0 && item.first_rvalid_cycle == 0 && elapsed > rval_budget) begin
            item.timed_out         = 1'b1;
            item.completion_status = AXIL_STATUS_R_TIMEOUT;
            r_wedged               = 1'b1;
            `uvm_error("AXIL_QUEUE_RVAL_TIMEOUT", $sformatf(
              "Transaction at addr=0x%08h in queue position [%0d] exceeded RVALID budget (%0d cycles)",
              item.addr, i, rval_budget))
            break;
          end
        end
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Decoupled AR Channel Worker
  // ---------------------------------------------------------------------------
  task automatic ar_loop();
    axil_master_transaction req;
    axil_master_transaction ctx;
    bit ar_accepted;

    forever begin
      wait (reset_recovery_done && !in_reset && cfg.vif.aresetn === 1'b1);
      seq_item_port.get_next_item(req);
      init_req_status(req);

      if (!$cast(ctx, req.clone()))
        `uvm_fatal("AXIL_CLONE", "Cannot clone AXI-Lite request")
      ctx.set_id_info(req);
      init_req_status(ctx);

      reg_lock.get(1);
      if (in_reset || cfg.vif.aresetn !== 1'b1) begin
        active_ar_req = ctx;
        if (!reset_pulse_active) begin
          // Reset pulse is not currently active in handler (either reset just asserted physically
          // or reset deasserted and is in recovery while a new pulse R2 arrived).
          // Release lock and wait for reset_handler to establish the new epoch and abort ctx.
          reg_lock.put(1);
          wait (ctx.reset_abort || ctx.driver_done);
        end else begin
          // reset_pulse_active is 1: handler has actively established current_epoch for this pulse.
          abort_active_ar();
          reg_lock.put(1);
        end
        sync_req_from_ctx(req, ctx);
        seq_item_port.item_done();
        active_ar_req = null;
        continue;
      end
      active_ar_req = ctx;
      reg_lock.put(1);

      if (ar_wedged || r_wedged) begin
        active_ar_req = null;
        ctx.timed_out         = 1'b1;
        ctx.completion_status = AXIL_STATUS_REJECTED;
        finish_once(ctx);
        sync_req_from_ctx(req, ctx);
        `uvm_error("AXIL_BUS_WEDGED", $sformatf(
          "Rejecting new AXI-Lite read (addr=0x%08h) while bus is wedged (ar_wedged=%0b r_wedged=%0b); assert reset to recover",
          ctx.addr, ar_wedged, r_wedged))
        seq_item_port.item_done();
        continue;
      end

      drive_ar_phase(ctx, ar_accepted);

      if (in_reset || cfg.vif.aresetn !== 1'b1 || ctx.reset_abort || ctx.birth_epoch != current_epoch) begin
        wait (ctx.reset_abort || ctx.driver_done);
        sync_req_from_ctx(req, ctx);
        seq_item_port.item_done();
        active_ar_req = null;
        continue;
      end

      // If accepted, enqueue into pending_r_q for the R channel worker (unless R is already wedged)
      if (ar_accepted && !ctx.timed_out && !r_wedged) begin
        pending_r_q.push_back(ctx);
        -> pending_r_ev;
        active_ar_req = null;
      end else begin
        // Timed out during AR wait or rejected due to R wedge
        active_ar_req = null;
        if (r_wedged && !ctx.timed_out) begin
          ctx.timed_out         = 1'b1;
          ctx.completion_status = AXIL_STATUS_REJECTED;
        end
        finish_once(ctx);
        sync_req_from_ctx(req, ctx);
        seq_item_port.item_done();
        continue;
      end

      if (!ctx.pipeline_ar) begin
        wait (ctx.driver_done === 1'b1 || ctx.r_completed === 1'b1 || ctx.reset_abort === 1'b1 || in_reset || cfg.vif.aresetn !== 1'b1);
        if (in_reset || cfg.vif.aresetn !== 1'b1 || ctx.birth_epoch != current_epoch) begin
          wait (ctx.reset_abort || ctx.driver_done);
        end
        sync_req_from_ctx(req, ctx);
      end

      seq_item_port.item_done();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Decoupled R Channel Worker
  // ---------------------------------------------------------------------------
  task automatic drain_r_wedge();
    axil_master_transaction dropped;
    while (pending_r_q.size() > 0) begin
      dropped = pending_r_q.pop_front();
      if (!dropped.r_completed) begin
        dropped.timed_out         = 1'b1;
        dropped.completion_status = AXIL_STATUS_R_TIMEOUT;
      end
      finish_once(dropped);
    end
    cfg.vif.master_cb.rready <= 1'b0;
    rready_driven             = 1'b0;
    wait (in_reset || cfg.vif.aresetn !== 1'b1);
  endtask

  task automatic r_loop();
    axil_master_transaction r_req;
    cfg.vif.master_cb.rready <= 1'b0;
    rready_driven             = 1'b0;

    forever begin
      if (in_reset || cfg.vif.aresetn !== 1'b1) begin
        wait (reset_recovery_done && !in_reset && cfg.vif.aresetn === 1'b1);
      end

      while (pending_r_q.size() == 0 && orphan_r_pending == 0 && !in_reset && cfg.vif.aresetn === 1'b1) begin
        @(cycle_advanced or reset_asserted_ev or pending_r_ev or negedge cfg.vif.aresetn);
      end
      if (in_reset || cfg.vif.aresetn !== 1'b1) continue;

      if (pending_r_q.size() == 0 && orphan_r_pending > 0) begin
        cfg.vif.master_cb.rready <= 1'b1;
        rready_driven             = 1'b1;
        forever begin
          @(cycle_advanced or reset_asserted_ev);
          if (in_reset || cfg.vif.aresetn !== 1'b1) break;
          if (cfg.vif.master_cb.rvalid === 1'b1) begin
            cfg.vif.master_cb.rready <= 1'b0;
            rready_driven             = 1'b0;
            if (orphan_r_pending > 0) orphan_r_pending--;
            if (orphan_r_pending == 0 && !arvalid_driven) begin
              ar_wedged           = 1'b0;
              ar_expected_timeout = 1'b0;
            end
            break;
          end
        end
        continue;
      end

      r_req = pending_r_q[0];

      if (in_reset || cfg.vif.aresetn !== 1'b1 || r_req.reset_abort) begin
        continue;
      end else if (r_wedged || r_req.timed_out) begin
        drain_r_wedge();
        continue;
      end

      drive_r_phase(r_req);

      if (in_reset || cfg.vif.aresetn !== 1'b1 || r_req.reset_abort) begin
        continue;
      end else if (r_wedged || r_req.timed_out) begin
        drain_r_wedge();
        continue;
      end else begin
        // Successful completion
        if (pending_r_q.size() > 0 && pending_r_q[0] == r_req) begin
          void'(pending_r_q.pop_front());
        end
        finish_once(r_req);
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Resilient Asynchronous Reset Handler & Recovery Engine
  // ---------------------------------------------------------------------------
  task automatic reset_handler();
    axil_master_transaction aborted;
    // Initial startup check
    if (cfg.vif.aresetn === 1'b1) begin
      cfg.vif.direct_reset_release();
      drive_cb_idle();
      in_reset            = 1'b0;
      reset_pulse_active  = 1'b0;
      reset_recovery_done = 1'b1;
    end else begin
      in_reset            = 1'b1;
      reset_pulse_active  = 1'b1;
      reset_recovery_done = 1'b0;
      current_epoch       = 1;
      ar_wedged           = 1'b0;
      ar_expected_timeout = 1'b0;
      r_wedged            = 1'b0;
      orphan_r_pending    = 0;
      cfg.vif.direct_reset_force();
      drive_cb_idle();

      // Wait for bootstrap reset deassertion
      while (cfg.vif.aresetn !== 1'b1) begin
        @(posedge cfg.vif.aresetn);
      end
      reg_lock.get(1);
      if (cfg.vif.aresetn === 1'b1) begin
        reset_pulse_active = 1'b0;
      end
      reg_lock.put(1);

      @(cycle_advanced or negedge cfg.vif.aresetn);
      if (cfg.vif.aresetn === 1'b1) begin
        cfg.vif.direct_reset_release();
        drive_cb_idle();
        @(cycle_advanced or negedge cfg.vif.aresetn);
        if (cfg.vif.aresetn === 1'b1) begin
          recovery_barrier();
        end
      end
    end

    forever begin
      if (cfg.vif.aresetn === 1'b1) begin
        @(negedge cfg.vif.aresetn);
      end
      reg_lock.get(1);
      current_epoch++;
      in_reset            = 1'b1;
      reset_pulse_active  = 1'b1;
      reset_recovery_done = 1'b0;
      last_ar_hs_time     = -1.0;
      ar_wedged           = 1'b0;
      ar_expected_timeout = 1'b0;
      r_wedged            = 1'b0;
      orphan_r_pending    = 0;
      arvalid_driven      = 1'b0;
      rready_driven       = 1'b0;

      // Absolute priority hardware forcing (IEEE 1800 §10.6.2)
      cfg.vif.direct_reset_force();
      drive_cb_idle();

      // Abort active AR request atomically
      abort_active_ar();

      // Abort all queued R requests atomically
      while (pending_r_q.size() > 0) begin
        aborted = pending_r_q.pop_front();
        if (!aborted.driver_done) begin
          aborted.reset_abort       = 1'b1;
          aborted.completion_status = AXIL_STATUS_RESET_ABORT;
          aborted.abort_epoch       = current_epoch;
          aborted.data              = '0;
          aborted.resp              = '0;
          finish_once(aborted);
        end
      end

      reg_lock.put(1);
      // Notify all workers that reset abort is complete and epoch is established
      -> reset_asserted_ev;

      // Wait until reset is deasserted AND remains deasserted through recovery
      while (cfg.vif.aresetn !== 1'b1) begin
        @(posedge cfg.vif.aresetn);
      end

      reg_lock.get(1);
      if (cfg.vif.aresetn === 1'b1) begin
        reset_pulse_active = 1'b0;
      end
      reg_lock.put(1);

      @(cycle_advanced or negedge cfg.vif.aresetn);
      if (cfg.vif.aresetn !== 1'b1) continue;

      cfg.vif.direct_reset_release();
      drive_cb_idle();

      @(cycle_advanced or negedge cfg.vif.aresetn);
      if (cfg.vif.aresetn !== 1'b1) continue;

      // Synchronized recovery barrier under reg_lock
      recovery_barrier();
    end
  endtask

  virtual task run_phase(uvm_phase phase);
    cfg.vif.direct_reset_force();
    fork
      clock_tracker();
      reset_handler();
      ar_hold_watcher();
      queue_timeout_watcher();
      ar_loop();
      r_loop();
    join
  endtask

endclass : axil_master_driver

`endif // AXIL_MASTER_DRIVER_SV
