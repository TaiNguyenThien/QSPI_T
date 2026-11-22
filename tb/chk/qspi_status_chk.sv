`ifndef QSPI_STATUS_CHK_SV
`define QSPI_STATUS_CHK_SV
// Checks externally observable CSR invariants. It never predicts undocumented
// cycle latency or drives APB reads. Event checks run whenever software reads
// status, while pin/reset checks run independently of software and coverage.
class qspi_status_chk extends uvm_component;
  `uvm_component_utils(qspi_status_chk)
  qspi_env_cfg cfg;
  uvm_analysis_imp #(qspi_apb_item_t, qspi_status_chk) apb_imp;
  uvm_analysis_imp_status_spi #(qspi_transaction, qspi_status_chk) spi_imp;
  qspi_csr_shadow csr;
  typedef struct { bit rx; int unsigned words; int unsigned popped; } frame_credit_t;
  frame_credit_t pending_frames[$];
  bit [4:0] exp_int_en, act_int_stat;
  bit [4:0] exp_ctrl_static;
  int unsigned checked_reads=0;
  bit indirect_pending, completion_armed, completion_observed_since_trigger, auto_clear_due;
  bit ctrl_reset_baseline=1;
  bit [1:0] completion_clear_pending;
  bit disabled_trigger_guard, fifo_exercised;
  bit dma_started_since_reset;
  bit pio_indirect;
  bit pio_dma_done_baseline;
  bit int_stat_baseline_valid = 1;
  bit xip_clean_cmd_done_base = 1;
  bit xip_clean_dma_done_base = 1;
  bit xip_clean_err_base      = 1;
  bit xip_isolation_active    = 0;
  int unsigned     xip_outstanding = 0;
  int unsigned     pio_rx_unpopped_words = 0;
  longint unsigned reset_epoch     = 0;
  bit              read_cap_valid  = 0;
  logic            read_cap_irq    = 1'b0;
  bit              read_cap_xip_ok = 0;
  typedef struct {
    qspi_apb_item_t tr;
    logic           irq_at_obs;
    bit             xip_ok_at_obs;
  } status_apb_obs_t;
  status_apb_obs_t apb_batch_q[$];

  function new(string name, uvm_component parent);
    super.new(name,parent);
    apb_imp = new("apb_imp",this);
    spi_imp = new("spi_imp",this);
    csr = new("csr");
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null || cfg.clk_vif == null || cfg.flash_vif == null ||
        cfg.apb_cfg_h == null || cfg.apb_cfg_h.apb_vif == null)
      `uvm_fatal("QSPI_STATUS_CFG", "Missing qspi_env_cfg or virtual interfaces")
  endfunction

  function void write(qspi_apb_item_t t);
    status_apb_obs_t obs;
    if (cfg == null || cfg.clk_vif == null) begin
      `uvm_fatal("QSPI_STATUS_CFG", "Missing qspi_env_cfg or clk_vif in write")
      return;
    end
    if (t == null || t.reset_abort || t.slverr !== 1'b0 ||
        cfg.clk_vif.rst_n !== 1'b1) return;
    obs.tr = t;
    if (!t.write && read_cap_valid) begin
      obs.irq_at_obs    = read_cap_irq;
      obs.xip_ok_at_obs = read_cap_xip_ok;
    end else begin
      obs.irq_at_obs    = cfg.clk_vif.irq;
      obs.xip_ok_at_obs = ((exp_ctrl_static[0] && exp_ctrl_static[1]) || (xip_outstanding > 0));
    end
    apb_batch_q.push_back(obs);
  endfunction

  function void flush_apb_batch();
    while (apb_batch_q.size() > 0) begin
      status_apb_obs_t obs = apb_batch_q.pop_front();
      process_apb(obs.tr, obs.irq_at_obs, obs.xip_ok_at_obs);
    end
  endfunction

  function void process_apb(qspi_apb_item_t t, logic irq_at_obs, bit xip_ok_at_obs);
    bit triggered;
    frame_credit_t credit;
    qspi_cmd_profile_t profile;
    if (t == null || t.reset_abort || t.slverr !== 1'b0 ||
        cfg.clk_vif.rst_n !== 1'b1) return;
    if ($isunknown({t.addr,t.write,t.strb})) begin
      `uvm_error("QSPI_STATUS_XZ", "Unknown APB controls")
      return;
    end
    if (t.write) begin
      for (int lane=0;lane<4;lane++)
        if (t.strb[lane] === 1'b1 && $isunknown(t.wdata[8*lane +: 8])) begin
          `uvm_error("QSPI_STATUS_XZ", "Unknown enabled APB write byte")
          return;
        end
      triggered=csr.apply_apb_write(t);
      if (triggered) begin
        profile=csr.get_cmd_snapshot();
        credit.rx=profile.dir && !t.wdata[9];
        credit.words=(profile.cmd_len/4)+((profile.cmd_len%4)!=0);
        credit.popped=0;
        pending_frames.push_back(credit);
      end
      case (t.addr)
        QSPI_REG_CTRL: begin
          logic [4:0] pre_ctrl_static;
          bit         eff_ctrl_en;
          pre_ctrl_static = exp_ctrl_static;
          eff_ctrl_en     = t.strb[0] ? t.wdata[0] : pre_ctrl_static[0];
          exp_ctrl_static = csr.ctrl[4:0];
          if (t.strb[1]) begin
            if ($isunknown(t.wdata[9:8])) begin
              `uvm_error("QSPI_STATUS_XZ", "CTRL[9:8] write contains X/Z")
              return;
            end
            ctrl_reset_baseline = 0;
            if (t.wdata[8] || t.wdata[9])
              auto_clear_due = 0;
          end
          if (t.strb[1] && t.wdata[8] && !eff_ctrl_en) disabled_trigger_guard=1;
          if (exp_ctrl_static[0] && exp_ctrl_static[1]) begin
            disabled_trigger_guard=0;
            xip_isolation_active=1;
            if (!indirect_pending && int_stat_baseline_valid) begin
              xip_clean_cmd_done_base = !act_int_stat[0];
              xip_clean_dma_done_base = !act_int_stat[1];
              xip_clean_err_base      = !act_int_stat[2];
            end else if (!int_stat_baseline_valid) begin
              xip_clean_cmd_done_base = 0;
              xip_clean_dma_done_base = 0;
              xip_clean_err_base      = 0;
            end
          end
          if (t.strb[1] && t.wdata[8] && eff_ctrl_en && !exp_ctrl_static[1]) begin
            disabled_trigger_guard=0;
            fifo_exercised=1;
            indirect_pending=1;
            completion_armed=!act_int_stat[0];
            completion_observed_since_trigger=0;
            auto_clear_due=0;
            completion_clear_pending[0]=0;
            xip_isolation_active=0;
            xip_clean_cmd_done_base=0;
            xip_clean_dma_done_base=0;
            xip_clean_err_base=0;
            if (t.wdata[9]) begin
              completion_clear_pending[1]=0;
              dma_started_since_reset=1;
              pio_indirect=0;
              pio_dma_done_baseline=0;
              int_stat_baseline_valid=0;
            end else begin
              pio_indirect=1;
              pio_dma_done_baseline=(int_stat_baseline_valid && !act_int_stat[1]);
              int_stat_baseline_valid=0;
            end
          end
        end
        QSPI_REG_INT_EN: exp_int_en=csr.int_en[4:0];
        QSPI_REG_WRITE_TX: fifo_exercised=1;

        QSPI_REG_INT_STAT: if (t.strb[0]) begin
          if ($isunknown(t.wdata[4:0])) begin
            `uvm_error("QSPI_STATUS_XZ", "INT_STAT W1C write contains X/Z")
            return;
          end
          if (t.wdata[1] && pio_indirect) pio_dma_done_baseline=1;
          if (!indirect_pending) begin
            completion_clear_pending |= t.wdata[1:0];
            if (t.wdata[0]) xip_clean_cmd_done_base=1;
            if (t.wdata[1]) xip_clean_dma_done_base=1;
            if (t.wdata[2]) xip_clean_err_base=1;
          end else if (t.wdata[0] && completion_armed && !act_int_stat[0]) begin
            completion_observed_since_trigger=1;
          end
          act_int_stat=qspi_csr_shadow::apply_w1c_mask(act_int_stat,t.wdata,t.strb);
        end
      endcase
      return;
    end
    case (t.addr)
      QSPI_REG_CTRL: begin
        checked_reads++;
        // Reserved-bit check derives from the shared writable mask (minus
        // CMD_TRIGGER/DMA_EN, which this checker tracks separately below)
        // so it cannot silently diverge from qspi_apb_csr_sb/qspi_flow_sb.
        if ($isunknown(t.rdata) || t.rdata[4:0] !== exp_ctrl_static ||
            (t.rdata & ~qspi_csr_writable_mask(QSPI_REG_CTRL)) !== 0)
          `uvm_error("QSPI_STATUS_CTRL", "CTRL stable fields/reserved bits mismatch")
        if ((auto_clear_due || ctrl_reset_baseline) && t.rdata[9:8]!==2'b00)
          `uvm_error("QSPI_STATUS_CTRL_CLEAR", "CMD_TRIGGER/DMA_EN did not clear after observed completion and idle")
      end
      QSPI_REG_STATUS: begin
        checked_reads++;
        if ($isunknown(t.rdata) || t.rdata[31:4] !== 0)
          `uvm_error("QSPI_STATUS_RESERVED", "STATUS reserved bits are nonzero/unknown")
        if (!xip_ok_at_obs && t.rdata[1]!==1'b0)
          `uvm_error("QSPI_STATUS_XIP", "STATUS.XIP_ACTIVE asserted with XIP disabled and no draining XIP request")
        if (!xip_ok_at_obs && !indirect_pending && t.rdata[1:0] !== 2'b00)
          `uvm_error("QSPI_STATUS_QUIESCENT", $sformatf(
            "Expected STATUS.{XIP_ACTIVE,BUSY}=2'b00 when quiescent idle, got STATUS=0x%08h", t.rdata))
        if (!dma_started_since_reset && t.rdata[3]!==1'b0)
          `uvm_error("QSPI_STATUS_PIO_ISOLATION", "STATUS.DMA_DONE asserted without a DMA command since reset")
        if (indirect_pending && t.rdata[0] === 1'b0 &&
            (completion_observed_since_trigger || act_int_stat[2] ||
             (completion_armed && (act_int_stat[0] || (dma_started_since_reset && act_int_stat[1]))))) begin
          auto_clear_due=1;
          indirect_pending=0;
          if (act_int_stat[2] && cfg.flash_vif.qspi_cs_n === 1'b1)
            pending_frames.delete();
        end
      end
      QSPI_REG_INT_STAT: begin
        checked_reads++;
        if ($isunknown(t.rdata) || t.rdata[31:5] !== 0) begin
          `uvm_error("QSPI_STATUS_INT_STAT", "INT_STAT unknown/reserved bits")
          return; // An invalid read must not erase previously known events.
        end
        if ((t.rdata[4:0] & act_int_stat) !== act_int_stat)
          `uvm_error("QSPI_STATUS_W1C", "A latched event disappeared without W1C/reset")
        if (indirect_pending && (t.rdata[0] === 1'b1 || (dma_started_since_reset && t.rdata[1] === 1'b1)))
          completion_observed_since_trigger = 1;
        if (pio_indirect && (!dma_started_since_reset || pio_dma_done_baseline) && t.rdata[1]!==1'b0)
          `uvm_error("QSPI_STATUS_DMA_EVENT", "PIO produced an unexpected DMA_DONE event")
        if (((exp_ctrl_static[0] && exp_ctrl_static[1]) || xip_outstanding > 0 || xip_isolation_active) && !indirect_pending) begin
          if (xip_clean_cmd_done_base && t.rdata[0] !== 1'b0)
            `uvm_error("QSPI_STATUS_XIP_EVENT", "XIP activity produced an unexpected CMD_DONE event")
          if ((!dma_started_since_reset || xip_clean_dma_done_base) && t.rdata[1] !== 1'b0)
            `uvm_error("QSPI_STATUS_XIP_EVENT", "XIP activity produced an unexpected DMA_DONE event")
          if (xip_clean_err_base && (pio_rx_unpopped_words < 4) && t.rdata[2] !== 1'b0)
            `uvm_error("QSPI_STATUS_XIP_ERR", "Clean XIP activity unexpectedly latched INT_STAT.ERR=1")
          if (!(exp_ctrl_static[0] && exp_ctrl_static[1]) && xip_outstanding == 0)
            xip_isolation_active = 0;
        end
        if ((t.rdata[1:0] & completion_clear_pending)!=0)
          `uvm_error("QSPI_STATUS_W1C_CLEAR", "A quiescent completion bit remained set after W1C")
        completion_clear_pending=0;
        if (irq_at_obs !== (|(t.rdata[4:0] & exp_int_en)))
          `uvm_error("QSPI_STATUS_IRQ", "IRQ differs from OR(INT_STAT & INT_EN)")
        act_int_stat = t.rdata[4:0];
        if (!indirect_pending) begin
          int_stat_baseline_valid = 1;
          xip_clean_cmd_done_base = !act_int_stat[0];
          xip_clean_dma_done_base = !act_int_stat[1];
          xip_clean_err_base      = !act_int_stat[2];
        end
      end
      QSPI_REG_READ_RX: begin
        if (pio_rx_unpopped_words > 0)
          pio_rx_unpopped_words--;
        else if (pending_frames.size()>0 && pending_frames[0].rx)
          pending_frames[0].popped++;
      end
      QSPI_REG_FIFO_STAT: begin
        checked_reads++;
        if ($isunknown(t.rdata) || t.rdata[31:10] !== 0 ||
            t.rdata[3:0] > 4 || t.rdata[7:4] > 4)
          `uvm_error("QSPI_STATUS_FIFO", "FIFO level exceeds depth four or reserved bits are invalid")
        if ((t.rdata[8] && t.rdata[3:0] != 0) ||
            (t.rdata[9] && t.rdata[7:4] != 4))
          `uvm_error("QSPI_STATUS_FIFO", "FIFO boundary flag disagrees with reported level")
        // Only completed PIO frames justify residual RX words after XIP drains.
        if (exp_ctrl_static[1] && exp_ctrl_static[0] && xip_outstanding == 0 &&
            !indirect_pending && t.rdata[7:4] !== 4'(pio_rx_unpopped_words)) begin
          `uvm_error("QSPI_STATUS_XIP_RX_RESIDUAL", $sformatf(
            "Quiescent XIP RX_LEVEL=%0d differs from completed PIO credit=%0d in FIFO_STAT=0x%08h",
            t.rdata[7:4], pio_rx_unpopped_words, t.rdata))
        end
        // Do not impose the ambiguous reset-table TX_EMPTY value. Once the
        // FIFO has been exercised, boundary indications must work both ways.
        if (fifo_exercised && (t.rdata[8] !== (t.rdata[3:0]==0) ||
                              t.rdata[9] !== (t.rdata[7:4]==4)))
          `uvm_error("QSPI_STATUS_FIFO_BOUNDARY", "Missing FIFO empty/full indication")
      end
      QSPI_REG_ERR_STAT: begin
        checked_reads++;
        if ($isunknown(t.rdata) || t.rdata[31:3] !== 0)
          `uvm_error("QSPI_STATUS_ERR_STAT", "ERR_STAT unknown/reserved bits")
        if (exp_ctrl_static[1] && exp_ctrl_static[0] && xip_outstanding == 0 &&
            !indirect_pending && (pio_rx_unpopped_words < 4) && !act_int_stat[2] &&
            t.rdata[2:0] !== 3'b000) begin
          `uvm_error("QSPI_STATUS_XIP_LIVE_ERR", $sformatf(
            "Unexpected live ERR_STAT=0x%08h during clean quiescent XIP", t.rdata))
        end
        if (|t.rdata[2:0]) act_int_stat[2] = 1;
      end
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    virtual axil_if axil_vif_h;
    if (cfg == null || cfg.clk_vif == null || cfg.flash_vif == null ||
        cfg.apb_cfg_h == null || cfg.apb_cfg_h.apb_vif == null)
      `uvm_fatal("QSPI_STATUS_CFG", "Missing qspi_env_cfg or virtual interfaces in run_phase")
    axil_vif_h = (cfg.axil_vif != null) ? cfg.axil_vif :
                 ((cfg.axil_cfg_h != null) ? cfg.axil_cfg_h.vif : null);
    fork
      forever begin
        @(negedge cfg.clk_vif.rst_n);
        reset_epoch++;
        apb_batch_q.delete();
        exp_int_en = 0; act_int_stat = 0; exp_ctrl_static = 0;
        indirect_pending=0; completion_armed=0; completion_observed_since_trigger=0; auto_clear_due=0;
        ctrl_reset_baseline=1; completion_clear_pending=0;
        dma_started_since_reset=0; pio_indirect=0; pio_dma_done_baseline=0;
        int_stat_baseline_valid=1; xip_clean_cmd_done_base=1; xip_clean_dma_done_base=1;
        xip_clean_err_base=1;
        pio_rx_unpopped_words=0;
        csr.reset(); pending_frames.delete();
        xip_isolation_active=0;
        disabled_trigger_guard=0; fifo_exercised=0;
        xip_outstanding=0;
        read_cap_valid=0;
      end
      forever begin
        @(negedge cfg.flash_vif.qspi_cs_n);
        if (cfg.clk_vif.rst_n===1 && disabled_trigger_guard)
          `uvm_error("QSPI_PIO_DISABLED_TRIGGER","Serial CS asserted after a disabled trigger")
      end
      forever begin
        bit ar_hs, r_hs, xip_en_pre, apb_rd_done_edge;
        longint unsigned edge_epoch;
        @(posedge cfg.clk_vif.clk);
        edge_epoch = reset_epoch;
        ar_hs = (axil_vif_h != null && cfg.clk_vif.rst_n === 1'b1 &&
                 axil_vif_h.arvalid === 1'b1 && axil_vif_h.arready === 1'b1);
        r_hs  = (axil_vif_h != null && cfg.clk_vif.rst_n === 1'b1 &&
                 axil_vif_h.rvalid  === 1'b1 && axil_vif_h.rready  === 1'b1);
        xip_en_pre = (exp_ctrl_static[0] && exp_ctrl_static[1]);
        apb_rd_done_edge = (cfg.apb_cfg_h != null && cfg.apb_cfg_h.apb_vif != null &&
                            cfg.clk_vif.rst_n === 1'b1 &&
                            cfg.apb_cfg_h.apb_vif.psel === 1'b1 &&
                            cfg.apb_cfg_h.apb_vif.penable === 1'b1 &&
                            !cfg.apb_cfg_h.apb_vif.pwrite &&
                            cfg.apb_cfg_h.apb_vif.pready === 1'b1);
        if (cfg.apb_cfg_h != null && cfg.apb_cfg_h.apb_vif != null &&
            cfg.clk_vif.rst_n === 1'b1 &&
            cfg.apb_cfg_h.apb_vif.psel === 1'b1 &&
            !cfg.apb_cfg_h.apb_vif.pwrite &&
            (!cfg.apb_cfg_h.apb_vif.penable || cfg.apb_cfg_h.apb_vif.pready === 1'b0)) begin
          read_cap_valid  = 1'b1;
          read_cap_irq    = cfg.clk_vif.irq;
          read_cap_xip_ok = ((exp_ctrl_static[0] && exp_ctrl_static[1]) || (xip_outstanding > 0));
        end
        #1ps; // qspi_chk_pkg precision is 1ps; allow edge updates to settle.
        if (cfg.clk_vif.rst_n === 1'b1 && edge_epoch == reset_epoch) begin
          if (ar_hs && xip_en_pre)
            xip_outstanding++;
          flush_apb_batch();
          if (apb_rd_done_edge)
            read_cap_valid = 1'b0;
          if (r_hs && xip_outstanding > 0)
            xip_outstanding--;
          if ($isunknown(cfg.clk_vif.irq))
            `uvm_error("QSPI_STATUS_IRQ", "IRQ is X/Z after reset")
          if (exp_int_en == 0 && cfg.clk_vif.irq !== 1'b0)
            `uvm_error("QSPI_STATUS_IRQ_MASK", "IRQ asserted with all sources masked")
        end else if (cfg.clk_vif.rst_n === 1'b0 &&
                     cfg.clk_vif.irq !== 1'b0)
          `uvm_error("QSPI_STATUS_IRQ_RESET", "IRQ did not clear during reset")
      end
    join
  endtask

  function void write_status_spi(qspi_transaction tr);
    frame_credit_t credit;
    int unsigned remaining;
    if (tr==null || cfg.clk_vif.rst_n !== 1'b1) return;
    flush_apb_batch();
    if (pending_frames.size()==0) return;
    credit=pending_frames.pop_front();
    if (tr.aborted_early || !credit.rx) return;
    remaining=(credit.words>credit.popped) ? credit.words-credit.popped : 0;
    pio_rx_unpopped_words+=remaining;
    if (pio_rx_unpopped_words>4) pio_rx_unpopped_words=4;
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (cfg.clk_vif.rst_n === 1'b1)
      flush_apb_batch();
  endfunction
endclass : qspi_status_chk
`endif
