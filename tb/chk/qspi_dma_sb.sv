// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_dma_sb.sv
// Role   : End-to-End Scoreboard for DMA Mode (Group 4 - Checkpoint 2)
// Spec   : VNCHIP_QSPI_Controller_Specification_Rev1.1 & Clarifications 1-5.5
// =============================================================================

`ifndef QSPI_DMA_SB_SV
`define QSPI_DMA_SB_SV

`uvm_analysis_imp_decl(_dma_apb)
`uvm_analysis_imp_decl(_dma_axi)
`uvm_analysis_imp_decl(_dma_axi_resp)
`uvm_analysis_imp_decl(_dma_spi)

class qspi_dma_sb extends uvm_scoreboard;
  `uvm_component_utils(qspi_dma_sb)

  qspi_env_cfg cfg;

  uvm_analysis_imp_dma_apb      #(qspi_apb_item_t,       qspi_dma_sb) apb_export;
  uvm_analysis_imp_dma_axi      #(axi_slave_transaction, qspi_dma_sb) axi_export;
  uvm_analysis_imp_dma_axi_resp #(axi_slave_resp_event,  qspi_dma_sb) axi_resp_export;
  uvm_analysis_imp_dma_spi      #(qspi_transaction,      qspi_dma_sb) spi_export;

  // Shared spec-compliant passive CSR shadow instance
  qspi_csr_shadow csr;
  bit             last_was_dma_cmd;

  // Active DMA transfer context
  bit        dma_active;
  bit        active_unsupported_cfg;
  bit [31:0] active_dma_addr;
  bit [31:0] active_dma_len;
  bit [31:0] active_cmd_len;
  bit        active_dma_dir;      // 0: TX (RAM->QSPI), 1: RX (QSPI->RAM)
  bit        active_cmd_dir;
  bit        active_incr_addr;
  bit        active_quad_en;
  bit [7:0]  active_opcode;
  bit [7:0]  active_mode_bits;
  bit [31:0] active_cmd_addr;
  bit [31:0] active_cmd_cfg;
  bit [7:0]  active_extra_dummy;
  bit [1:0]  active_cs_delay;

  // Lifecycle & interrupt/error state (decoupled from W1C clears)
  bit        saw_axi_error;
  bit        saw_axi_err_txn;
  bit        saw_dma_done_event;
  bit        saw_cmd_done_event;
  bit        saw_err_event;
  bit        err_reported_for_transfer;
  bit        dma_pending_irq_check;
  bit        dma_in_error_drain;
  bit        in_post_err_quiescence;
  bit        dma_trailing_spi_pending;
  bit        err_spi_checked;
  time       axi_err_obs_at;
  time       err_observed_at;
  time       dma_started_at;
  time       last_non_dma_trigger_at;

  // Per-cycle deterministic ordering batches
  qspi_apb_item_t       apb_wr_batch_q[$];
  qspi_apb_item_t       apb_rd_batch_q[$];
  axi_slave_resp_event  axi_resp_batch_q[$];
  axi_slave_transaction axi_batch_q[$];
  qspi_transaction      spi_batch_q[$];

  // Captured transactions during active DMA
  axi_slave_transaction captured_axi_tx[$];
  axi_slave_transaction captured_axi_rx[$];
  qspi_transaction      captured_spi[$];

  // Independent physical-bus FIFO occupancy, fault & active-AXI observation
  // (derived strictly from observed SPI/AXI handshakes; never trusts DUT ERR_STAT or test knobs)
  bit [2:0]    active_clk_div         = 3'd0;
  bit          active_cpol            = 1'b0;
  bit          active_cpha            = 1'b0;
  int unsigned active_hdr_sclk_edges  = 0;
  int unsigned active_edges_per_byte  = 8;
  int unsigned dma_spi_sclk_edges     = 0;
  int unsigned axi_rx_drained_bytes   = 0;
  int unsigned axi_tx_fetched_bytes   = 0;
  bit          saw_axi_active_in_xfer = 1'b0;
  bit          saw_rx_overrun_stall   = 1'b0;
  bit          saw_tx_underrun_stall  = 1'b0;
  bit          saw_sclk_timeout_stall = 1'b0;
  int unsigned axi_ar_pending         = 0;
  int unsigned rx_axi_stall_cycles    = 0;
  int unsigned tx_axi_starve_cycles   = 0;

  // Statistics
  int unsigned tx_dma_starts        = 0;
  int unsigned rx_dma_starts        = 0;
  int unsigned dma_completions      = 0;
  int unsigned dma_errors           = 0;
  int unsigned dma_reset_aborts     = 0;
  int unsigned dma_axi_reset_aborts = 0;
  int unsigned mismatch_count       = 0;

  function new(string name = "qspi_dma_sb", uvm_component parent = null);
    super.new(name, parent);
    apb_export      = new("apb_export", this);
    axi_export      = new("axi_export", this);
    axi_resp_export = new("axi_resp_export", this);
    spi_export      = new("spi_export", this);
    csr             = qspi_csr_shadow::type_id::create("dma_sb_csr");
    reset_model();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null || cfg.clk_vif == null)
      `uvm_fatal("QSPI_DMA_CFG", "qspi_dma_sb requires non-null cfg and cfg.clk_vif")
  endfunction

  function void record_mismatch(string tag, string msg);
    `uvm_error(tag, msg)
    mismatch_count++;
  endfunction

  function void reset_model();
    if (csr != null)
      csr.reset();
    last_was_dma_cmd          = 1'b0;
    dma_active                = 1'b0;
    active_clk_div            = 3'd0;
    active_cpol               = 1'b0;
    active_cpha               = 1'b0;
    active_hdr_sclk_edges     = 0;
    active_edges_per_byte     = 8;
    dma_spi_sclk_edges        = 0;
    axi_rx_drained_bytes      = 0;
    axi_tx_fetched_bytes      = 0;
    saw_axi_active_in_xfer    = 1'b0;
    saw_rx_overrun_stall      = 1'b0;
    saw_tx_underrun_stall     = 1'b0;
    saw_sclk_timeout_stall    = 1'b0;
    axi_ar_pending            = 0;
    rx_axi_stall_cycles       = 0;
    tx_axi_starve_cycles      = 0;
    active_unsupported_cfg    = 1'b0;
    active_dma_addr           = 32'h0;
    active_dma_len            = 32'h0;
    active_cmd_len            = 32'h0;
    active_dma_dir            = 1'b0;
    active_cmd_dir            = 1'b0;
    active_incr_addr          = 1'b0;
    active_quad_en            = 1'b0;
    active_opcode             = 8'h0;
    active_mode_bits          = 8'h0;
    active_cmd_addr           = 32'h0;
    active_cmd_cfg            = 32'h0;
    active_extra_dummy        = 8'h0;
    active_cs_delay           = 2'b0;
    saw_axi_error             = 1'b0;
    saw_axi_err_txn           = 1'b0;
    saw_dma_done_event        = 1'b0;
    saw_cmd_done_event        = 1'b0;
    saw_err_event             = 1'b0;
    err_reported_for_transfer = 1'b0;
    dma_pending_irq_check     = 1'b0;
    dma_in_error_drain        = 1'b0;
    in_post_err_quiescence    = 1'b0;
    dma_trailing_spi_pending  = 1'b0;
    err_spi_checked           = 1'b0;
    axi_err_obs_at            = 0;
    err_observed_at           = 0;
    dma_started_at            = 0;
    last_non_dma_trigger_at   = 0;
    apb_wr_batch_q.delete();
    apb_rd_batch_q.delete();
    axi_resp_batch_q.delete();
    axi_batch_q.delete();
    spi_batch_q.delete();
    captured_axi_tx.delete();
    captured_axi_rx.delete();
    captured_spi.delete();
  endfunction

  function void flush_batches();
    while (apb_wr_batch_q.size() > 0)
      process_apb(apb_wr_batch_q.pop_front());
    while (axi_resp_batch_q.size() > 0)
      process_axi_resp(axi_resp_batch_q.pop_front());
    while (axi_batch_q.size() > 0)
      process_axi(axi_batch_q.pop_front());
    while (spi_batch_q.size() > 0)
      process_spi(spi_batch_q.pop_front());
    while (apb_rd_batch_q.size() > 0)
      process_apb(apb_rd_batch_q.pop_front());
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg == null || cfg.clk_vif == null)
      `uvm_fatal("QSPI_DMA_CFG", "Missing qspi_env_cfg or clk_vif in run_phase")
    reset_model();
    fork
      forever begin
        @(negedge cfg.clk_vif.rst_n);
        if (dma_active || dma_in_error_drain)
          dma_reset_aborts++;
        if (dma_active && (saw_axi_active_in_xfer || captured_axi_tx.size() > 0 || captured_axi_rx.size() > 0))
          dma_axi_reset_aborts++;
        reset_model();
      end
      forever begin
        if (cfg.flash_vif == null) begin
          @(posedge cfg.clk_vif.clk);
          continue;
        end
        @(posedge cfg.flash_vif.qspi_sclk or negedge cfg.flash_vif.qspi_sclk);
        if (cfg.clk_vif.rst_n === 1'b1 && dma_active && cfg.flash_vif.qspi_cs_n === 1'b0) begin
          bit sample_on_high;
          sample_on_high = (active_cpol == active_cpha);
          if ((sample_on_high && cfg.flash_vif.qspi_sclk === 1'b1) ||
              (!sample_on_high && cfg.flash_vif.qspi_sclk === 1'b0))
            dma_spi_sclk_edges++;
        end
      end
      forever begin
        int unsigned spi_data_bytes, spi_data_bytes_started, sclk_to_thresh;
        @(posedge cfg.clk_vif.clk);
        if (cfg.clk_vif.rst_n === 1'b1 && dma_active && cfg.axi_vif != null) begin
          if (cfg.axi_vif.m_awvalid === 1'b1 || cfg.axi_vif.m_wvalid === 1'b1 ||
              cfg.axi_vif.m_arvalid === 1'b1 || cfg.axi_vif.m_rvalid === 1'b1 ||
              cfg.axi_vif.m_bvalid  === 1'b1)
            saw_axi_active_in_xfer = 1'b1;

          if (cfg.axi_vif.m_arvalid === 1'b1 && cfg.axi_vif.m_arready === 1'b1)
            axi_ar_pending++;
          if (cfg.axi_vif.m_rvalid === 1'b1 && cfg.axi_vif.m_rready === 1'b1) begin
            axi_tx_fetched_bytes += 4;
            if (cfg.axi_vif.m_rlast === 1'b1 && axi_ar_pending > 0)
              axi_ar_pending--;
          end
          if (cfg.axi_vif.m_wvalid === 1'b1 && cfg.axi_vif.m_wready === 1'b1)
            axi_rx_drained_bytes += 4;

          spi_data_bytes = (dma_spi_sclk_edges > active_hdr_sclk_edges && active_edges_per_byte > 0) ?
                           ((dma_spi_sclk_edges - active_hdr_sclk_edges) / active_edges_per_byte) : 0;
          if (spi_data_bytes > active_dma_len)
            spi_data_bytes = active_dma_len;
          spi_data_bytes_started = (dma_spi_sclk_edges > active_hdr_sclk_edges && active_edges_per_byte > 0) ?
                                   ((dma_spi_sclk_edges - active_hdr_sclk_edges + active_edges_per_byte - 1) / active_edges_per_byte) : 0;
          if (spi_data_bytes_started > active_dma_len)
            spi_data_bytes_started = active_dma_len;
          sclk_to_thresh = 2000 * (1 << active_clk_div);

          if (active_dma_dir) begin
            // RX FIFO overrun requires transfer > 16B capacity AND SPI starting/producing beyond AXI drain + 16B
            if (active_dma_len > 16 && spi_data_bytes_started > (axi_rx_drained_bytes + 16))
              saw_rx_overrun_stall = 1'b1;
            if (cfg.axi_vif.m_wvalid === 1'b1 && cfg.axi_vif.m_wready === 1'b1) begin
              rx_axi_stall_cycles = 0;
            end else if ((cfg.axi_vif.m_wvalid === 1'b1 && cfg.axi_vif.m_wready === 1'b0) ||
                         (cfg.axi_vif.m_awvalid === 1'b1 && cfg.axi_vif.m_awready === 1'b0)) begin
              rx_axi_stall_cycles++;
              if (rx_axi_stall_cycles >= sclk_to_thresh)
                saw_sclk_timeout_stall = 1'b1;
            end
          end else begin
            // TX FIFO underrun requires SPI at/past header with TX FIFO empty (fetched <= consumed) while more TX bytes remain & AXI read is stalled
            if (cfg.axi_vif.m_rvalid === 1'b1 && cfg.axi_vif.m_rready === 1'b1) begin
              tx_axi_starve_cycles = 0;
            end else if ((cfg.flash_vif != null && cfg.flash_vif.qspi_cs_n === 1'b0) &&
                         ((axi_ar_pending > 0 && cfg.axi_vif.m_rvalid === 1'b0) ||
                          (cfg.axi_vif.m_arvalid === 1'b1 && cfg.axi_vif.m_arready === 1'b0))) begin
              tx_axi_starve_cycles++;
              if (dma_spi_sclk_edges >= active_hdr_sclk_edges &&
                  axi_tx_fetched_bytes < active_dma_len &&
                  spi_data_bytes >= axi_tx_fetched_bytes)
                saw_tx_underrun_stall = 1'b1;
              if (tx_axi_starve_cycles >= sclk_to_thresh)
                saw_sclk_timeout_stall = 1'b1;
            end
          end
        end
        #1ps;
        if (cfg.clk_vif.rst_n === 1'b1)
          flush_batches();
      end
    join
  endtask

  virtual function void write_dma_apb(qspi_apb_item_t tr);
    if (tr == null || tr.reset_abort || tr.slverr !== 1'b0) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;
    if ($isunknown(tr.write)) begin
      record_mismatch("QSPI_DMA_APB_XZ", "APB write control signal is X/Z");
      return;
    end
    if (tr.write) apb_wr_batch_q.push_back(tr);
    else          apb_rd_batch_q.push_back(tr);
  endfunction

  virtual function void write_dma_axi_resp(axi_slave_resp_event ev);
    if (ev == null) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;
    // Flag saw_axi_error immediately if active or post-trigger so APB polls cannot miss it.
    if ((dma_active || dma_in_error_drain) && !$isunknown(ev.resp) && ev.resp !== 2'b00) begin
      saw_axi_error = 1'b1;
      if (axi_err_obs_at == 0) axi_err_obs_at = ev.obs_time;
    end
    axi_resp_batch_q.push_back(ev);
  endfunction

  virtual function void write_dma_axi(axi_slave_transaction tr);
    if (tr == null) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;
    axi_batch_q.push_back(tr);
  endfunction

  virtual function void write_dma_spi(qspi_transaction tr);
    if (tr == null) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;
    spi_batch_q.push_back(tr);
  endfunction

  protected function void process_axi_resp(axi_slave_resp_event ev);
    if (ev == null) return;
    if (!dma_active && !dma_in_error_drain && !in_post_err_quiescence) return;
    if ($isunknown(ev.resp)) begin
      record_mismatch("QSPI_DMA_AXI_RESP_XZ", $sformatf(
        "AXI %s beat %0d returned X/Z response (%02b)",
        ev.is_write ? "BRESP" : "RRESP", ev.beat_idx, ev.resp));
      return;
    end
    if (ev.resp === 2'b01) begin
      record_mismatch("QSPI_DMA_AXI_EXOKAY", $sformatf(
        "Unsupported AXI %s EXOKAY (2'b01) response on beat %0d",
        ev.is_write ? "BRESP" : "RRESP", ev.beat_idx));
      return;
    end
    if (ev.resp === 2'b10 || ev.resp === 2'b11) begin
      saw_axi_error = 1'b1;
      if (axi_err_obs_at == 0) axi_err_obs_at = ev.obs_time;
    end
  endfunction

  protected function void process_apb(qspi_apb_item_t tr);
    bit triggered;
    if (tr == null || tr.reset_abort || tr.slverr !== 1'b0) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;

    if (tr.write) begin
      for (int lane = 0; lane < 4; lane++) begin
        if (tr.strb[lane] && $isunknown(tr.wdata[lane*8 +: 8])) begin
          record_mismatch("QSPI_DMA_APB_WDATA_XZ", $sformatf(
            "APB write addr=0x%03h byte %0d contains X/Z", tr.addr, lane));
          return;
        end
      end
      triggered = csr.apply_apb_write(tr);
      if (tr.addr == QSPI_REG_CTRL) begin
        if (triggered && (tr.strb[1] === 1'b1) && (tr.wdata[9] === 1'b1)) begin
          last_was_dma_cmd = 1'b1;
          start_dma_transfer();
        end else if (triggered) begin
          last_was_dma_cmd = 1'b0;
          if (last_non_dma_trigger_at == 0)
            last_non_dma_trigger_at = (tr.completed_at > 0) ? tr.completed_at : $time;
        end else if (csr.ctrl[1]) begin
          last_was_dma_cmd = 1'b0;
          if (last_non_dma_trigger_at == 0)
            last_non_dma_trigger_at = (tr.completed_at > 0) ? tr.completed_at : $time;
        end
      end
    end else begin
      if (tr.addr == QSPI_REG_INT_STAT && (dma_active || dma_pending_irq_check || dma_in_error_drain)) begin
        if ($isunknown(tr.rdata[2:0])) begin
          record_mismatch("QSPI_DMA_INT_STAT_XZ", $sformatf(
            "APB read of INT_STAT returned unknown bits (X/Z): 0x%08h", tr.rdata));
          return;
        end

        if (tr.rdata[1] === 1'b1) saw_dma_done_event = 1'b1;
        if (tr.rdata[0] === 1'b1) saw_cmd_done_event = 1'b1;

        if (tr.rdata[2] === 1'b1) begin
          bit is_expected;
          // Independent physical-bus fault contract (never trusts DUT ERR_STAT or test knobs)
          is_expected = saw_axi_error || saw_rx_overrun_stall || saw_tx_underrun_stall || saw_sclk_timeout_stall;
          saw_err_event = 1'b1;
          if (!err_reported_for_transfer) begin
            dma_errors++;
            err_reported_for_transfer = 1'b1;
            `uvm_info("QSPI_DMA_SB", "DMA status observed INT_STAT.ERR=1", UVM_LOW)
          end
          if (!is_expected) begin
            record_mismatch("QSPI_DMA_UNEXPECTED_ERR", $sformatf(
              "INT_STAT.ERR asserted (0x%08h) without independent physical-bus fault evidence (axi_err=%0b rx_ovf=%0b tx_udf=%0b to=%0b)",
              tr.rdata, saw_axi_error, saw_rx_overrun_stall, saw_tx_underrun_stall, saw_sclk_timeout_stall));
          end
          dma_pending_irq_check    = 1'b0;
          dma_active               = 1'b0;
          dma_in_error_drain       = 1'b1;
          in_post_err_quiescence   = 1'b1;
          dma_trailing_spi_pending = (captured_spi.size() == 0);
          err_observed_at          = (tr.completed_at > 0) ? tr.completed_at : $time;
          if (captured_spi.size() > 0 && !err_spi_checked)
            check_error_dma_transfer(captured_spi[0]);
        end else if (saw_axi_error && !saw_err_event &&
                     (tr.rdata[1] === 1'b1 || tr.rdata[0] === 1'b1)) begin
          if (!err_reported_for_transfer) begin
            record_mismatch("QSPI_DMA_ERR_MISS",
              "AXI error response (SLVERR/DECERR) occurred during DMA, but INT_STAT.ERR was not latched!");
            dma_errors++;
            err_reported_for_transfer = 1'b1;
          end
          dma_active               = 1'b0;
          dma_pending_irq_check    = 1'b0;
          dma_in_error_drain       = 1'b1;
          in_post_err_quiescence   = 1'b1;
          dma_trailing_spi_pending = (captured_spi.size() == 0);
          err_observed_at          = (tr.completed_at > 0) ? tr.completed_at : $time;
          if (captured_spi.size() > 0 && !err_spi_checked)
            check_error_dma_transfer(captured_spi[0]);
        end else if (!saw_axi_error) begin
          if (tr.rdata[0] === 1'b1 && !saw_dma_done_event) begin
            record_mismatch("QSPI_DMA_CMD_DONE_EARLY",
              "CMD_DONE (INT_STAT[0]) asserted before DMA_DONE (INT_STAT[1]) in DMA mode (violates Spec 5.3)");
          end else if (tr.rdata[0] === 1'b1 && dma_active && !active_unsupported_cfg &&
                       !is_bus_transfer_complete()) begin
            record_mismatch("QSPI_DMA_DONE_PREMATURE",
              "INT_STAT reported CMD_DONE before bus transfer completed on AXI/SPI (violates Spec 5.3)");
          end else if (saw_dma_done_event && saw_cmd_done_event) begin
            if (dma_active)
              complete_dma_transfer();
            dma_pending_irq_check = 1'b0;
          end
        end
      end
    end
  endfunction

  protected function bit check_axi_burst_common(axi_slave_transaction tr, int idx);
    bit ok = 1'b1;
    longint unsigned burst_start = 64'(tr.addr);
    longint unsigned byte_span   = 64'(tr.data.size()) << 2;
    longint unsigned burst_end   = (byte_span > 0) ? (burst_start + byte_span - 64'd1) : burst_start;
    int unsigned exp_beats       = int'(tr.len) + 1;

    if ($isunknown(tr.addr) || $isunknown(tr.size) || $isunknown(tr.burst) || $isunknown(tr.len)) begin
      record_mismatch("QSPI_DMA_AXI_CTRL_XZ", $sformatf(
        "%s burst[%0d] control fields contain X/Z (addr=0x%08h size=%03b burst=%02b len=0x%02h)",
        tr.is_write ? "RX" : "TX", idx, tr.addr, tr.size, tr.burst, tr.len));
      return 1'b0;
    end
    if (tr.size !== 3'b010 || tr.burst !== 2'b01) begin
      record_mismatch("QSPI_DMA_AXI_ATTR", $sformatf(
        "%s burst[%0d] invalid AXI attributes: size=%0d (exp 2), burst=%0b (exp 01 INCR)",
        tr.is_write ? "RX" : "TX", idx, tr.size, tr.burst));
      ok = 1'b0;
    end
    if ((burst_start & 64'hFFFF_F000) !== (burst_end & 64'hFFFF_F000)) begin
      record_mismatch("QSPI_DMA_4KB", $sformatf(
        "%s burst[%0d] crossed 4KB boundary: start=0x%08h, end=0x%08h",
        tr.is_write ? "RX" : "TX", idx, burst_start[31:0], burst_end[31:0]));
      ok = 1'b0;
    end
    if (tr.is_write) begin
      if ($isunknown(tr.bresp)) begin
        record_mismatch("QSPI_DMA_AXI_BRESP_XZ", $sformatf("RX burst[%0d] BRESP is X/Z", idx));
        ok = 1'b0;
      end
      if (!tr.wlast_seen || tr.data.size() != exp_beats || tr.wstrb.size() != exp_beats) begin
        record_mismatch("QSPI_DMA_AXI_WLAST", $sformatf(
          "RX burst[%0d] LEN/WLAST mismatch: awlen=%0d exp_beats=%0d data=%0d wstrb=%0d wlast_seen=%0b",
          idx, tr.len, exp_beats, tr.data.size(), tr.wstrb.size(), tr.wlast_seen));
        ok = 1'b0;
      end
      foreach (tr.wstrb[beat]) begin
        if ($isunknown(tr.wstrb[beat])) begin
          record_mismatch("QSPI_DMA_WSTRB_XZ", $sformatf(
            "RX burst[%0d] beat[%0d] WSTRB has X/Z: %04b", idx, beat, tr.wstrb[beat]));
          ok = 1'b0;
        end
      end
    end else begin
      bit has_r_err = 1'b0;
      foreach (tr.rresp[beat]) begin
        if ($isunknown(tr.rresp[beat])) begin
          record_mismatch("QSPI_DMA_AXI_RRESP_XZ", $sformatf(
            "TX burst[%0d] beat[%0d] RRESP is X/Z", idx, beat));
          ok = 1'b0;
        end else if (tr.rresp[beat] != 2'b00) begin
          has_r_err = 1'b1;
        end
      end
      if (!has_r_err && (!tr.rlast_seen || tr.data.size() != exp_beats)) begin
        record_mismatch("QSPI_DMA_AXI_RLAST", $sformatf(
          "TX burst[%0d] LEN/RLAST mismatch: arlen=%0d exp_beats=%0d data=%0d rlast_seen=%0b",
          idx, tr.len, exp_beats, tr.data.size(), tr.rlast_seen));
        ok = 1'b0;
      end
    end
    return ok;
  endfunction

  protected function void process_axi(axi_slave_transaction tr);
    bit is_err_resp = 1'b0;
    bit is_wrong_dir = 1'b0;
    bit prior_saw_axi_error;
    time eff_err_at;
    if (tr == null) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;

    prior_saw_axi_error = saw_axi_err_txn;

    if (tr.is_write) begin
      if ($isunknown(tr.bresp) || tr.bresp != 2'b00) is_err_resp = 1'b1;
    end else begin
      foreach (tr.rresp[i]) begin
        if ($isunknown(tr.rresp[i]) || tr.rresp[i] != 2'b00) is_err_resp = 1'b1;
      end
    end

    if (is_err_resp) begin
      saw_axi_error   = 1'b1;
      saw_axi_err_txn = 1'b1;
      if (axi_err_obs_at == 0)
        axi_err_obs_at = (tr.completed_at > 0) ? tr.completed_at : $time;
    end

    if (dma_active || dma_in_error_drain || in_post_err_quiescence) begin
      if (active_dma_dir == 1'b0 && tr.is_write)  is_wrong_dir = 1'b1;
      if (active_dma_dir == 1'b1 && !tr.is_write) is_wrong_dir = 1'b1;
      if (is_wrong_dir) begin
        record_mismatch("QSPI_DMA_AXI_WRONG_DIR", $sformatf(
          "DUT issued AXI %s transaction (addr=0x%08h) during %s DMA (violates transfer direction)",
          tr.is_write ? "WRITE" : "READ", tr.addr, active_dma_dir ? "RX" : "TX"));
        return;
      end
    end

    eff_err_at = (axi_err_obs_at > 0) ? axi_err_obs_at : err_observed_at;
    if (prior_saw_axi_error ||
        (err_observed_at > 0 && tr.started_at > err_observed_at) ||
        (axi_err_obs_at  > 0 && tr.started_at > axi_err_obs_at)) begin
      record_mismatch("QSPI_DMA_ERR_CONT", $sformatf(
        "DUT issued a new AXI %s transaction (addr=0x%08h, started_at=%0t) after error observed (prior_err_txn=%0b, axi_err_at=%0t, apb_err_at=%0t) (violates Spec 5.4)",
        tr.is_write ? "WRITE" : "READ", tr.addr, tr.started_at, prior_saw_axi_error, axi_err_obs_at, err_observed_at));
      return;
    end

    if (!dma_active) begin
      if ((dma_in_error_drain || in_post_err_quiescence) && eff_err_at > 0 &&
          tr.started_at >= dma_started_at && tr.started_at <= eff_err_at) begin
        void'(check_axi_burst_common(tr, tr.is_write ? captured_axi_rx.size() : captured_axi_tx.size()));
        if (tr.is_write) captured_axi_rx.push_back(tr);
        else             captured_axi_tx.push_back(tr);
        return;
      end

      record_mismatch("QSPI_DMA_AXI_SPURIOUS", $sformatf(
        "DUT issued unexpected AXI %s transaction (addr=0x%08h, started_at=%0t) while DMA is not active",
        tr.is_write ? "WRITE" : "READ", tr.addr, tr.started_at));
      return;
    end

    if (tr.is_write) captured_axi_rx.push_back(tr);
    else             captured_axi_tx.push_back(tr);

    if (dma_active && !saw_axi_error && !active_unsupported_cfg && is_bus_transfer_complete()) begin
      complete_dma_transfer();
    end
  endfunction

  protected function void process_spi(qspi_transaction tr);
    if (tr == null) return;
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n !== 1'b1) return;

    if (!dma_active) begin
      if (dma_trailing_spi_pending) begin
        int unsigned a_bytes = (active_cmd_cfg[7:6] == 2'b01) ? 3 : (active_cmd_cfg[7:6] == 2'b10) ? 4 : 0;
        bit addr_match = (a_bytes == 0) ||
                         (a_bytes == 3 && tr.addr[23:0] === active_cmd_addr[23:0]) ||
                         (a_bytes == 4 && tr.addr[31:0] === active_cmd_addr[31:0]);
        bit is_our_trailing = (tr.opcode === active_opcode) &&
                              addr_match &&
                              (tr.started_at >= dma_started_at) &&
                              (last_non_dma_trigger_at == 0 || tr.started_at < last_non_dma_trigger_at);
        dma_trailing_spi_pending = 1'b0;
        dma_in_error_drain       = 1'b0;
        if (is_our_trailing) begin
          captured_spi.push_back(tr);
          check_error_dma_transfer(tr);
          `uvm_info("QSPI_DMA_SB", "Absorbed & checked trailing SPI frame for errored DMA transfer", UVM_HIGH)
          return;
        end
      end
      if (csr.ctrl[1] || !last_was_dma_cmd)
        return;

      record_mismatch("QSPI_DMA_SPI_SPURIOUS", $sformatf(
        "DUT issued unexpected SPI frame (op=0x%02h, addr=0x%08h, len=%0d) while DMA is not active",
        tr.opcode, tr.addr, tr.data.size()));
      return;
    end

    if (captured_spi.size() > 0) begin
      record_mismatch("QSPI_DMA_SPI_MULTI_FRAME", $sformatf(
        "DUT issued multiple SPI frames (captured=%0d) for a single DMA transfer trigger",
        captured_spi.size() + 1));
      return;
    end

    captured_spi.push_back(tr);
    if (dma_in_error_drain) begin
      dma_active         = 1'b0;
      dma_in_error_drain = 1'b0;
      check_error_dma_transfer(tr);
      return;
    end
    if (!saw_axi_error && !active_unsupported_cfg && is_bus_transfer_complete()) begin
      complete_dma_transfer();
    end
  endfunction

  protected function bit is_bus_transfer_complete();
    longint unsigned axi_bytes_count = 0;
    if (!dma_active || active_dma_len == 0) return 1'b0;

    if (active_dma_dir) begin
      if (captured_spi.size() == 0) return 1'b0;
      foreach (captured_axi_rx[b]) begin
        for (int beat = 0; beat < captured_axi_rx[b].data.size(); beat++) begin
          for (int lane = 0; lane < 4; lane++) begin
            if (captured_axi_rx[b].wstrb[beat][lane]) axi_bytes_count++;
          end
        end
      end
      return (axi_bytes_count >= 64'(active_dma_len) &&
              64'(captured_spi[0].data.size()) >= 64'(active_dma_len));
    end else begin
      if (captured_spi.size() == 0) return 1'b0;
      foreach (captured_axi_tx[b]) begin
        axi_bytes_count += (64'(captured_axi_tx[b].data.size()) * 64'd4);
      end
      return (axi_bytes_count >= 64'(active_dma_len) &&
              64'(captured_spi[0].data.size()) >= 64'(active_dma_len));
    end
  endfunction

  protected function void start_dma_transfer();
    qspi_cmd_profile_t cp;
    bit [31:0]         cfg_w;
    int unsigned       l_cmd, l_addr, l_data;
    int                ab;
    cp    = csr.get_cmd_snapshot();
    cfg_w = cp.cmd_cfg;

    if (dma_active) begin
      record_mismatch("QSPI_DMA_OVERWRITE", $sformatf(
        "New DMA trigger issued while prior DMA transfer (dir=%s, addr=0x%08h, len=%0d) is still active and unretired!",
        active_dma_dir ? "RX" : "TX", active_dma_addr, active_dma_len));
    end
    if (dma_pending_irq_check) begin
      record_mismatch("QSPI_DMA_IRQ_UNCHECKED",
        "New DMA transfer started before previous transfer interrupt status (INT_STAT) was verified");
    end
    dma_pending_irq_check = 1'b0;

    if (cfg_w[1:0] == 2'b11 || cfg_w[3:2] == 2'b11 || cfg_w[5:4] == 2'b11 || cfg_w[7:6] == 2'b11) begin
      record_mismatch("QSPI_DMA_SPEC_INPUT", $sformatf(
        "Reserved CMD_CFG/LUT_CFG encoding (0x%08h) has no specified DMA transaction", cfg_w));
    end

    dma_active                = 1'b1;
    active_clk_div            = cp.clk_div;
    active_cpol               = cp.cpol;
    active_cpha               = cp.cpha;
    l_cmd                     = qspi_eff_lanes(cp.cmd_lanes_enc,  cp.quad_en);
    l_addr                    = qspi_eff_lanes(cp.addr_lanes_enc, cp.quad_en);
    l_data                    = qspi_eff_lanes(cp.data_lanes_enc, cp.quad_en);
    ab                        = qspi_enc_to_addr_bytes(cp.addr_bytes_enc);
    active_hdr_sclk_edges     = (8 / l_cmd) + ((ab > 0 ? ab * 8 : 0) / l_addr) +
                                (cp.mode_en ? (8 / l_addr) : 0) +
                                int'(cp.dummy_cycles) + int'(cp.extra_dummy);
    active_edges_per_byte     = 8 / l_data;
    dma_spi_sclk_edges        = 0;
    axi_rx_drained_bytes      = 0;
    axi_tx_fetched_bytes      = 0;
    saw_axi_active_in_xfer    = 1'b0;
    saw_rx_overrun_stall      = 1'b0;
    saw_tx_underrun_stall     = 1'b0;
    saw_sclk_timeout_stall    = 1'b0;
    axi_ar_pending            = 0;
    rx_axi_stall_cycles       = 0;
    tx_axi_starve_cycles      = 0;
    active_dma_addr           = cp.dma_addr;
    active_dma_len            = cp.dma_len;
    active_cmd_len            = cp.cmd_len;
    active_dma_dir            = cp.dma_dir;
    active_incr_addr          = cp.dma_incr_addr;
    active_quad_en            = cp.quad_en;
    active_cmd_dir            = cp.dir;
    active_opcode             = cp.opcode;
    active_mode_bits          = cp.mode_bits;
    active_cmd_addr           = cp.cmd_addr;
    active_cmd_cfg            = cp.cmd_cfg;
    active_extra_dummy        = cp.extra_dummy;
    active_cs_delay           = cp.cs_delay;
    active_unsupported_cfg    = (active_dma_len == 0 || active_dma_len != active_cmd_len ||
                                 active_dma_dir != active_cmd_dir || active_dma_addr[1:0] != 2'b00);
    saw_axi_error             = 1'b0;
    saw_axi_err_txn           = 1'b0;
    saw_dma_done_event        = 1'b0;
    saw_cmd_done_event        = 1'b0;
    saw_err_event             = 1'b0;
    err_reported_for_transfer = 1'b0;
    dma_in_error_drain        = 1'b0;
    in_post_err_quiescence    = 1'b0;
    dma_trailing_spi_pending  = 1'b0;
    err_spi_checked           = 1'b0;
    axi_err_obs_at            = 0;
    err_observed_at           = 0;
    dma_started_at            = $time;
    last_non_dma_trigger_at   = 0;
    captured_axi_tx.delete();
    captured_axi_rx.delete();
    captured_spi.delete();

    if (active_dma_dir == 1'b0) tx_dma_starts++;
    else                        rx_dma_starts++;

    if (active_unsupported_cfg) begin
      `uvm_info("QSPI_DMA_SB", $sformatf(
        "DMA START [OUT-OF-SCOPE per Clarif 5.2/5.5]: dir=%s, cmd_dir=%0b, addr=0x%08h, dma_len=%0d, cmd_len=%0d",
        active_dma_dir ? "RX" : "TX", active_cmd_dir, active_dma_addr, active_dma_len, active_cmd_len), UVM_LOW)
    end else begin
      `uvm_info("QSPI_DMA_SB", $sformatf(
        "DMA START: dir=%s, addr=0x%08h, dma_len=%0d, cmd_len=%0d, incr_addr=%0b, quad_en=%0b, op=0x%02h, cmd_addr=0x%08h",
        active_dma_dir ? "RX (QSPI->RAM)" : "TX (RAM->QSPI)",
        active_dma_addr, active_dma_len, active_cmd_len, active_incr_addr,
        active_quad_en, active_opcode, active_cmd_addr), UVM_LOW)
    end
  endfunction

  protected function void check_spi_header_and_edges(
    qspi_transaction spi_tr,
    bit              allow_partial,
    output int unsigned c_lanes,
    output int unsigned a_lanes,
    output int unsigned d_lanes,
    output longint unsigned exp_edges
  );
    int unsigned a_bytes;
    int unsigned dummy_c;
    int unsigned extra_d;
    int unsigned eff_dummy;
    bit          mode_en;
    a_bytes   = (active_cmd_cfg[7:6] == 2'b01) ? 3 : (active_cmd_cfg[7:6] == 2'b10) ? 4 : 0;
    dummy_c   = active_cmd_cfg[12:9];
    extra_d   = active_extra_dummy;
    eff_dummy = dummy_c + extra_d;
    mode_en   = active_cmd_cfg[8];

    c_lanes = qspi_eff_lanes(active_cmd_cfg[1:0], active_quad_en);
    a_lanes = qspi_eff_lanes(active_cmd_cfg[3:2], active_quad_en);
    d_lanes = qspi_eff_lanes(active_cmd_cfg[5:4], active_quad_en);
    if (c_lanes == 0) c_lanes = 1;
    if (a_lanes == 0) a_lanes = 1;
    if (d_lanes == 0) d_lanes = 1;

    exp_edges = 64'd8 / c_lanes +
                (64'd8 * 64'(a_bytes)) / a_lanes +
                (mode_en ? (64'd8 / a_lanes) : 64'd0) +
                64'(eff_dummy) +
                (64'd8 * 64'(active_dma_len)) / d_lanes;

    if (!allow_partial && spi_tr.aborted_early) begin
      record_mismatch("QSPI_DMA_SPI_ABORTED", $sformatf(
        "DMA SPI frame aborted early (end_phase=%0d) on normal transfer", spi_tr.end_phase));
    end

    if (!allow_partial || spi_tr.end_phase >= 1) begin
      if ($isunknown(spi_tr.opcode) || spi_tr.opcode !== active_opcode) begin
        record_mismatch("QSPI_DMA_SPI_OPCODE", $sformatf(
          "SPI opcode mismatch: exp=0x%02h, got=0x%02h", active_opcode, spi_tr.opcode));
      end
    end

    if (!allow_partial || spi_tr.end_phase >= 2) begin
      if (a_bytes == 3 && ($isunknown(spi_tr.addr[23:0]) || spi_tr.addr[23:0] !== active_cmd_addr[23:0])) begin
        record_mismatch("QSPI_DMA_SPI_ADDR", $sformatf(
          "SPI 3-byte address mismatch: exp=0x%06h, got=0x%06h",
          active_cmd_addr[23:0], spi_tr.addr[23:0]));
      end else if (a_bytes == 4 && ($isunknown(spi_tr.addr[31:0]) || spi_tr.addr[31:0] !== active_cmd_addr[31:0])) begin
        record_mismatch("QSPI_DMA_SPI_ADDR", $sformatf(
          "SPI 4-byte address mismatch: exp=0x%08h, got=0x%08h",
          active_cmd_addr[31:0], spi_tr.addr[31:0]));
      end
    end

    if (mode_en && (!allow_partial || spi_tr.end_phase >= 3)) begin
      if ($isunknown(spi_tr.mode_bits) || spi_tr.mode_bits !== active_mode_bits) begin
        record_mismatch("QSPI_DMA_SPI_MODE", $sformatf(
          "SPI mode bits mismatch: exp=0x%02h, got=0x%02h", active_mode_bits, spi_tr.mode_bits));
      end
    end

    if (!allow_partial) begin
      if (spi_tr.sclk_edges_total < exp_edges ||
          spi_tr.sclk_edges_total > exp_edges + 64'(active_cs_delay)) begin
        record_mismatch("QSPI_DMA_SPI_EDGES", $sformatf(
          "SPI total active SCLK edges mismatch: exp=%0d (+%0d cs_delay), got=%0d (len=%0d, d_lanes=%0d)",
          exp_edges, active_cs_delay, spi_tr.sclk_edges_total, active_dma_len, d_lanes));
      end
    end else if (spi_tr.sclk_edges_total > exp_edges + 64'(active_cs_delay) + 64'd2000) begin
      record_mismatch("QSPI_DMA_SPI_EDGES", $sformatf(
        "Error-path SPI SCLK edges=%0d exceeded upper bound=%0d",
        spi_tr.sclk_edges_total, exp_edges + 64'(active_cs_delay) + 64'd2000));
    end
  endfunction

  protected function void check_error_dma_transfer(qspi_transaction spi_tr);
    int unsigned c_lanes, a_lanes, d_lanes;
    longint unsigned exp_edges;
    logic [7:0] axi_bytes[$];
    int unsigned prefix_len;
    if (spi_tr == null || err_spi_checked || active_unsupported_cfg) return;
    err_spi_checked = 1'b1;

    check_spi_header_and_edges(spi_tr, 1'b1, c_lanes, a_lanes, d_lanes, exp_edges);

    if (active_dma_dir == 1'b0) begin
      foreach (captured_axi_tx[b]) begin
        for (int beat = 0; beat < captured_axi_tx[b].data.size(); beat++) begin
          bit beat_ok = (beat >= captured_axi_tx[b].rresp.size()) ? 1'b1 :
                        (captured_axi_tx[b].rresp[beat] === 2'b00);
          if (!beat_ok) break;
          for (int lane = 0; lane < 4 && axi_bytes.size() < active_dma_len; lane++) begin
            axi_bytes.push_back(captured_axi_tx[b].data[beat][lane*8 +: 8]);
          end
        end
      end
      prefix_len = (axi_bytes.size() < spi_tr.data.size()) ? axi_bytes.size() : spi_tr.data.size();
      if (prefix_len > active_dma_len) prefix_len = active_dma_len;
      for (int i = 0; i < prefix_len; i++) begin
        if ($isunknown(spi_tr.data[i]) || spi_tr.data[i] !== axi_bytes[i]) begin
          record_mismatch("QSPI_DMA_ERR_TX_PREFIX", $sformatf(
            "TX error-path prefix byte[%0d] mismatch: AXI_RDATA=0x%02h, SPI=0x%02h",
            i, axi_bytes[i], spi_tr.data[i]));
        end
      end
    end else begin
      foreach (captured_axi_rx[b]) begin
        if (captured_axi_rx[b].bresp !== 2'b00) continue;
        for (int beat = 0; beat < captured_axi_rx[b].data.size(); beat++) begin
          // Pure AMBA AXI4 Little-Endian byte ordering across active wstrb lanes
          for (int lane = 0; lane < 4; lane++) begin
            if (captured_axi_rx[b].wstrb[beat][lane])
              axi_bytes.push_back(captured_axi_rx[b].data[beat][lane*8 +: 8]);
          end
        end
      end
      prefix_len = (axi_bytes.size() < spi_tr.data.size()) ? axi_bytes.size() : spi_tr.data.size();
      if (prefix_len > active_dma_len) prefix_len = active_dma_len;
      for (int i = 0; i < prefix_len; i++) begin
        if (axi_bytes[i] !== spi_tr.data[i]) begin
          record_mismatch("QSPI_DMA_ERR_RX_PREFIX", $sformatf(
            "RX error-path prefix byte[%0d] mismatch: SPI=0x%02h, AXI_WDATA=0x%02h",
            i, spi_tr.data[i], axi_bytes[i]));
        end
      end
    end
  endfunction

  protected function void complete_dma_transfer();
    logic [7:0] axi_bytes[$];
    logic [7:0] spi_bytes[$];
    bit [31:0] exp_addr;
    int unsigned exp_beats;
    int unsigned act_beats;
    int unsigned cmp_len;
    int unsigned c_lanes, a_lanes, d_lanes;
    int unsigned max_stop_bytes;
    longint unsigned exp_edges;
    bit [3:0] exp_last_strb;

    dma_completions++;
    dma_active = 1'b0;
    dma_pending_irq_check = !(saw_dma_done_event && saw_cmd_done_event);

    if (active_unsupported_cfg) begin
      `uvm_info("QSPI_DMA_SB",
        "Skipping strict scoreboard check for out-of-scope DMA configuration", UVM_LOW)
      return;
    end

    if (captured_spi.size() == 0) begin
      record_mismatch("QSPI_DMA_SPI_MISS", "DMA completed without any captured SPI transactions");
      return;
    end else if (captured_spi.size() > 1) begin
      record_mismatch("QSPI_DMA_SPI_MULTI_FRAME", $sformatf(
        "DUT issued %0d SPI frames for a single DMA transfer (violates Spec 5.3)", captured_spi.size()));
    end

    check_spi_header_and_edges(captured_spi[0], 1'b0, c_lanes, a_lanes, d_lanes, exp_edges);
    max_stop_bytes = (int'(active_cs_delay) * d_lanes) / 8;

    foreach (captured_spi[s]) begin
      foreach (captured_spi[s].data[b]) begin
        spi_bytes.push_back(captured_spi[s].data[b]);
      end
    end

    exp_beats = (active_dma_len + 32'd3) >> 2;
    exp_addr  = active_dma_addr;

    if (active_dma_dir == 1'b1) begin
      act_beats = 0;
      case (active_dma_len % 4)
        0: exp_last_strb = 4'b1111;
        1: exp_last_strb = 4'b0001;
        2: exp_last_strb = 4'b0011;
        3: exp_last_strb = 4'b0111;
      endcase

      foreach (captured_axi_rx[b]) begin
        void'(check_axi_burst_common(captured_axi_rx[b], b));
        if (captured_axi_rx[b].addr !== exp_addr) begin
          record_mismatch("QSPI_DMA_AWADDR", $sformatf(
            "RX burst[%0d] AWADDR mismatch: exp=0x%08h, got=0x%08h (incr_addr=%0b)",
            b, exp_addr, captured_axi_rx[b].addr, active_incr_addr));
        end
        if (active_incr_addr)
          exp_addr += 32'(64'(captured_axi_rx[b].data.size()) << 2);

        for (int beat = 0; beat < captured_axi_rx[b].data.size(); beat++) begin
          bit is_final_overall_beat = (act_beats == exp_beats - 1);
          bit [3:0] strb = captured_axi_rx[b].wstrb[beat];
          bit [3:0] exp_strb = is_final_overall_beat ? exp_last_strb : 4'b1111;
          act_beats++;

          if (strb !== exp_strb) begin
            record_mismatch("QSPI_DMA_WSTRB", $sformatf(
              "RX beat[%0d] WSTRB mismatch: exp=%04b, got=%04b (len=%0d)",
              act_beats - 1, exp_strb, strb, active_dma_len));
          end

          // Standard AMBA AXI4 Little-Endian byte layout across active WSTRB lanes
          for (int lane = 0; lane < 4; lane++) begin
            if (strb[lane]) begin
              logic [7:0] byte_val;
              byte_val = captured_axi_rx[b].data[beat][lane*8 +: 8];
              if ($isunknown(byte_val)) begin
                record_mismatch("QSPI_DMA_RX_WDATA_XZ", $sformatf(
                  "RX beat[%0d] lane %0d contains unknown (X/Z): 0x%02h", act_beats - 1, lane, byte_val));
              end
              axi_bytes.push_back(byte_val);
            end
          end
        end
      end

      if (act_beats != exp_beats) begin
        record_mismatch("QSPI_DMA_RX_BEATS", $sformatf(
          "RX AXI write beat count mismatch: exp=%0d, got=%0d (len=%0d)",
          exp_beats, act_beats, active_dma_len));
      end

      if (axi_bytes.size() != active_dma_len) begin
        record_mismatch("QSPI_DMA_RX_LEN", $sformatf(
          "RX AXI byte count mismatch: exp=%0d, got=%0d", active_dma_len, axi_bytes.size()));
      end

      if (spi_bytes.size() < active_dma_len || spi_bytes.size() > active_dma_len + max_stop_bytes) begin
        record_mismatch("QSPI_DMA_RX_SPI_LEN", $sformatf(
          "RX SPI byte count mismatch: exp=[%0d .. %0d], got=%0d",
          active_dma_len, active_dma_len + max_stop_bytes, spi_bytes.size()));
      end

      cmp_len = (axi_bytes.size() < active_dma_len) ? axi_bytes.size() : active_dma_len;
      if (spi_bytes.size() < cmp_len) cmp_len = spi_bytes.size();
      for (int i = 0; i < cmp_len; i++) begin
        if ($isunknown(spi_bytes[i])) begin
          record_mismatch("QSPI_DMA_RX_SPI_XZ", $sformatf(
            "RX SPI byte[%0d] contains X/Z: 0x%02h", i, spi_bytes[i]));
        end else if (axi_bytes[i] !== spi_bytes[i]) begin
          record_mismatch("QSPI_DMA_RX_DATA", $sformatf(
            "RX End-to-End byte[%0d] mismatch (Little-Endian word byte order): SPI=0x%02h, AXI_WDATA=0x%02h",
            i, spi_bytes[i], axi_bytes[i]));
        end
      end
    end else begin
      act_beats = 0;
      foreach (captured_axi_tx[b]) begin
        void'(check_axi_burst_common(captured_axi_tx[b], b));
        if (captured_axi_tx[b].addr !== exp_addr) begin
          record_mismatch("QSPI_DMA_ARADDR", $sformatf(
            "TX burst[%0d] ARADDR mismatch: exp=0x%08h, got=0x%08h (incr_addr=%0b)",
            b, exp_addr, captured_axi_tx[b].addr, active_incr_addr));
        end
        if (active_incr_addr)
          exp_addr += 32'(64'(captured_axi_tx[b].data.size()) << 2);

        for (int beat = 0; beat < captured_axi_tx[b].data.size(); beat++) begin
          act_beats++;
          for (int lane = 0; lane < 4 && axi_bytes.size() < active_dma_len; lane++) begin
            logic [7:0] byte_val;
            byte_val = captured_axi_tx[b].data[beat][lane*8 +: 8];
            if ($isunknown(byte_val)) begin
              record_mismatch("QSPI_DMA_TX_RDATA_XZ", $sformatf(
                "TX beat[%0d] lane %0d contains X/Z: 0x%02h", act_beats - 1, lane, byte_val));
            end
            axi_bytes.push_back(byte_val);
          end
        end
      end

      if (act_beats != exp_beats) begin
        record_mismatch("QSPI_DMA_TX_BEATS", $sformatf(
          "TX AXI read beat count mismatch: exp=%0d, got=%0d (len=%0d)",
          exp_beats, act_beats, active_dma_len));
      end

      if (axi_bytes.size() != active_dma_len) begin
        record_mismatch("QSPI_DMA_TX_AXI_LEN", $sformatf(
          "TX AXI byte count mismatch: exp=%0d, got=%0d", active_dma_len, axi_bytes.size()));
      end

      if (spi_bytes.size() < active_dma_len || spi_bytes.size() > active_dma_len + max_stop_bytes) begin
        record_mismatch("QSPI_DMA_TX_SPI_LEN", $sformatf(
          "TX SPI byte count mismatch: exp=[%0d .. %0d], got=%0d",
          active_dma_len, active_dma_len + max_stop_bytes, spi_bytes.size()));
      end

      cmp_len = (axi_bytes.size() < active_dma_len) ? axi_bytes.size() : active_dma_len;
      if (spi_bytes.size() < cmp_len) cmp_len = spi_bytes.size();
      for (int i = 0; i < cmp_len; i++) begin
        if ($isunknown(spi_bytes[i])) begin
          record_mismatch("QSPI_DMA_TX_SPI_XZ", $sformatf(
            "TX SPI byte[%0d] contains X/Z: 0x%02h", i, spi_bytes[i]));
        end else if (spi_bytes[i] !== axi_bytes[i]) begin
          record_mismatch("QSPI_DMA_TX_DATA", $sformatf(
            "TX End-to-End byte[%0d] mismatch (Little-Endian word byte order): AXI_RDATA=0x%02h, SPI=0x%02h",
            i, axi_bytes[i], spi_bytes[i]));
        end
      end
    end

    `uvm_info("QSPI_DMA_SB", $sformatf(
      "DMA COMPLETE: dir=%s, len=%0d, axi_bursts=%0d, mismatches=%0d",
      active_dma_dir ? "RX" : "TX", active_dma_len,
      active_dma_dir ? captured_axi_rx.size() : captured_axi_tx.size(),
      mismatch_count), UVM_LOW)
  endfunction

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (cfg != null && cfg.clk_vif != null && cfg.clk_vif.rst_n === 1'b1)
      flush_batches();

    if (captured_spi.size() > 1) begin
      record_mismatch("QSPI_DMA_SPI_MULTI_FRAME", $sformatf(
        "DMA transfer had %0d SPI frames captured (violates Spec 5.3)", captured_spi.size()));
    end
    if (dma_active) begin
      record_mismatch("QSPI_DMA_HANGING", $sformatf(
        "Test ended with an active unretired DMA transfer (dir=%s, addr=0x%08h, dma_len=%0d)",
        active_dma_dir ? "RX" : "TX", active_dma_addr, active_dma_len));
    end
    if (dma_pending_irq_check) begin
      record_mismatch("QSPI_DMA_IRQ_UNVERIFIED",
        "Test ended without verifying DMA interrupt status (INT_STAT)");
    end
    if (cfg != null && cfg.flash_vif != null && cfg.flash_vif.qspi_cs_n === 1'b0) begin
      record_mismatch("QSPI_DMA_SPI_HANGING",
        "Test ended with physical SPI CS_N held active low (hanging/incomplete serial transfer)");
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_DMA_SB", $sformatf(
      "DMA Scoreboard Summary: tx_starts=%0d, rx_starts=%0d, completions=%0d, errors=%0d, reset_aborts=%0d, mismatches=%0d",
      tx_dma_starts, rx_dma_starts, dma_completions, dma_errors, dma_reset_aborts, mismatch_count), UVM_LOW)
  endfunction
endclass : qspi_dma_sb

`endif // QSPI_DMA_SB_SV
