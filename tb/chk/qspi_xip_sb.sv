// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_xip_sb.sv
// Role   : Enterprise XIP Scoreboard (AXI4-Lite AR/R <-> SPI <-> APB CSR)
// Spec   : VNCHIP QSPI Controller Rev 1.0 & Checkpoint 3 XIP VPlan (36 TCs)
// =============================================================================

`ifndef QSPI_XIP_SB_SV
`define QSPI_XIP_SB_SV

`uvm_analysis_imp_decl(_xip_axil_ar)
`uvm_analysis_imp_decl(_xip_axil_r)
`uvm_analysis_imp_decl(_xip_apb)
`uvm_analysis_imp_decl(_xip_spi)
`uvm_analysis_imp_decl(_xip_dma_axi)

typedef enum bit {
  XIP_SPI_OWNER_XIP     = 1'b0,
  XIP_SPI_OWNER_NON_XIP = 1'b1
} xip_spi_owner_e;

// Compact, self-contained tracking record for one accepted AXI4-Lite XIP read.
class qspi_xip_ctx extends uvm_object;
  `uvm_object_utils(qspi_xip_ctx)

  longint unsigned epoch;
  longint unsigned mon_birth_epoch;
  longint unsigned accept_seq;

  logic [31:0]     araddr;
  logic [2:0]      arprot;
  bit [31:0]       flash_addr;
  int unsigned     addr_bytes;
  bit              is_unaligned;
  bit              characterize_unaligned;

  bit [7:0]        expected_bytes[4];
  bit [31:0]       expected_data;
  logic [1:0]      expected_resp;

  // CSR configuration snapshot captured using pre-edge CSR state at AR handshake
  bit [31:0]       snap_ctrl;
  bit [31:0]       snap_clk_div;
  bit [31:0]       snap_cs_ctrl;
  bit [31:0]       snap_xip_cfg;
  bit [31:0]       snap_xip_cmd;

  // Lifecycle & latency telemetry
  longint unsigned ar_accept_cycle;
  time             ar_accept_time;
  time             r_first_valid_at;
  longint unsigned first_rvalid_cycle;
  longint unsigned r_complete_cycle;
  int unsigned     ar_wait;
  int unsigned     r_stall;
  bit              disable_seen;
  bit              rvalid_seen;
  bit              early_r_reported;
  bit              timeout_reported;
  bit              spi_checked;
  bit              spi_completed;
  time             spi_completed_at;
  bit              axi_retired;
  bit              expect_no_spi;
  bit              spi_validation_deferred;
  qspi_transaction deferred_spi_tr;

  function new(string name = "qspi_xip_ctx");
    super.new(name);
    expected_resp = 2'b00;
  endfunction

  function bit is_expect_slverr();
    return (expected_resp === 2'b10);
  endfunction
endclass : qspi_xip_ctx

typedef struct {
  longint unsigned epoch;
  xip_spi_owner_e  owner;
  qspi_xip_ctx     ctx;
  bit              non_xip_dir;
  bit              is_dma_cmd;
  bit [7:0]        non_xip_opcode;
  bit [31:0]       non_xip_addr;
  int unsigned     non_xip_addr_bytes;
  int unsigned     non_xip_len;
  bit [31:0]       non_xip_dma_addr;
  bit              non_xip_dma_incr;
  bit              has_tx_source;
  bit              dma_prov_failed;
  bit [31:0]       dma_prov_next_addr;
  int unsigned     dma_prov_bytes_captured;
  logic [7:0]      expected_tx_bytes[$];
} xip_spi_expect_t;

typedef struct {
  axil_master_transaction tr;
  time                    obs_time;
} xip_axil_obs_t;

class qspi_xip_sb extends uvm_scoreboard;
  `uvm_component_utils(qspi_xip_sb)

  localparam bit [31:0] QSPI_ID_VALUE = 32'h0A10_0102;

  qspi_env_cfg cfg;

  uvm_analysis_imp_xip_axil_ar #(axil_master_transaction, qspi_xip_sb) axil_ar_export;
  uvm_analysis_imp_xip_axil_r  #(axil_master_transaction, qspi_xip_sb) axil_r_export;
  uvm_analysis_imp_xip_apb     #(qspi_apb_item_t,         qspi_xip_sb) apb_export;
  uvm_analysis_imp_xip_spi     #(qspi_transaction,        qspi_xip_sb) spi_export;
  uvm_analysis_imp_xip_dma_axi #(axi_slave_transaction,   qspi_xip_sb) dma_axi_export;

  // Shared spec-compliant passive CSR shadow instance (updated at end-of-edge after AR checks)
  qspi_csr_shadow csr;

  // Same-cycle deterministic edge batches (flushed R -> AR -> APB)
  xip_axil_obs_t   r_batch_q[$];
  xip_axil_obs_t   ar_batch_q[$];
  qspi_apb_item_t  apb_batch_q[$];

  // AXI retirement FIFO + chronological SPI ownership FIFO (shared qspi_xip_ctx handles)
  qspi_xip_ctx     in_flight_ar_q[$];
  qspi_xip_ctx     retired_awaiting_spi_q[$];
  xip_spi_expect_t pending_spi_q[$];

  // Active physical SPI frame ownership claimed at negedge qspi_cs_n
  bit              spi_frame_active    = 1'b0;
  bit              spi_frame_has_owner = 1'b0;
  xip_spi_expect_t active_spi_exp;

  // Independent sparse Flash golden memory & non-memory register oracle
  bit [7:0] flash_ref_mem[int unsigned];
  bit [7:0] jedec_id[3]      = '{8'hc2, 8'h20, 8'h17};
  bit       flash_wel        = 1'b0;
  bit [7:0] flash_status_reg = 8'h00;

  // Configurable scoreboard policy knobs (set by sequences/tests before stimulus)
  int unsigned max_expected_outstanding  = 1;
  bit          enforce_latency_budget    = 1'b0;
  bit          allow_mid_frame_csr_mut   = 1'b0;
  int unsigned latency_budget_exceeded   = 0;

  // Passive prefill / TX source-truth tracking (per-command DMA provenance lives in xip_spi_expect_t)
  int unsigned verified_pio_prefill_words = 0;
  bit [31:0]   tx_fifo_shadow_words[$];

  // Disabled AR gating telemetry
  bit          prev_disabled_ar_blocked     = 1'b0;
  int unsigned cur_disabled_ar_window       = 0;
  int unsigned total_disabled_ar_attempts   = 0;
  int unsigned total_disabled_ar_cycles     = 0;
  int unsigned max_disabled_ar_window       = 0;

  // Epoch, reset lineage & conservation counters
  longint unsigned current_epoch        = 0;
  longint unsigned next_accept_seq      = 1;
  longint unsigned cycle_count          = 0;
  bit              has_runtime_reset    = 0;
  time             last_reset_assert_at = 0;
  time             last_cs_assert_at    = 0;

  int unsigned total_ar_accepted        = 0;
  int unsigned total_ar_wait_nonzero    = 0;
  int unsigned total_r_completed        = 0;
  int unsigned total_reset_aborts       = 0;
  int unsigned total_spi_reset_aborts   = 0;
  int unsigned total_non_xip_spi_frames = 0;
  int unsigned total_r_matched          = 0;
  int unsigned total_r_data_matched     = 0;
  int unsigned total_r_slverr_matched   = 0;
  int unsigned total_r_char_matched     = 0;
  int unsigned total_r_mismatches       = 0;
  int unsigned total_spi_matched        = 0;
  int unsigned total_spi_ok_matched     = 0;
  int unsigned total_spi_slverr_matched = 0;
  int unsigned total_spi_mismatches     = 0;
  int unsigned total_slverr_observed    = 0;
  int unsigned total_r_post_valid_stall_completed = 0;
  int unsigned total_disable_seen       = 0;
  int unsigned max_r_stall_observed     = 0;
  int unsigned max_outstanding_observed = 0;
  longint unsigned max_first_r_latency  = 0;
  longint unsigned max_total_r_latency  = 0;

  // Concurrent APB isolation metrics (TC_033)
  int unsigned concurrent_apb_count     = 0;
  int unsigned conc_rd_id_count         = 0;
  int unsigned conc_rd_status_count     = 0;
  int unsigned conc_rd_fifo_stat_count  = 0;
  int unsigned conc_wr_int_en_count     = 0;
  int unsigned isolation_violations     = 0;

  function new(string name = "qspi_xip_sb", uvm_component parent = null);
    super.new(name, parent);
    axil_ar_export = new("axil_ar_export", this);
    axil_r_export  = new("axil_r_export",  this);
    apb_export     = new("apb_export",     this);
    spi_export     = new("spi_export",     this);
    dma_axi_export = new("dma_axi_export", this);
    csr            = qspi_csr_shadow::type_id::create("xip_sb_csr");
    reset_csr_shadows();
  endfunction

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db #(qspi_env_cfg)::get(this, "", "cfg", cfg));
    if (cfg == null || cfg.clk_vif == null)
      `uvm_fatal("XIP_SB_CFG", "qspi_xip_sb requires non-null cfg and cfg.clk_vif")
    max_expected_outstanding = cfg.enforce_xip_max_os ? cfg.xip_max_outstanding : 0;
  endfunction

  function automatic virtual axil_if get_axil_vif();
    if (cfg.axil_cfg_h != null && cfg.axil_cfg_h.vif != null)
      return cfg.axil_cfg_h.vif;
    return cfg.axil_vif;
  endfunction

  // -------------------------------------------------------------------------
  // Flash Golden Oracle Helpers (Memory clear & external device reset separated)
  // -------------------------------------------------------------------------
  function void clear_flash_ref(bit reset_device = 1'b0);
    flash_ref_mem.delete();
    if (reset_device)
      reset_flash_device_ref();
  endfunction

  function void reset_flash_device_ref();
    flash_wel        = 1'b0;
    flash_status_reg = 8'h00;
  endfunction

  function void erase_flash_ref_range(input bit [31:0] raw_addr, input int unsigned range_bytes);
    int unsigned keys_to_del[$];
    longint unsigned base_addr;
    longint unsigned end_addr;
    if (range_bytes == 0) return;
    base_addr = longint'(raw_addr) - (longint'(raw_addr) % longint'(range_bytes));
    end_addr  = base_addr + longint'(range_bytes);
    foreach (flash_ref_mem[k]) begin
      if (longint'(k) >= base_addr && longint'(k) < end_addr)
        keys_to_del.push_back(k);
    end
    foreach (keys_to_del[i])
      flash_ref_mem.delete(keys_to_del[i]);
  endfunction

  function void preload_byte(input bit [31:0] addr, input bit [7:0] data);
    flash_ref_mem[addr] = data;
  endfunction

  function automatic bit [7:0] get_flash_byte(input bit [31:0] addr);
    if (flash_ref_mem.exists(addr))
      return flash_ref_mem[addr];
    return 8'hFF;
  endfunction

  protected function void attach_dma_tx_burst(
    ref   xip_spi_expect_t      cmd,
    input axi_slave_transaction tr
  );
    bit [31:0]   exp_addr;
    int unsigned beat_cap;
    int unsigned max_aligned_bytes;
    bit          beat_ok;

    exp_addr          = cmd.non_xip_dma_incr ? cmd.dma_prov_next_addr : cmd.non_xip_dma_addr;
    max_aligned_bytes = ((cmd.non_xip_len + 32'd3) >> 2) << 2;

    if ($isunknown(tr.addr) || tr.addr !== exp_addr) begin
      `uvm_error("XIP_DMA_SRC_ADDR_MISMATCH", $sformatf(
        "DMA TX AXI read addr=0x%08h disagreed with expected APB DMA addr=0x%08h (incr=%0b)",
        tr.addr, exp_addr, cmd.non_xip_dma_incr))
      cmd.dma_prov_failed = 1'b1;
      total_spi_mismatches++;
    end
    if ($isunknown(tr.len) || tr.data.size() != (int'(tr.len) + 1)) begin
      cmd.dma_prov_failed = 1'b1;
    end

    beat_cap = tr.data.size();
    for (int unsigned beat = 0; beat < beat_cap; beat++) begin
      // Preserve beat byte positions strictly: never skip a failed beat and collapse offsets.
      beat_ok = (beat < tr.rresp.size()) && (tr.rresp[beat] === 2'b00);
      if (!beat_ok) begin
        cmd.dma_prov_failed = 1'b1;
        for (int lane = 0; lane < 4; lane++)
          cmd.expected_tx_bytes.push_back(8'hxx);
      end else begin
        // Standard AMBA AXI4 Little-Endian byte ordering: lane 0 = [7:0] .. lane 3 = [31:24]
        for (int lane = 0; lane < 4; lane++)
          cmd.expected_tx_bytes.push_back(tr.data[beat][lane*8 +: 8]);
      end
      cmd.dma_prov_bytes_captured += 4;
    end

    if (cmd.non_xip_dma_incr)
      cmd.dma_prov_next_addr += (beat_cap * 4);

    if (cmd.dma_prov_bytes_captured > max_aligned_bytes)
      cmd.dma_prov_failed = 1'b1;

    cmd.has_tx_source = (!cmd.dma_prov_failed && cmd.expected_tx_bytes.size() >= cmd.non_xip_len);
  endfunction

  function void write_xip_dma_axi(axi_slave_transaction tr);
    if (tr == null || tr.is_write) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;

    // Bind AXI read burst strictly to the single head DMA TX command (active SPI frame
    // first, otherwise the earliest pending DMA TX command). Any over-fetched burst
    // poisons that head command via dma_prov_failed and never spills into a later command.
    if (spi_frame_active && spi_frame_has_owner &&
        active_spi_exp.owner == XIP_SPI_OWNER_NON_XIP &&
        active_spi_exp.is_dma_cmd && !active_spi_exp.non_xip_dir &&
        active_spi_exp.non_xip_len > 0) begin
      attach_dma_tx_burst(active_spi_exp, tr);
      return;
    end

    foreach (pending_spi_q[i]) begin
      if (pending_spi_q[i].owner == XIP_SPI_OWNER_NON_XIP &&
          pending_spi_q[i].is_dma_cmd && !pending_spi_q[i].non_xip_dir &&
          pending_spi_q[i].non_xip_len > 0) begin
        attach_dma_tx_burst(pending_spi_q[i], tr);
        return;
      end
    end

    // Orphan DMA TX read burst with no active or pending DMA TX command.
    `uvm_error("XIP_DMA_SRC_ORPHAN", $sformatf(
      "Observed AXI read burst (addr=0x%08h beats=%0d) with no owning DMA TX command",
      tr.addr, tr.data.size()))
    total_spi_mismatches++;
  endfunction

  // -------------------------------------------------------------------------
  // Reset, Epoch, Budget & Batch Ordering Helpers
  // -------------------------------------------------------------------------
  function void reset_csr_shadows();
    if (csr != null)
      csr.reset();
  endfunction

  // Flush any same-cycle accepted ARs BEFORE clearing shadows so pre-reset CSR
  // context and ledger accounting are preserved for upcoming reset-abort callbacks.
  function void flush_ar_batch_only();
    while (ar_batch_q.size() > 0) begin
      xip_axil_obs_t obs = ar_batch_q.pop_front();
      process_axil_ar(obs.tr, obs.obs_time);
    end
  endfunction

  function void remove_ctx_from_awaiting_spi(qspi_xip_ctx target);
    for (int i = 0; i < retired_awaiting_spi_q.size(); i++) begin
      if (retired_awaiting_spi_q[i] == target) begin
        retired_awaiting_spi_q.delete(i);
        return;
      end
    end
  endfunction

  // Purge stale non-AXI expectations while keeping in_flight_ar_q intact so
  // axil_master_monitor's abort notifications retire each accepted AR 1:1.
  function void on_reset_assert();
    xip_spi_expect_t kept_spi[$];
    flush_ar_batch_only();
    foreach (in_flight_ar_q[i])
      check_early_r_on_reset(in_flight_ar_q[i], $time);
    foreach (retired_awaiting_spi_q[i])
      check_early_r_on_reset(retired_awaiting_spi_q[i], $time);
    retired_awaiting_spi_q.delete();
    current_epoch++;
    has_runtime_reset    = 1'b1;
    last_reset_assert_at = $time;
    spi_frame_active           = 1'b0;
    spi_frame_has_owner        = 1'b0;
    apb_batch_q.delete();
    verified_pio_prefill_words = 0;
    tx_fifo_shadow_words.delete();
    prev_disabled_ar_blocked   = 1'b0;
    cur_disabled_ar_window     = 0;
    // External SPI Flash retains memory and WEL/status across controller rst_n.
    reset_csr_shadows();
    foreach (pending_spi_q[i]) begin
      if (pending_spi_q[i].epoch == current_epoch)
        kept_spi.push_back(pending_spi_q[i]);
    end
    pending_spi_q = kept_spi;
  endfunction

  function void flush_edge_batches();
    while (r_batch_q.size() > 0) begin
      xip_axil_obs_t obs = r_batch_q.pop_front();
      process_axil_r(obs.tr, obs.obs_time);
    end
    while (ar_batch_q.size() > 0) begin
      xip_axil_obs_t obs = ar_batch_q.pop_front();
      process_axil_ar(obs.tr, obs.obs_time);
    end
    while (apb_batch_q.size() > 0) begin
      qspi_apb_item_t apb_tr = apb_batch_q.pop_front();
      process_apb(apb_tr);
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    virtual axil_if axil_vif_h = get_axil_vif();

    if (cfg.clk_vif.rst_n !== 1'b1) begin
      current_epoch        = 1;
      has_runtime_reset    = 1'b1;
      last_reset_assert_at = $time;
    end

    fork
      forever begin
        @(negedge cfg.clk_vif.rst_n);
        on_reset_assert();
      end
      forever begin
        bit pre_xip_en;
        @(posedge cfg.clk_vif.clk);
        cycle_count++;
        pre_xip_en = (csr.ctrl[0] && csr.ctrl[1]);
        if (cfg.clk_vif.rst_n === 1'b1 && axil_vif_h != null) begin
          if (axil_vif_h.arvalid === 1'b1 && axil_vif_h.arready === 1'b0 &&
              !pre_xip_en && in_flight_ar_q.size() == 0) begin
            total_disabled_ar_cycles++;
            cur_disabled_ar_window++;
            if (cur_disabled_ar_window > max_disabled_ar_window)
              max_disabled_ar_window = cur_disabled_ar_window;
            if (!prev_disabled_ar_blocked) begin
              total_disabled_ar_attempts++;
              prev_disabled_ar_blocked = 1'b1;
            end
          end else begin
            prev_disabled_ar_blocked = 1'b0;
            cur_disabled_ar_window   = 0;
          end
        end else begin
          prev_disabled_ar_blocked = 1'b0;
          cur_disabled_ar_window   = 0;
        end
        if (cfg.clk_vif.rst_n === 1'b1 && in_flight_ar_q.size() > 0) begin
          qspi_xip_ctx head = in_flight_ar_q[0];
          if (axil_vif_h != null && axil_vif_h.rvalid === 1'b1) begin
            if (!head.rvalid_seen)
              head.r_first_valid_at = $time;
            head.rvalid_seen = 1'b1;
          end
          if (!head.rvalid_seen && !head.timeout_reported &&
              cycle_count > head.ar_accept_cycle) begin
            longint unsigned elapsed       = cycle_count - head.ar_accept_cycle;
            longint unsigned lockup_budget = compute_first_rvalid_budget(head) * 64'd4 + 64'd256;
            if (elapsed > lockup_budget) begin
              head.timeout_reported = 1'b1;
              `uvm_error("XIP_READ_LOCKUP_TIMEOUT", $sformatf(
                "seq=%0d addr=0x%08h stalled waiting for RVALID: elapsed=%0d ACLK exceeded lockup ceiling=%0d ACLK",
                head.accept_seq, head.araddr, elapsed, lockup_budget))
            end
          end
        end
        #1ps;
        if (cfg.clk_vif.rst_n === 1'b1)
          flush_edge_batches();
      end
      begin
        if (cfg.flash_vif != null) begin
          forever begin
            time cs_fall_at;
            @(negedge cfg.flash_vif.qspi_cs_n);
            cs_fall_at = $time;
            // Settle past Active, NBA and Reactive monitor_cb regions at this
            // timestamp before claiming SPI ownership from pending_spi_q.
            #1ps;
            if (cfg.clk_vif.rst_n !== 1'b1)
              continue;
            flush_edge_batches();
            last_cs_assert_at = cs_fall_at;
            spi_frame_active  = 1'b1;
            if (pending_spi_q.size() == 0) begin
              spi_frame_has_owner = 1'b0;
              `uvm_error("XIP_SPI_BEFORE_AR", $sformatf(
                "Physical SPI CS_N asserted at %0t with no pending XIP/PIO/DMA request", cs_fall_at))
            end else begin
              active_spi_exp      = pending_spi_q.pop_front();
              spi_frame_has_owner = 1'b1;
              if (active_spi_exp.owner == XIP_SPI_OWNER_XIP &&
                  cs_fall_at < active_spi_exp.ctx.ar_accept_time) begin
                `uvm_error("XIP_SPI_CAUSALITY_ERR", $sformatf(
                  "seq=%0d SPI CS_N asserted at %0t before AR accepted at %0t",
                  active_spi_exp.ctx.accept_seq, cs_fall_at, active_spi_exp.ctx.ar_accept_time))
              end
            end
          end
        end
      end
    join
  endtask

  function automatic int unsigned calc_wire_sclk_cycles(input qspi_xip_ctx ctx);
    bit quad_en;
    bit mode_en;
    int l_cmd, l_addr, l_data, n_dummy, n_cmd, n_addr, n_mode, n_data;
    quad_en = ctx.snap_ctrl[2];
    mode_en = ctx.snap_xip_cfg[8];
    l_cmd   = qspi_eff_lanes(ctx.snap_xip_cfg[1:0], quad_en);
    l_addr  = qspi_eff_lanes(ctx.snap_xip_cfg[3:2], quad_en);
    l_data  = qspi_eff_lanes(ctx.snap_xip_cfg[5:4], quad_en);
    if (l_cmd == 0)  l_cmd  = 1;
    if (l_addr == 0) l_addr = 1;
    if (l_data == 0) l_data = 1;
    n_dummy = int'(ctx.snap_xip_cfg[12:9]);
    n_cmd   = (8 + l_cmd - 1) / l_cmd;
    n_addr  = (ctx.addr_bytes * 8 + l_addr - 1) / l_addr;
    n_mode  = mode_en ? ((8 + l_addr - 1) / l_addr) : 0;
    n_data  = (32 + l_data - 1) / l_data;
    return n_cmd + n_addr + n_mode + n_dummy + n_data;
  endfunction

  function automatic longint unsigned compute_first_rvalid_budget(input qspi_xip_ctx ctx);
    int unsigned clk_div    = int'(ctx.snap_clk_div[2:0]);
    int unsigned cs_delay   = int'(ctx.snap_cs_ctrl[3:2]);
    int unsigned frame_sclk = calc_wire_sclk_cycles(ctx) + cs_delay;
    return qspi_compute_xip_budget(clk_div, frame_sclk, ctx.is_expect_slverr());
  endfunction

  function automatic bit has_active_xip_spi_frame();
    if (cfg.flash_vif != null) begin
      return spi_frame_active && spi_frame_has_owner &&
             (active_spi_exp.owner == XIP_SPI_OWNER_XIP) &&
             (cfg.flash_vif.qspi_cs_n === 1'b0);
    end
    foreach (pending_spi_q[i]) begin
      if (pending_spi_q[i].owner == XIP_SPI_OWNER_XIP)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  function automatic bit has_uncompleted_xip_spi();
    foreach (in_flight_ar_q[i]) begin
      if (!in_flight_ar_q[i].spi_completed && !in_flight_ar_q[i].expect_no_spi)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  function void remove_ctx_from_pending_spi(input qspi_xip_ctx target);
    if (spi_frame_active && spi_frame_has_owner &&
        active_spi_exp.owner == XIP_SPI_OWNER_XIP && active_spi_exp.ctx == target) begin
      spi_frame_has_owner = 1'b0;
      return;
    end
    for (int i = 0; i < pending_spi_q.size(); i++) begin
      if (pending_spi_q[i].owner == XIP_SPI_OWNER_XIP && pending_spi_q[i].ctx == target) begin
        pending_spi_q.delete(i);
        return;
      end
    end
  endfunction

  function void remove_unstarted_pending_spi(input qspi_xip_ctx target);
    for (int i = 0; i < pending_spi_q.size(); i++) begin
      if (pending_spi_q[i].owner == XIP_SPI_OWNER_XIP && pending_spi_q[i].ctx == target) begin
        pending_spi_q.delete(i);
        return;
      end
    end
  endfunction

  // -------------------------------------------------------------------------
  // TLM 1: Accepted AXI4-Lite Read Address (ar_ap)
  // -------------------------------------------------------------------------
  function void write_xip_axil_ar(axil_master_transaction tr);
    xip_axil_obs_t obs;
    if (tr == null) begin
      `uvm_error("XIP_SB_NULL", "Null transaction received on axil_ar_export")
      total_r_mismatches++;
      return;
    end
    obs.tr       = tr;
    obs.obs_time = $time;
    ar_batch_q.push_back(obs);
  endfunction

  function void process_axil_ar(axil_master_transaction tr, time obs_time);
    qspi_xip_ctx     ctx;
    xip_spi_expect_t spi_exp;
    bit [1:0]        addr_bytes_enc;
    bit              prelaunch_err;

    if ($isunknown(tr.addr) || $isunknown(tr.prot)) begin
      `uvm_error("XIP_AR_XZ", $sformatf("Accepted AR contains X/Z: addr=0x%08h prot=%03b", tr.addr, tr.prot))
      total_r_mismatches++;
      return;
    end
    prelaunch_err = 1'b0;
    if (!(csr.ctrl[0] && csr.ctrl[1])) begin
      `uvm_error("XIP_AR_WHEN_DISABLED", $sformatf(
        "DUT accepted AR=0x%08h while pre-edge CTRL.{XIP_EN,ENABLE}=%02b (CTRL=0x%08h)",
        tr.addr, csr.ctrl[1:0], csr.ctrl))
      isolation_violations++;
      prelaunch_err = 1'b1;
    end

    addr_bytes_enc = csr.xip_cfg[7:6];
    if (addr_bytes_enc == 2'b11) begin
      `uvm_error("XIP_CFG_ADDR_BYTES_RSVD", $sformatf(
        "Reserved XIP_CFG.ADDR_BYTES encoding %02b active on AR=0x%08h (expected 00=0B, 01=3B, or 10=4B)",
        addr_bytes_enc, tr.addr))
      isolation_violations++;
      prelaunch_err = 1'b1;
    end
    if (csr.xip_cfg[1:0] == 2'b11 || csr.xip_cfg[3:2] == 2'b11 || csr.xip_cfg[5:4] == 2'b11) begin
      `uvm_error("XIP_CFG_LANES_RSVD", $sformatf(
        "Reserved XIP_CFG lane encoding (2'b11) active on AR=0x%08h (XIP_CFG=0x%08h)",
        tr.addr, csr.xip_cfg))
      isolation_violations++;
      prelaunch_err = 1'b1;
    end

    ctx = qspi_xip_ctx::type_id::create($sformatf("xip_ctx_%0d", next_accept_seq));
    ctx.epoch                  = current_epoch;
    ctx.mon_birth_epoch        = tr.birth_epoch;
    ctx.accept_seq             = next_accept_seq++;
    ctx.araddr                 = tr.addr;
    ctx.arprot                 = tr.prot;
    ctx.ar_accept_cycle        = tr.ar_accept_cycle;
    ctx.ar_accept_time         = obs_time;
    ctx.ar_wait                = tr.ar_wait;
    ctx.is_unaligned           = (tr.addr[1:0] != 2'b00);
    ctx.snap_ctrl              = csr.ctrl;
    ctx.snap_clk_div           = csr.clk_div;
    ctx.snap_cs_ctrl           = csr.cs_ctrl;
    ctx.snap_xip_cfg           = csr.xip_cfg;
    ctx.snap_xip_cmd           = csr.xip_cmd;
    ctx.addr_bytes             = (addr_bytes_enc == 2'b10) ? 4 :
                                 (addr_bytes_enc == 2'b01) ? 3 : 0;
    ctx.flash_addr             = (ctx.addr_bytes == 0) ? 32'h0 :
                                 (ctx.addr_bytes == 3) ? {8'h00, tr.addr[23:0]} : tr.addr;
    // Derive expected SLVERR & unaligned characterization strictly from passive observation.
    ctx.expected_resp          = (verified_pio_prefill_words >= 4) ? 2'b10 : 2'b00;
    ctx.characterize_unaligned = (cfg != null && cfg.xip_allow_unaligned_char &&
                                  ctx.is_unaligned && verified_pio_prefill_words < 4);
    ctx.expect_no_spi          = prelaunch_err;

    if (ctx.addr_bytes == 0 && ctx.snap_xip_cmd[7:0] == 8'h9F) begin
      for (int i = 0; i < 4; i++) ctx.expected_bytes[i] = jedec_id[i % 3];
    end else if (ctx.addr_bytes == 0 && ctx.snap_xip_cmd[7:0] == 8'h05) begin
      bit [7:0] sr;
      sr = {flash_status_reg[7:2], flash_wel, 1'b0};
      for (int i = 0; i < 4; i++) ctx.expected_bytes[i] = sr;
    end else begin
      for (int i = 0; i < 4; i++) begin
        ctx.expected_bytes[i] = get_flash_byte(ctx.flash_addr + i);
      end
    end
    ctx.expected_data = qspi_pack_word_le(
      ctx.expected_bytes[0], ctx.expected_bytes[1],
      ctx.expected_bytes[2], ctx.expected_bytes[3]
    );
    if (ctx.ar_wait > 0)
      total_ar_wait_nonzero++;

    in_flight_ar_q.push_back(ctx);
    if (!ctx.expect_no_spi) begin
      spi_exp.epoch                   = current_epoch;
      spi_exp.owner                   = XIP_SPI_OWNER_XIP;
      spi_exp.ctx                     = ctx;
      spi_exp.non_xip_dir             = 1'b0;
      spi_exp.is_dma_cmd              = 1'b0;
      spi_exp.non_xip_opcode          = 8'h00;
      spi_exp.non_xip_addr            = 32'h0;
      spi_exp.non_xip_addr_bytes      = 0;
      spi_exp.non_xip_len             = 0;
      spi_exp.non_xip_dma_addr        = 32'h0;
      spi_exp.non_xip_dma_incr        = 1'b0;
      spi_exp.has_tx_source           = 1'b0;
      spi_exp.dma_prov_failed         = 1'b0;
      spi_exp.dma_prov_next_addr      = 32'h0;
      spi_exp.dma_prov_bytes_captured = 0;
      spi_exp.expected_tx_bytes.delete();
      pending_spi_q.push_back(spi_exp);
    end
    total_ar_accepted++;

    if (in_flight_ar_q.size() > max_outstanding_observed)
      max_outstanding_observed = in_flight_ar_q.size();

    if (max_expected_outstanding > 0 && in_flight_ar_q.size() > max_expected_outstanding) begin
      `uvm_error("XIP_CAPACITY_EXCEEDED", $sformatf(
        "Outstanding AR depth %0d exceeded max_expected_outstanding=%0d (seq=%0d addr=0x%08h)",
        in_flight_ar_q.size(), max_expected_outstanding, ctx.accept_seq, tr.addr))
    end
  endfunction

  // -------------------------------------------------------------------------
  // TLM 2: AXI4-Lite Read Completion / Reset Abort (ap)
  // -------------------------------------------------------------------------
  function void write_xip_axil_r(axil_master_transaction tr);
    xip_axil_obs_t obs;
    if (tr == null) begin
      `uvm_error("XIP_SB_NULL", "Null transaction received on axil_r_export")
      total_r_mismatches++;
      return;
    end
    // Reset aborts process immediately so in_flight_ar_q drains cleanly even during reset.
    if (tr.reset_abort || cfg.clk_vif.rst_n !== 1'b1) begin
      process_axil_r(tr, $time);
      return;
    end
    obs.tr       = tr;
    obs.obs_time = $time;
    r_batch_q.push_back(obs);
  endfunction

  function void check_spi_before_r(qspi_xip_ctx ctx);
    if (ctx == null || ctx.early_r_reported || ctx.is_expect_slverr() || ctx.expect_no_spi)
      return;
    if (ctx.rvalid_seen && ctx.spi_completed && ctx.r_first_valid_at < ctx.spi_completed_at) begin
      ctx.early_r_reported = 1'b1;
      `uvm_error("XIP_R_BEFORE_SPI", $sformatf(
        "seq=%0d addr=0x%08h asserted RVALID at %0t before last payload byte completed at %0t",
        ctx.accept_seq, ctx.araddr, ctx.r_first_valid_at, ctx.spi_completed_at))
      total_r_mismatches++;
    end
  endfunction

  function void check_early_r_on_reset(qspi_xip_ctx ctx, time rst_time);
    if (ctx == null || ctx.early_r_reported || ctx.is_expect_slverr() || ctx.expect_no_spi)
      return;
    if (ctx.rvalid_seen && !ctx.spi_completed && ctx.r_first_valid_at < rst_time) begin
      ctx.early_r_reported = 1'b1;
      `uvm_error("XIP_R_BEFORE_SPI", $sformatf(
        "seq=%0d addr=0x%08h asserted RVALID at %0t and reset occurred at %0t before SPI completed",
        ctx.accept_seq, ctx.araddr, ctx.r_first_valid_at, rst_time))
      total_r_mismatches++;
    end
  endfunction

  function void process_axil_r(axil_master_transaction tr, time obs_time);
    qspi_xip_ctx     ctx;
    int              abort_idx;
    longint unsigned l_first;
    longint unsigned l_complete;
    longint unsigned budget;

    if (tr.reset_abort) begin
      if (!tr.ar_accepted)
        return; // Unaccepted AR aborts are outside accepted conservation.

      flush_ar_batch_only();
      abort_idx = -1;
      for (int i = 0; i < in_flight_ar_q.size(); i++) begin
        if (in_flight_ar_q[i].mon_birth_epoch == tr.birth_epoch &&
            in_flight_ar_q[i].ar_accept_cycle == tr.ar_accept_cycle &&
            in_flight_ar_q[i].araddr === tr.addr) begin
          abort_idx = i;
          break;
        end
      end

      if (abort_idx < 0) begin
        `uvm_error("XIP_ABORT_ORPHAN", $sformatf(
          "Reset-abort lineage mismatch: addr=0x%08h birth_epoch=%0d ar_cycle=%0d pending=%0d",
          tr.addr, tr.birth_epoch, tr.ar_accept_cycle, in_flight_ar_q.size()))
        total_r_mismatches++;
        return;
      end

      ctx = in_flight_ar_q[abort_idx];
      ctx.spi_validation_deferred = 1'b0;
      check_early_r_on_reset(ctx, $time);
      in_flight_ar_q.delete(abort_idx);
      remove_ctx_from_pending_spi(ctx);
      total_reset_aborts++;
      return;
    end

    if (in_flight_ar_q.size() == 0) begin
      `uvm_error("XIP_ORPHAN_R", $sformatf(
        "Observed R completion (data=0x%08h resp=%02b) with empty in_flight_ar_q",
        tr.data, tr.resp))
      total_r_mismatches++;
      return;
    end

    ctx = in_flight_ar_q.pop_front();
    ctx.axi_retired        = 1'b1;
    if (!ctx.rvalid_seen)
      ctx.r_first_valid_at = obs_time;
    ctx.rvalid_seen        = 1'b1;
    ctx.first_rvalid_cycle = tr.first_rvalid_cycle;
    ctx.r_complete_cycle   = tr.r_complete_cycle;
    ctx.r_stall            = tr.r_stall;
    total_r_completed++;
    if (ctx.r_stall > max_r_stall_observed)
      max_r_stall_observed = ctx.r_stall;
    if (ctx.r_stall > 0 && (tr.resp inside {2'b00, 2'b10}))
      total_r_post_valid_stall_completed++;
    if (ctx.disable_seen)
      total_disable_seen++;

    if (ctx.characterize_unaligned && ctx.is_unaligned) begin
      if (tr.resp inside {2'b00, 2'b10}) begin
        ctx.expected_resp = tr.resp;
      end
      if (tr.resp === 2'b10) begin
        remove_unstarted_pending_spi(ctx);
      end
      if (ctx.spi_validation_deferred) begin
        ctx.spi_validation_deferred = 1'b0;
        finalize_xip_spi_frame(ctx, ctx.deferred_spi_tr, ctx.is_expect_slverr());
      end
    end

    if (tr.resp !== 2'b10)
      check_spi_before_r(ctx);
    if (!ctx.spi_completed && !ctx.is_expect_slverr() && !ctx.expect_no_spi &&
        tr.resp === 2'b00) begin
      retired_awaiting_spi_q.push_back(ctx);
    end

    if ($isunknown(tr.resp)) begin
      `uvm_error("XIP_RRESP_XZ", $sformatf(
        "seq=%0d addr=0x%08h returned X/Z RRESP=%02b", ctx.accept_seq, ctx.araddr, tr.resp))
      total_r_mismatches++;
      return;
    end

    if (tr.resp === 2'b10)
      total_slverr_observed++;

    if (ctx.characterize_unaligned && ctx.is_unaligned) begin
      `uvm_info("XIP_UNALIGNED_CHAR", $sformatf(
        "seq=%0d unaligned AR=0x%08h mapped_flash=0x%08h -> observed resp=%02b rdata=0x%08h (oracle_raw_le=0x%08h)",
        ctx.accept_seq, ctx.araddr, ctx.flash_addr, tr.resp, tr.data, ctx.expected_data), UVM_LOW)
      if (!(tr.resp inside {2'b00, 2'b10})) begin
        `uvm_error("XIP_UNEXPECTED_RRESP", $sformatf(
          "seq=%0d unaligned AR returned illegal AXI4-Lite RRESP=%02b", ctx.accept_seq, tr.resp))
        total_r_mismatches++;
      end else if (tr.resp === 2'b00 && $isunknown(tr.data)) begin
        `uvm_error("XIP_RDATA_XZ", $sformatf("seq=%0d unaligned OKAY RDATA has X/Z", ctx.accept_seq))
        total_r_mismatches++;
      end else begin
        total_r_char_matched++;
        total_r_matched++;
      end
    end else if (ctx.is_expect_slverr()) begin
      if (tr.resp !== 2'b10) begin
        `uvm_error("XIP_SLVERR_MISS", $sformatf(
          "seq=%0d addr=0x%08h expected SLVERR (2'b10), got RRESP=%02b RDATA=0x%08h",
          ctx.accept_seq, ctx.araddr, tr.resp, tr.data))
        total_r_mismatches++;
      end else begin
        total_r_slverr_matched++;
        total_r_matched++;
      end
    end else begin
      if (tr.resp !== 2'b00) begin
        `uvm_error("XIP_UNEXPECTED_RRESP", $sformatf(
          "seq=%0d addr=0x%08h expected OKAY (2'b00), got RRESP=%02b RDATA=0x%08h",
          ctx.accept_seq, ctx.araddr, tr.resp, tr.data))
        total_r_mismatches++;
      end else if (tr.data !== ctx.expected_data) begin
        `uvm_error("XIP_RDATA_MISMATCH", $sformatf(
          "seq=%0d AR=0x%08h flash=0x%08h disable_seen=%0b: expected RDATA=0x%08h (LE bytes %02h %02h %02h %02h), got 0x%08h",
          ctx.accept_seq, ctx.araddr, ctx.flash_addr, ctx.disable_seen,
          ctx.expected_data,
          ctx.expected_bytes[0], ctx.expected_bytes[1],
          ctx.expected_bytes[2], ctx.expected_bytes[3], tr.data))
        total_r_mismatches++;
      end else begin
        total_r_data_matched++;
        total_r_matched++;
      end
    end

    // Latency accounting (diagnostic watchdog separate from functional spec pass/fail)
    if (ctx.r_complete_cycle >= ctx.ar_accept_cycle) begin
      l_complete = ctx.r_complete_cycle - ctx.ar_accept_cycle;
      if (l_complete > max_total_r_latency) max_total_r_latency = l_complete;
    end
    if (ctx.first_rvalid_cycle >= ctx.ar_accept_cycle && ctx.first_rvalid_cycle > 0) begin
      l_first = ctx.first_rvalid_cycle - ctx.ar_accept_cycle;
      if (l_first > max_first_r_latency) max_first_r_latency = l_first;
      budget = compute_first_rvalid_budget(ctx);
      if (l_first > budget) begin
        latency_budget_exceeded++;
        if (enforce_latency_budget) begin
          `uvm_error("XIP_LATENCY_BUDGET", $sformatf(
            "seq=%0d addr=0x%08h first-RVALID latency=%0d ACLK exceeded budget=%0d ACLK",
            ctx.accept_seq, ctx.araddr, l_first, budget))
        end else begin
          `uvm_warning("XIP_LATENCY_WATCHDOG", $sformatf(
            "seq=%0d addr=0x%08h first-RVALID latency=%0d ACLK exceeded heuristic budget=%0d ACLK (diagnostic only)",
            ctx.accept_seq, ctx.araddr, l_first, budget))
        end
        ctx.timeout_reported = 1'b1;
      end
    end
  endfunction

  // -------------------------------------------------------------------------
  // TLM 3: Completed APB CSR Observation (Shadow CSR + TC_005/TC_033/TC_034)
  // -------------------------------------------------------------------------
  function void write_xip_apb(qspi_apb_item_t tr);
    if (tr == null) begin
      `uvm_error("XIP_SB_NULL", "Null transaction received on apb_export")
      isolation_violations++;
      return;
    end
    if (tr.reset_abort || cfg.clk_vif.rst_n !== 1'b1)
      return;
    apb_batch_q.push_back(tr);
  endfunction

  function void process_apb(qspi_apb_item_t tr);
    bit              xip_active_now;
    bit              spi_shifting_now;
    bit              prev_xip_en;
    xip_spi_expect_t non_xip_exp;

    if ($isunknown({tr.addr, tr.write, tr.strb, tr.slverr})) begin
      `uvm_error("XIP_APB_XZ", "APB control signals contain X/Z")
      isolation_violations++;
      return;
    end

    xip_active_now   = (in_flight_ar_q.size() > 0 || has_active_xip_spi_frame());
    spi_shifting_now = has_active_xip_spi_frame() &&
      ((cfg.flash_vif == null) ? 1'b1 : (tr.completed_at > last_cs_assert_at));

    // Track & validate concurrent APB accesses during active XIP transfer (TC_033)
    if (xip_active_now) begin
      concurrent_apb_count++;

      if (!tr.write) begin
        case (tr.addr)
          QSPI_REG_ID: begin
            if (tr.slverr !== 1'b0) begin
              `uvm_error("XIP_TC033_APB_SLVERR", "Concurrent ID read unexpectedly returned PSLVERR=1")
              isolation_violations++;
            end else begin
              if (spi_shifting_now) conc_rd_id_count++;
              if (tr.rdata !== QSPI_ID_VALUE) begin
                `uvm_error("XIP_TC033_ID_MISMATCH", $sformatf(
                  "Concurrent ID read returned 0x%08h, expected 0x%08h", tr.rdata, QSPI_ID_VALUE))
                isolation_violations++;
              end
            end
          end
          QSPI_REG_STATUS: begin
            if (tr.slverr !== 1'b0) begin
              `uvm_error("XIP_TC033_APB_SLVERR", "Concurrent STATUS read unexpectedly returned PSLVERR=1")
              isolation_violations++;
            end else begin
              if (spi_shifting_now) conc_rd_status_count++;
              if ($isunknown(tr.rdata[3:0])) begin
                `uvm_error("XIP_TC033_STATUS_XZ", $sformatf(
                  "Concurrent STATUS read returned X/Z flags: 0x%08h", tr.rdata))
                isolation_violations++;
              end
            end
          end
          QSPI_REG_FIFO_STAT: begin
            if (tr.slverr !== 1'b0) begin
              `uvm_error("XIP_TC033_APB_SLVERR", "Concurrent FIFO_STAT read unexpectedly returned PSLVERR=1")
              isolation_violations++;
            end else begin
              if (spi_shifting_now) conc_rd_fifo_stat_count++;
              if ($isunknown(tr.rdata) || (tr.rdata[31:10] != 22'h0)) begin
                `uvm_error("XIP_TC033_FIFO_STAT_BAD", $sformatf(
                  "Concurrent FIFO_STAT read invalid/reserved non-zero: 0x%08h", tr.rdata))
                isolation_violations++;
              end
            end
          end
          QSPI_REG_READ_RX: begin
            `uvm_error("XIP_TC033_FORBIDDEN_READ_RX",
              "Stimulus read READ_RX (0x048) while XIP transfer is active (risks popping RX FIFO)")
            isolation_violations++;
          end
          default: ;
        endcase
      end else begin
        case (tr.addr)
          QSPI_REG_INT_EN: begin
            if (tr.slverr !== 1'b0) begin
              `uvm_error("XIP_TC033_APB_SLVERR", "Concurrent INT_EN write unexpectedly returned PSLVERR=1")
              isolation_violations++;
            end else if (spi_shifting_now) begin
              conc_wr_int_en_count++;
            end
          end
          QSPI_REG_CTRL: begin
            if ((has_active_xip_spi_frame() || has_uncompleted_xip_spi()) &&
                !allow_mid_frame_csr_mut && tr.slverr === 1'b0) begin
              bit [31:0] new_ctrl;
              new_ctrl = qspi_csr_shadow::merge_pstrb(csr.ctrl, tr.wdata, tr.strb,
                                                      qspi_csr_writable_mask(QSPI_REG_CTRL));
              if (new_ctrl[4:2] !== csr.ctrl[4:2]) begin
                `uvm_error("XIP_TC033_CSR_MUTATION", $sformatf(
                  "Stimulus mutated CTRL.{CPHA,CPOL,QUAD_EN} (%03b -> %03b) while XIP SPI frame is active",
                  csr.ctrl[4:2], new_ctrl[4:2]))
                isolation_violations++;
              end
            end
          end
          QSPI_REG_CLK_DIV, QSPI_REG_CS_CTRL, QSPI_REG_XIP_CFG, QSPI_REG_XIP_CMD: begin
            if ((has_active_xip_spi_frame() || has_uncompleted_xip_spi()) &&
                !allow_mid_frame_csr_mut && tr.slverr === 1'b0) begin
              bit [31:0] old_val, new_val;
              old_val = csr.get_reg(tr.addr);
              new_val = qspi_csr_shadow::merge_pstrb(old_val, tr.wdata, tr.strb, qspi_csr_writable_mask(tr.addr));
              if (new_val !== old_val) begin
                `uvm_error("XIP_TC033_CSR_MUTATION", $sformatf(
                  "Stimulus mutated XIP CSR addr=0x%03h (0x%08h -> 0x%08h, wdata=0x%08h strb=%04b) while XIP SPI frame is active",
                  tr.addr, old_val, new_val, tr.wdata, tr.strb))
                isolation_violations++;
              end
            end
          end
          default: ;
        endcase
      end
    end

    // Track legitimate APB READ_RX drains when XIP is not active
    if (!tr.write && !tr.slverr && tr.addr == QSPI_REG_READ_RX) begin
      if (verified_pio_prefill_words > 0)
        verified_pio_prefill_words--;
    end

    // Update shadow CSRs & track non-XIP PIO/DMA TX provenance and launches
    if (tr.write && !tr.slverr) begin
      bit triggered;
      for (int lane = 0; lane < 4; lane++) begin
        if (tr.strb[lane] && $isunknown(tr.wdata[8*lane +: 8])) begin
          `uvm_error("XIP_APB_WDATA_XZ", $sformatf(
            "APB write addr=0x%03h lane %0d has X/Z wdata", tr.addr, lane))
          isolation_violations++;
          return;
        end
      end

      if (tr.addr == QSPI_REG_WRITE_TX) begin
        bit [31:0] tx_w;
        tx_w = qspi_csr_shadow::merge_pstrb(32'h0, tr.wdata, tr.strb, 32'hFFFF_FFFF);
        if (tx_fifo_shadow_words.size() < 4)
          tx_fifo_shadow_words.push_back(tx_w);
        return;
      end

      prev_xip_en = csr.ctrl[1];
      triggered   = csr.apply_apb_write(tr);
      if (prev_xip_en && !csr.ctrl[1]) begin
        foreach (in_flight_ar_q[i])
          in_flight_ar_q[i].disable_seen = 1'b1;
      end

      if (triggered) begin
        qspi_cmd_profile_t cp;
        int                ab;
        cp = csr.get_cmd_snapshot();
        ab = qspi_enc_to_addr_bytes(cp.addr_bytes_enc);
        non_xip_exp.epoch                   = current_epoch;
        non_xip_exp.owner                   = XIP_SPI_OWNER_NON_XIP;
        non_xip_exp.ctx                     = null;
        non_xip_exp.non_xip_dir             = cp.dir;
        non_xip_exp.is_dma_cmd              = (tr.strb[1] === 1'b1) && (tr.wdata[9] === 1'b1);
        non_xip_exp.non_xip_opcode          = cp.opcode;
        non_xip_exp.non_xip_addr_bytes      = (ab > 0) ? ab : 0;
        non_xip_exp.non_xip_addr            = (ab == 3) ? {8'h00, cp.cmd_addr[23:0]} :
                                              (ab == 4) ? cp.cmd_addr : 32'h0;
        non_xip_exp.non_xip_len             = cp.cmd_len;
        non_xip_exp.non_xip_dma_addr        = cp.dma_addr;
        non_xip_exp.non_xip_dma_incr        = cp.dma_incr_addr;
        non_xip_exp.has_tx_source           = 1'b0;
        non_xip_exp.dma_prov_failed         = 1'b0;
        non_xip_exp.dma_prov_next_addr      = cp.dma_addr;
        non_xip_exp.dma_prov_bytes_captured = 0;
        non_xip_exp.expected_tx_bytes.delete();

        // For PIO TX (non-DMA write), unpack Little-Endian bytes from APB WRITE_TX shadow
        if (!cp.dir && !non_xip_exp.is_dma_cmd && cp.cmd_len > 0) begin
          int unsigned needed_words;
          needed_words = (cp.cmd_len + 32'd3) >> 2;
          if (tx_fifo_shadow_words.size() >= needed_words) begin
            for (int unsigned w = 0; w < needed_words; w++) begin
              bit [31:0] wd;
              wd = tx_fifo_shadow_words.pop_front();
              for (int lane = 0; lane < 4 && non_xip_exp.expected_tx_bytes.size() < cp.cmd_len; lane++) begin
                non_xip_exp.expected_tx_bytes.push_back(wd[lane*8 +: 8]);
              end
            end
            non_xip_exp.has_tx_source = 1'b1;
          end else begin
            while (tx_fifo_shadow_words.size() > 0) begin
              bit [31:0] wd;
              wd = tx_fifo_shadow_words.pop_front();
              for (int lane = 0; lane < 4 && non_xip_exp.expected_tx_bytes.size() < cp.cmd_len; lane++) begin
                non_xip_exp.expected_tx_bytes.push_back(wd[lane*8 +: 8]);
              end
            end
            non_xip_exp.has_tx_source = (non_xip_exp.expected_tx_bytes.size() >= cp.cmd_len);
          end
        end
        pending_spi_q.push_back(non_xip_exp);
      end
    end
  endfunction

  // -------------------------------------------------------------------------
  // TLM 4: Physical SPI Frame Observation (flash_agt.monitor.ref_port)
  // -------------------------------------------------------------------------
  function void finalize_xip_spi_frame(
    input qspi_xip_ctx     ctx,
    input qspi_transaction tr,
    input bit              is_slverr_mode
  );
    bit          frame_ok;
    bit          is_char_mode;
    bit [31:0]   obs_addr_masked;
    bit [31:0]   exp_addr_masked;
    int unsigned exp_edges;
    int unsigned cs_delay;
    int unsigned l_data;
    int unsigned max_stop_bytes;
    int unsigned prefix_len;

    if (ctx == null || tr == null)
      return;

    is_char_mode = (ctx.characterize_unaligned && ctx.is_unaligned);
    cs_delay     = int'(ctx.snap_cs_ctrl[3:2]);
    exp_edges    = calc_wire_sclk_cycles(ctx);

    if (!is_slverr_mode && tr.byte_completed_at.size() >= 4 && tr.byte_completed_at[3] > 0)
      ctx.spi_completed_at = tr.byte_completed_at[3];
    else if (!is_slverr_mode && tr.data_completed_at > 0)
      ctx.spi_completed_at = tr.data_completed_at;
    else
      ctx.spi_completed_at = (tr.completed_at > 0) ? tr.completed_at : $time;
    check_spi_before_r(ctx);
    frame_ok = 1'b1;

    // Only report early abort when the frame terminated before all 4 XIP payload bytes
    // completed; trailing clocks after byte 3 are checked once by XIP_SPI_EDGES_MISMATCH.
    if (tr.aborted_early && !is_slverr_mode && (tr.end_phase < 4 || tr.data.size() < 4)) begin
      `uvm_error("XIP_SPI_ABORTED_EARLY", $sformatf(
        "seq=%0d SPI frame aborted_early=%0b end_phase=%0d data_bytes=%0d (AR=0x%08h)",
        ctx.accept_seq, tr.aborted_early, tr.end_phase, tr.data.size(), ctx.araddr))
      frame_ok = 1'b0;
    end

    if (!is_slverr_mode || tr.end_phase >= 1) begin
      if ($isunknown(tr.opcode) || tr.opcode !== ctx.snap_xip_cmd[7:0]) begin
        `uvm_error("XIP_SPI_OPCODE_MISMATCH", $sformatf(
          "seq=%0d SPI opcode mismatch: expected 0x%02h, got 0x%02h",
          ctx.accept_seq, ctx.snap_xip_cmd[7:0], tr.opcode))
        frame_ok = 1'b0;
      end
    end

    if (ctx.addr_bytes != 0 && (!is_slverr_mode || tr.end_phase >= 2)) begin
      obs_addr_masked = (ctx.addr_bytes == 3) ? {8'h00, tr.addr[23:0]} : tr.addr;
      exp_addr_masked = (ctx.addr_bytes == 3) ? {8'h00, ctx.flash_addr[23:0]} : ctx.flash_addr;
      if ($isunknown(tr.addr) || (obs_addr_masked !== exp_addr_masked)) begin
        `uvm_error("XIP_SPI_ADDR_MISMATCH", $sformatf(
          "seq=%0d SPI addr mismatch (%0dB): expected 0x%08h, got 0x%08h",
          ctx.accept_seq, ctx.addr_bytes, exp_addr_masked, obs_addr_masked))
        frame_ok = 1'b0;
      end
    end

    if (ctx.snap_xip_cfg[8] && (!is_slverr_mode || tr.end_phase >= 3)) begin
      if ($isunknown(tr.mode_bits) || tr.mode_bits !== ctx.snap_xip_cmd[23:16]) begin
        `uvm_error("XIP_SPI_MODE_MISMATCH", $sformatf(
          "seq=%0d SPI mode_bits mismatch: expected 0x%02h, got 0x%02h",
          ctx.accept_seq, ctx.snap_xip_cmd[23:16], tr.mode_bits))
        frame_ok = 1'b0;
      end
    end

    l_data         = qspi_eff_lanes(ctx.snap_xip_cfg[5:4], ctx.snap_ctrl[2]);
    if (l_data == 0) l_data = 1;
    max_stop_bytes = (cs_delay * l_data) / 8;

    if (!is_slverr_mode) begin
      if (tr.sclk_edges_total < exp_edges || tr.sclk_edges_total > (exp_edges + cs_delay)) begin
        `uvm_error("XIP_SPI_EDGES_MISMATCH", $sformatf(
          "seq=%0d SCLK edges=%0d outside [%0d .. %0d] (CS_DELAY=%0d, AR=0x%08h)",
          ctx.accept_seq, tr.sclk_edges_total, exp_edges, exp_edges + cs_delay, cs_delay, ctx.araddr))
        frame_ok = 1'b0;
      end
      if (tr.data.size() < 4 || tr.data.size() > (4 + max_stop_bytes)) begin
        `uvm_error("XIP_SPI_LEN_MISMATCH", $sformatf(
          "seq=%0d expected 4 payload bytes (allow +%0d STOP_CS), observed %0d",
          ctx.accept_seq, max_stop_bytes, tr.data.size()))
        frame_ok = 1'b0;
      end else begin
        for (int i = 0; i < 4; i++) begin
          if ($isunknown(tr.data[i])) begin
            `uvm_error("XIP_SPI_DATA_XZ", $sformatf(
              "seq=%0d SPI byte[%0d] contains X/Z: 0x%02h", ctx.accept_seq, i, tr.data[i]))
            frame_ok = 1'b0;
            break;
          end else if (!is_char_mode && tr.data[i] !== ctx.expected_bytes[i]) begin
            `uvm_error("XIP_SPI_DATA_MISMATCH", $sformatf(
              "seq=%0d SPI byte[%0d] mismatch at flash=0x%08h: expected 0x%02h, got 0x%02h",
              ctx.accept_seq, i, ctx.flash_addr + i, ctx.expected_bytes[i], tr.data[i]))
            frame_ok = 1'b0;
            break;
          end
        end
      end
    end else begin
      prefix_len = (tr.data.size() < 4) ? tr.data.size() : 4;
      if (tr.sclk_edges_total > (exp_edges + cs_delay + 2000)) begin
        `uvm_error("XIP_SPI_EDGES_OVERFLOW", $sformatf(
          "seq=%0d SLVERR SCLK edges=%0d exceeded error-path upper bound=%0d",
          ctx.accept_seq, tr.sclk_edges_total, exp_edges + cs_delay + 2000))
        frame_ok = 1'b0;
      end
      if (!tr.aborted_early && tr.data.size() > (4 + max_stop_bytes)) begin
        `uvm_error("XIP_SPI_LEN_MISMATCH", $sformatf(
          "seq=%0d SLVERR full SPI frame exceeded 4 (+%0d STOP_CS) bytes: got %0d",
          ctx.accept_seq, max_stop_bytes, tr.data.size()))
        frame_ok = 1'b0;
      end
      for (int i = 0; i < prefix_len; i++) begin
        if ($isunknown(tr.data[i])) begin
          `uvm_error("XIP_SPI_DATA_XZ", $sformatf(
            "seq=%0d SLVERR-mode SPI byte[%0d] contains X/Z: 0x%02h", ctx.accept_seq, i, tr.data[i]))
          frame_ok = 1'b0;
          break;
        end else if (!is_char_mode && tr.data[i] !== ctx.expected_bytes[i]) begin
          `uvm_error("XIP_SPI_DATA_MISMATCH", $sformatf(
            "seq=%0d SLVERR-mode SPI prefix byte[%0d] mismatch at flash=0x%08h: expected 0x%02h, got 0x%02h",
            ctx.accept_seq, i, ctx.flash_addr + i, ctx.expected_bytes[i], tr.data[i]))
          frame_ok = 1'b0;
          break;
        end
      end
    end

    if (frame_ok) begin
      total_spi_matched++;
      if (is_slverr_mode) total_spi_slverr_matched++;
      else                total_spi_ok_matched++;
    end else begin
      total_spi_mismatches++;
    end
  endfunction

  function void write_xip_spi(qspi_transaction tr);
    xip_spi_expect_t spi_exp;
    qspi_xip_ctx     ctx;
    bit              is_char_mode;
    qspi_transaction tr_copy;

    if (tr == null) begin
      `uvm_error("XIP_SB_NULL", "Null transaction received on spi_export")
      total_spi_mismatches++;
      return;
    end

    // Reject SPI frames cut short by an active or recent asynchronous reset.
    if (has_runtime_reset && tr.started_at <= last_reset_assert_at) begin
      total_spi_reset_aborts++;
      spi_frame_active    = 1'b0;
      spi_frame_has_owner = 1'b0;
      return;
    end

    // Consume pre-claimed CS owner when flash_vif is present; otherwise pop pending_spi_q.
    if (cfg.flash_vif != null) begin
      spi_frame_active = 1'b0;
      if (!spi_frame_has_owner) begin
        `uvm_error("XIP_UNEXPECTED_SPI", $sformatf(
          "Observed unowned SPI frame (op=0x%02h addr=0x%08h bytes=%0d)",
          tr.opcode, tr.addr, tr.data.size()))
        total_spi_mismatches++;
        return;
      end
      spi_exp             = active_spi_exp;
      spi_frame_has_owner = 1'b0;
    end else begin
      if (pending_spi_q.size() == 0) begin
        `uvm_error("XIP_UNEXPECTED_SPI", $sformatf(
          "Observed SPI frame (op=0x%02h addr=0x%08h bytes=%0d) with empty pending_spi_q",
          tr.opcode, tr.addr, tr.data.size()))
        total_spi_mismatches++;
        return;
      end
      spi_exp = pending_spi_q.pop_front();
    end

    if (spi_exp.owner == XIP_SPI_OWNER_NON_XIP) begin
      bit          meta_ok;
      logic [31:0] obs_addr;
      int unsigned erase_sz;
      int unsigned exp_len;
      int unsigned max_aligned_bytes;
      logic [7:0]  src_bytes[$];
      bit          src_ok;
      bit          tx_match;

      total_non_xip_spi_frames++;
      if (tr.aborted_early)
        return;

      // Validate observed SPI command metadata against the APB command snapshot
      // BEFORE trusting it to update any golden Flash state or RX prefill model.
      meta_ok  = 1'b1;
      obs_addr = (spi_exp.non_xip_addr_bytes == 3) ? {8'h00, tr.addr[23:0]} :
                 (spi_exp.non_xip_addr_bytes == 4) ? tr.addr : 32'h0;

      if ($isunknown(tr.opcode) || tr.opcode !== spi_exp.non_xip_opcode) begin
        `uvm_error("XIP_NONXIP_OPCODE_MISMATCH", $sformatf(
          "Non-XIP SPI opcode mismatch: observed=0x%02h expected(APB)=0x%02h; refusing golden oracle update",
          tr.opcode, spi_exp.non_xip_opcode))
        total_spi_mismatches++;
        meta_ok = 1'b0;
      end
      if (spi_exp.non_xip_addr_bytes != 0 &&
          ($isunknown(obs_addr) || obs_addr !== spi_exp.non_xip_addr)) begin
        `uvm_error("XIP_NONXIP_ADDR_MISMATCH", $sformatf(
          "Non-XIP SPI addr mismatch for op=0x%02h: observed=0x%08h expected(APB)=0x%08h (%0dB); refusing golden oracle update",
          spi_exp.non_xip_opcode, obs_addr, spi_exp.non_xip_addr, spi_exp.non_xip_addr_bytes))
        total_spi_mismatches++;
        meta_ok = 1'b0;
      end

      if (!meta_ok)
        return;

      // Per-command TX provenance bound strictly to this spi_exp (no cross-command sharing).
      exp_len           = spi_exp.non_xip_len;
      max_aligned_bytes = ((exp_len + 32'd3) >> 2) << 2;
      src_bytes         = spi_exp.expected_tx_bytes;
      src_ok            = 1'b0;
      if (!spi_exp.non_xip_dir && exp_len > 0) begin
        if (spi_exp.is_dma_cmd) begin
          src_ok = (!spi_exp.dma_prov_failed) &&
                   spi_exp.has_tx_source &&
                   (src_bytes.size() >= exp_len) &&
                   (spi_exp.dma_prov_bytes_captured == max_aligned_bytes);
        end else begin
          src_ok = spi_exp.has_tx_source && (src_bytes.size() >= exp_len);
        end
      end

      if (spi_exp.non_xip_dir && !spi_exp.is_dma_cmd && exp_len > 0) begin
        int unsigned pushed_w;
        if (tr.data.size() != exp_len) begin
          `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
            "Non-XIP PIO RX op=0x%02h length mismatch: observed=%0dB expected(APB)=%0dB",
            spi_exp.non_xip_opcode, tr.data.size(), exp_len))
          total_spi_mismatches++;
          return;
        end
        pushed_w = (exp_len + 32'd3) >> 2;
        verified_pio_prefill_words += pushed_w;
        if (verified_pio_prefill_words > 4)
          verified_pio_prefill_words = 4;
      end else if (!spi_exp.non_xip_dir) begin
        // Dispatch strictly on APB-expected opcode & APB-expected address (never DUT wire metadata)
        case (spi_exp.non_xip_opcode)
          8'h06: begin
            if (tr.data.size() != exp_len) begin
              `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                "Non-XIP WREN (0x06) length mismatch: observed=%0dB expected(APB)=%0dB",
                tr.data.size(), exp_len))
              total_spi_mismatches++;
            end else if (spi_exp.non_xip_addr_bytes == 0 && exp_len == 0) begin
              flash_wel = 1'b1;
            end
          end
          8'h04: begin
            if (tr.data.size() != exp_len) begin
              `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                "Non-XIP WRDI (0x04) length mismatch: observed=%0dB expected(APB)=%0dB",
                tr.data.size(), exp_len))
              total_spi_mismatches++;
            end else if (spi_exp.non_xip_addr_bytes == 0 && exp_len == 0) begin
              flash_wel = 1'b0;
            end
          end
          8'h01: begin
            if (spi_exp.non_xip_addr_bytes == 0 && exp_len >= 1) begin
              if (tr.data.size() != exp_len) begin
                `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                  "Non-XIP WRSR (0x01) length mismatch: observed=%0dB expected(APB)=%0dB",
                  tr.data.size(), exp_len))
                total_spi_mismatches++;
              end else if (!src_ok || $isunknown(src_bytes[0])) begin
                `uvm_error("XIP_DMA_SRC_XZ", "Non-XIP WRSR (0x01) lacked valid known APB/AXI source byte")
                total_spi_mismatches++;
              end else if ($isunknown(tr.data[0]) || tr.data[0] !== src_bytes[0]) begin
                `uvm_error("XIP_SB_TX_CORRUPT", $sformatf(
                  "Non-XIP WRSR (0x01) wire=0x%02h disagreed with APB/AXI source=0x%02h",
                  tr.data[0], src_bytes[0]))
                total_spi_mismatches++;
              end else if (flash_wel) begin
                flash_status_reg = src_bytes[0][7:0];
              end
            end
          end
          8'hC7: begin
            if (tr.data.size() != exp_len) begin
              `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                "Non-XIP Chip Erase (0xC7) length mismatch: observed=%0dB expected(APB)=%0dB",
                tr.data.size(), exp_len))
              total_spi_mismatches++;
            end else if (spi_exp.non_xip_addr_bytes == 0 && exp_len == 0) begin
              flash_ref_mem.delete();
            end
          end
          8'h20: begin
            if (tr.data.size() != exp_len) begin
              `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                "Non-XIP Sector Erase (0x20) length mismatch: observed=%0dB expected(APB)=%0dB",
                tr.data.size(), exp_len))
              total_spi_mismatches++;
            end else if (spi_exp.non_xip_addr_bytes != 0 && exp_len == 0) begin
              erase_sz = (cfg != null && cfg.flash_cfg_h != null) ? cfg.flash_cfg_h.sector_erase_bytes : 4096;
              erase_flash_ref_range(spi_exp.non_xip_addr, erase_sz);
            end
          end
          8'hD8: begin
            if (tr.data.size() != exp_len) begin
              `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                "Non-XIP Block Erase (0xD8) length mismatch: observed=%0dB expected(APB)=%0dB",
                tr.data.size(), exp_len))
              total_spi_mismatches++;
            end else if (spi_exp.non_xip_addr_bytes != 0 && exp_len == 0) begin
              erase_sz = (cfg != null && cfg.flash_cfg_h != null) ? cfg.flash_cfg_h.block_erase_bytes : 65536;
              erase_flash_ref_range(spi_exp.non_xip_addr, erase_sz);
            end
          end
          8'h02, 8'h32: begin
            if (spi_exp.non_xip_addr_bytes != 0 && exp_len > 0) begin
              if (tr.data.size() != exp_len) begin
                `uvm_error("XIP_NONXIP_LEN_MISMATCH", $sformatf(
                  "Non-XIP Program op=0x%02h addr=0x%08h length mismatch: observed=%0dB expected(APB)=%0dB; refusing golden oracle commit",
                  spi_exp.non_xip_opcode, spi_exp.non_xip_addr, tr.data.size(), exp_len))
                total_spi_mismatches++;
              end else if (!src_ok) begin
                `uvm_error("XIP_SB_TX_NO_SOURCE", $sformatf(
                  "Non-XIP TX op=0x%02h addr=0x%08h (%0dB) lacked APB/AXI source provenance; refusing blind SPI wire commit",
                  spi_exp.non_xip_opcode, spi_exp.non_xip_addr, exp_len))
                total_spi_mismatches++;
              end else begin
                tx_match = 1'b1;
                for (int unsigned i = 0; i < exp_len; i++) begin
                  if ($isunknown(src_bytes[i])) begin
                    `uvm_error("XIP_DMA_SRC_XZ", $sformatf(
                      "Non-XIP TX op=0x%02h addr=0x%08h byte[%0d] APB/AXI source contains X/Z (0x%02h)",
                      spi_exp.non_xip_opcode, spi_exp.non_xip_addr, i, src_bytes[i]))
                    total_spi_mismatches++;
                    tx_match = 1'b0;
                    break;
                  end
                  if ($isunknown(tr.data[i]) || tr.data[i] !== src_bytes[i]) begin
                    `uvm_error("XIP_SB_TX_CORRUPT", $sformatf(
                      "Non-XIP TX op=0x%02h addr=0x%08h byte[%0d] wire=0x%02h disagreed with APB/AXI source=0x%02h",
                      spi_exp.non_xip_opcode, spi_exp.non_xip_addr, i, tr.data[i], src_bytes[i]))
                    total_spi_mismatches++;
                    tx_match = 1'b0;
                    break;
                  end
                end
                if (tx_match) begin
                  for (int unsigned i = 0; i < exp_len; i++)
                    flash_ref_mem[spi_exp.non_xip_addr + i] = src_bytes[i][7:0];
                end
              end
            end
          end
          default: ;
        endcase
      end
      return;
    end

    ctx             = spi_exp.ctx;
    if (tr.started_at < ctx.ar_accept_time) begin
      `uvm_error("XIP_SPI_STARTED_BEFORE_AR", $sformatf(
        "seq=%0d SPI frame started_at=%0t preceded AR accepted at %0t",
        ctx.accept_seq, tr.started_at, ctx.ar_accept_time))
      total_spi_mismatches++;
      return;
    end

    is_char_mode      = (ctx.characterize_unaligned && ctx.is_unaligned);
    ctx.spi_checked   = 1'b1;
    ctx.spi_completed = 1'b1;
    remove_ctx_from_awaiting_spi(ctx);

    if (is_char_mode && !ctx.axi_retired) begin
      if (tr.byte_completed_at.size() >= 4 && tr.byte_completed_at[3] > 0)
        ctx.spi_completed_at = tr.byte_completed_at[3];
      else if (tr.data_completed_at > 0)
        ctx.spi_completed_at = tr.data_completed_at;
      else
        ctx.spi_completed_at = (tr.completed_at > 0) ? tr.completed_at : $time;
      if (!$cast(tr_copy, tr.clone()))
        `uvm_fatal("XIP_SPI_CLONE", "Failed to clone characterization SPI transaction")
      ctx.deferred_spi_tr         = tr_copy;
      ctx.spi_validation_deferred = 1'b1;
      return;
    end

    finalize_xip_spi_frame(ctx, tr, ctx.is_expect_slverr());
  endfunction

  // -------------------------------------------------------------------------
  // End-of-Test Conservation & Integrity Checks
  // -------------------------------------------------------------------------
  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    flush_edge_batches();

    if (total_ar_accepted != (total_r_completed + total_reset_aborts + in_flight_ar_q.size())) begin
      `uvm_error("XIP_CONSERVATION_FAIL", $sformatf(
        "Conservation violated: ar_accepted(%0d) != r_completed(%0d) + reset_aborts(%0d) + pending_ar(%0d)",
        total_ar_accepted, total_r_completed, total_reset_aborts, in_flight_ar_q.size()))
    end

    if (in_flight_ar_q.size() != 0) begin
      `uvm_error("XIP_HANGING_AR", $sformatf(
        "End of test with %0d unretired AR request(s) (head seq=%0d addr=0x%08h)",
        in_flight_ar_q.size(), in_flight_ar_q[0].accept_seq, in_flight_ar_q[0].araddr))
    end

    if (pending_spi_q.size() != 0 || spi_frame_active) begin
      `uvm_error("XIP_HANGING_SPI", $sformatf(
        "End of test with %0d pending SPI expectation(s) (spi_frame_active=%0b)",
        pending_spi_q.size(), spi_frame_active))
    end

    foreach (retired_awaiting_spi_q[i]) begin
      qspi_xip_ctx early_ctx = retired_awaiting_spi_q[i];
      `uvm_error("XIP_R_BEFORE_SPI", $sformatf(
        "seq=%0d addr=0x%08h asserted RVALID at %0t without completed SPI by end of test",
        early_ctx.accept_seq, early_ctx.araddr, early_ctx.r_first_valid_at))
      total_r_mismatches++;
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("XIP_SB_SUMMARY", $sformatf(
      "XIP SB Summary: AR=%0d(wait>0:%0d,disAtt=%0d,disCyc=%0d,disMax=%0d) R_done=%0d R_ok=%0d(data=%0d,slv=%0d,char=%0d,stall=%0d,maxStall=%0d,disSeen=%0d) R_err=%0d RstAbort=%0d SLVERR=%0d | SPI_ok=%0d(ok=%0d,slv=%0d) SPI_err=%0d SPI_rst=%0d NonXIP=%0d | MaxOS=%0d MaxLat(1st/tot)=%0d/%0d | ConcAPB=%0d(ID=%0d,ST=%0d,FIFO=%0d,IE=%0d) IsolErr=%0d",
      total_ar_accepted, total_ar_wait_nonzero,
      total_disabled_ar_attempts, total_disabled_ar_cycles, max_disabled_ar_window,
      total_r_completed, total_r_matched, total_r_data_matched, total_r_slverr_matched,
      total_r_char_matched, total_r_post_valid_stall_completed, max_r_stall_observed, total_disable_seen,
      total_r_mismatches, total_reset_aborts, total_slverr_observed,
      total_spi_matched, total_spi_ok_matched, total_spi_slverr_matched,
      total_spi_mismatches, total_spi_reset_aborts, total_non_xip_spi_frames,
      max_outstanding_observed, max_first_r_latency, max_total_r_latency,
      concurrent_apb_count, conc_rd_id_count, conc_rd_status_count,
      conc_rd_fifo_stat_count, conc_wr_int_en_count, isolation_violations), UVM_LOW)
  endfunction

endclass : qspi_xip_sb

`endif // QSPI_XIP_SB_SV
