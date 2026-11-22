// Observes APB pins independently of the driver in ACTIVE and PASSIVE modes.
// Protocol diagnostics covered by apb_sva are intentionally delegated
// to that checker; this component reconstructs and publishes bus transactions.
class apb_monitor #(
  int unsigned ADDR_WIDTH = 12,
  int unsigned DATA_WIDTH = 32
) extends uvm_monitor;
  `uvm_component_param_utils(apb_monitor #(ADDR_WIDTH, DATA_WIDTH))

  typedef apb_trans #(ADDR_WIDTH, DATA_WIDTH) trans_t;
  typedef apb_cfg #(ADDR_WIDTH, DATA_WIDTH) cfg_t;

  cfg_t cfg;
  uvm_analysis_port #(trans_t) ap;

  protected trans_t curr_trans;
  protected bit prev_transfer_done;
  protected bit has_completed_transfer;
  protected time last_completed_at;
  protected int unsigned idle_since_completion;

  function new(string name = "apb_monitor", uvm_component parent = null);
    super.new(name, parent);
    ap = new("ap", this);
  endfunction


  protected function bit reset_active();
    return cfg.apb_vif.rst_n !== 1'b1;
  endfunction

  protected function void publish_current();
    if (curr_trans == null)
      `uvm_fatal("APB_MON_STATE", "No transaction to publish")
    `uvm_info("APB_MON", curr_trans.sprint(), UVM_HIGH)
    ap.write(curr_trans);
    curr_trans = null;
  endfunction

  protected function void capture_setup(bit back_to_back);
    curr_trans = trans_t::type_id::create("observed");
    curr_trans.write        = cfg.apb_vif.pwrite;
    curr_trans.addr         = cfg.apb_vif.paddr;
    curr_trans.wdata        = cfg.apb_vif.pwdata;
    curr_trans.strb         = cfg.apb_vif.pstrb;
    curr_trans.prot         = cfg.apb_vif.pprot;
    curr_trans.idle_cycles = 0;
    curr_trans.observed_idle_cycles=idle_since_completion;
    curr_trans.setup_started=1;
    idle_since_completion=0;
    curr_trans.rdata        = '0;
    curr_trans.slverr       = 1'b0;
    curr_trans.reset_abort  = 1'b0;
    curr_trans.wait_cycles  = 0;
    curr_trans.back_to_back = back_to_back;
  endfunction

  virtual task run_phase(uvm_phase phase);
    curr_trans = null;
    prev_transfer_done = 1'b0;
    has_completed_transfer = 1'b0;
    last_completed_at = 0;
    idle_since_completion=0;

    forever begin
      @(posedge cfg.apb_vif.clk or negedge cfg.apb_vif.rst_n);

      if (reset_active()) begin
        prev_transfer_done = 1'b0;
        idle_since_completion=0;

        // Reset may arrive after the driver has driven SETUP or entered ACCESS
        // before this monitor has sampled that clock edge. Reconstruct it before aborting,
        // but never re-capture a transfer that already completed at this exact timestamp
        // while apb_driver::drive_idle() is clearing psel/penable in NBA.
        if (curr_trans == null &&
            !(has_completed_transfer && last_completed_at == $time) &&
            cfg.apb_vif.psel === 1'b1) begin
          capture_setup(1'b0);
          if (cfg.apb_vif.penable === 1'b1)
            curr_trans.abort_in_access = 1'b1;
        end

        if (curr_trans != null) begin
          curr_trans.completed_at = $time;
          curr_trans.reset_abort = 1'b1;
          if (cfg.apb_vif.penable === 1'b1)
            curr_trans.abort_in_access = 1'b1;
          publish_current();
        end

        // The reset pulse itself may hold for several clock edges. Without
        // this, the loop re-enters here on every one of those edges and
        // re-reconstructs/re-publishes the same stale SETUP (psel/penable do
        // not change while the driver is also held off by reset), producing
        // duplicate reset-abort observations for a single real event.
        while (reset_active())
          @(posedge cfg.apb_vif.clk or negedge cfg.apb_vif.rst_n);
        continue;
      end

      if (curr_trans == null) begin
        if (cfg.apb_vif.psel === 1'b1 &&
            cfg.apb_vif.penable === 1'b0) begin
          capture_setup(prev_transfer_done);
          prev_transfer_done = 1'b0;
        end
        else if (cfg.apb_vif.psel !== 1'b1) begin
          idle_since_completion++;
          // An idle cycle after completion ends the back-to-back opportunity.
          prev_transfer_done = 1'b0;
        end
        continue;
      end

      // The SVA checker owns phase/control stability diagnostics. If the bus
      // leaves ACCESS without a handshake, discard the incomplete observation.
      if (cfg.apb_vif.psel !== 1'b1 ||
          cfg.apb_vif.penable !== 1'b1) begin
        curr_trans = null;
        prev_transfer_done = 1'b0;

        // Recover immediately if this sample is a new SETUP phase. The
        // discarded transfer remains a protocol violation owned by SVA.
        if (cfg.apb_vif.psel === 1'b1 &&
            cfg.apb_vif.penable === 1'b0)
          capture_setup(1'b0);
        continue;
      end

      curr_trans.abort_in_access = 1'b1;

      case (cfg.apb_vif.pready)
        1'b0: begin
          curr_trans.wait_cycles++;
          if (cfg.checks_enable && cfg.max_wait_cycles != 0 &&
              curr_trans.wait_cycles == cfg.max_wait_cycles)
            `uvm_warning("APB_MON_WAIT", $sformatf(
              "Long ACCESS wait addr=%0h cycles=%0d",
              curr_trans.addr, curr_trans.wait_cycles))
        end

        1'b1: begin
          curr_trans.completed_at = $time;
          curr_trans.slverr = cfg.apb_vif.pslverr;
          if (!curr_trans.write)
            curr_trans.rdata = cfg.apb_vif.prdata;

          if (cfg.checks_enable && cfg.check_read_data_known &&
              !curr_trans.write && curr_trans.slverr === 1'b0 &&
              $isunknown(curr_trans.rdata))
            `uvm_error("APB_MON_X", "PRDATA X/Z on successful READ")

          publish_current();
          has_completed_transfer = 1'b1;
          last_completed_at = $time;
          // Used only if the following sampled edge sees the next SETUP.
          prev_transfer_done = 1'b1;
          idle_since_completion=0;
        end

        default: begin
          curr_trans.wait_cycles++;
          // PREADY X/Z is diagnosed by the primary SVA checker. Keep waiting
          // so that a later known handshake can still be reconstructed.
        end
      endcase
    end
  endtask
endclass
