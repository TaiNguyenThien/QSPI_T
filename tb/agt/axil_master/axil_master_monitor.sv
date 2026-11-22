// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_master_monitor.sv
// Role   : Enterprise Passive Bus Observer & Conservation Invariant Monitor
// Spec   : ARM AMBA AXI4-Lite Protocol & VNCHIP Spec Rev 1.0 (Section 3.3, 5.7)
// =============================================================================

`ifndef AXIL_MASTER_MONITOR_SV
`define AXIL_MASTER_MONITOR_SV

class axil_master_monitor extends uvm_monitor;
  `uvm_component_utils(axil_master_monitor)

  axil_master_cfg cfg;

  uvm_analysis_port #(axil_master_transaction) ap;       // Completed + accepted-reset-aborted reads
  uvm_analysis_port #(axil_master_transaction) ar_ap;    // Accepted AR requests ONLY
  uvm_analysis_port #(axil_master_transaction) unacc_ap; // Diagnostic: unaccepted requests cancelled by reset

  protected axil_master_transaction ar_pending;
  protected axil_master_transaction accepted[$];

  // --- Conservation Invariant Metrics ---
  longint unsigned accepted_count      = 0;
  longint unsigned completed_count     = 0;
  longint unsigned reset_aborts        = 0;
  longint unsigned unaccepted_aborts   = 0;
  longint unsigned orphan_responses    = 0;
  longint unsigned cycle_count         = 0;
  longint unsigned current_epoch       = 0;

  function new(string name = "axil_master_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap       = new("ap", this);
    ar_ap    = new("ar_ap", this);
    unacc_ap = new("unacc_ap", this);
  endfunction

  // Dedicated asynchronous reset watcher (flushes observations immediately on negedge aresetn)
  task automatic mon_reset_watcher();
    forever begin
      @(negedge cfg.vif.aresetn);
      current_epoch++;

      // Unaccepted AR cancelled by reset: separate diagnostic port, NOT in accepted conservation
      if (ar_pending != null) begin
        ar_pending.reset_abort       = 1'b1;
        ar_pending.completion_status = AXIL_STATUS_RESET_ABORT;
        ar_pending.abort_epoch       = current_epoch;
        unaccepted_aborts++;
        unacc_ap.write(ar_pending);
        ar_pending = null;
      end

      // Accepted requests awaiting R channel: count towards N_reset_aborted
      while (accepted.size() > 0) begin
        axil_master_transaction aborted = accepted.pop_front();
        aborted.reset_abort       = 1'b1;
        aborted.completion_status = AXIL_STATUS_RESET_ABORT;
        aborted.abort_epoch       = current_epoch;
        reset_aborts++;
        ap.write(aborted);
      end
    end
  endtask

  // Synchronous sampling loop on clocking block
  task automatic mon_sampling_loop();
    axil_master_transaction snapshot;
    axil_master_transaction result;

    forever begin
      @(cfg.vif.monitor_cb);
      cycle_count++;

      // Skip sampling when reset is active (check both preponed clocking sample and raw physical signal)
      if (cfg.vif.monitor_cb.aresetn !== 1'b1 || cfg.vif.aresetn !== 1'b1) begin
        continue;
      end

      // -----------------------------------------------------------------------
      // 1. Read Data Channel (R): Process R handshakes & record metrics
      // -----------------------------------------------------------------------
      if (accepted.size() > 0) begin
        if (cfg.vif.monitor_cb.rvalid === 1'b1) begin
          if (accepted[0].first_rvalid_cycle == 0) begin
            accepted[0].first_rvalid_cycle = cycle_count;
          end

          if (cfg.vif.monitor_cb.rready === 1'b1) begin
            result                   = accepted.pop_front();
            result.data              = cfg.vif.monitor_cb.rdata;
            result.resp              = cfg.vif.monitor_cb.rresp;
            result.r_completed       = 1'b1;
            result.completion_status = AXIL_STATUS_OK;
            result.r_complete_cycle  = cycle_count;
            completed_count++;
            ap.write(result);
          end else if (cfg.vif.monitor_cb.rready === 1'b0) begin
            accepted[0].r_stall++;
          end
        end
      end else if (cfg.vif.monitor_cb.rvalid === 1'b1 && cfg.vif.monitor_cb.rready === 1'b1) begin
        orphan_responses++;
        `uvm_error("AXIL_ORPHAN_RSP", $sformatf(
          "Observed R handshake (data=0x%08h resp=%02b) with no pending accepted AR request in queue!",
          cfg.vif.monitor_cb.rdata, cfg.vif.monitor_cb.rresp))
      end

      // -----------------------------------------------------------------------
      // 2. Read Address Channel (AR): Track AR wait & publish on handshake
      // -----------------------------------------------------------------------
      if (cfg.vif.monitor_cb.arvalid === 1'b1) begin
        if (ar_pending == null) begin
          ar_pending             = axil_master_transaction::type_id::create("observed_axil_ar");
          ar_pending.birth_epoch = current_epoch;
          ar_pending.abort_epoch = 0;
        end
        ar_pending.addr = cfg.vif.monitor_cb.araddr;
        ar_pending.prot = cfg.vif.monitor_cb.arprot;

        if (cfg.vif.monitor_cb.arready === 1'b1) begin
          ar_pending.ar_accepted     = 1'b1;
          ar_pending.ar_accept_cycle = cycle_count;
          accepted_count++;

          if (!$cast(snapshot, ar_pending.clone()))
            `uvm_fatal("AXIL_MON_CLONE", "Cannot clone accepted AR transaction")
          ar_ap.write(snapshot);

          accepted.push_back(ar_pending);
          ar_pending = null;
        end else if (cfg.vif.monitor_cb.arready === 1'b0) begin
          ar_pending.ar_wait++;
        end
      end else begin
        ar_pending = null;
      end
    end
  endtask

  virtual task run_phase(uvm_phase phase);
    // Align initial epoch with driver when starting under reset
    if (cfg.vif.aresetn !== 1'b1) begin
      current_epoch = 1;
    end

    fork
      mon_reset_watcher();
      mon_sampling_loop();
    join
  endtask

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    // Invariant Check: N_ar_accepted == N_r_completed + N_pending + N_reset_aborts
    if (accepted_count != (completed_count + accepted.size() + reset_aborts)) begin
      `uvm_error("AXIL_CONSERVATION_FAIL", $sformatf(
        "AXI-Lite Conservation violated: accepted(%0d) != completed(%0d) + pending(%0d) + reset_aborts(%0d)",
        accepted_count, completed_count, accepted.size(), reset_aborts))
    end

    if (orphan_responses != 0) begin
      `uvm_error("AXIL_ORPHAN_LEAK", $sformatf(
        "Simulation detected %0d orphan response(s) without accepted requests!", orphan_responses))
    end

    if (accepted.size() != 0) begin
      `uvm_error("AXIL_HANGING_REQ", $sformatf(
        "Simulation ended with %0d in-flight accepted AXI-Lite request(s) still pending in queue!",
        accepted.size()))
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("AXIL_MON_SUMMARY", $sformatf(
      "AXI4-Lite Monitor Summary: accepted=%0d completed=%0d reset_aborts=%0d unaccepted_aborts=%0d orphan=%0d",
      accepted_count, completed_count, reset_aborts, unaccepted_aborts, orphan_responses),
      (orphan_responses == 0 && unaccepted_aborts == 0) ? UVM_HIGH : UVM_LOW)
  endfunction

endclass : axil_master_monitor

`endif // AXIL_MASTER_MONITOR_SV
