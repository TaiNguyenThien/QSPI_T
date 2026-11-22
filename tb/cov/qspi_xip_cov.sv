`ifndef QSPI_XIP_COV_SV
`define QSPI_XIP_COV_SV

`uvm_analysis_imp_decl(_xip_cov_ar)
`uvm_analysis_imp_decl(_xip_cov_r)
`uvm_analysis_imp_decl(_xip_cov_apb)
`uvm_analysis_imp_decl(_xip_cov_spi)

class qspi_xip_cov extends uvm_component;
  `uvm_component_utils(qspi_xip_cov)

  typedef struct packed {
    bit        valid;
    bit [1:0]  cmd_lanes;
    bit [1:0]  addr_lanes;
    bit [1:0]  data_lanes;
    bit [5:0]  lane_profile;
    bit        quad_en;
    bit [1:0]  addr_bytes;
    bit        mode_en;
    bit [3:0]  dummy_cycles;
    bit [2:0]  clk_div;
    bit [1:0]  spi_mode;
    bit [1:0]  cs_delay;
    bit [7:0]  read_opcode;
    bit [7:0]  mode_bits;
  } xip_cfg_snap_t;

  qspi_env_cfg cfg;

  uvm_analysis_imp_xip_cov_ar  #(axil_master_transaction, qspi_xip_cov) axil_ar_export;
  uvm_analysis_imp_xip_cov_r   #(axil_master_transaction, qspi_xip_cov) axil_r_export;
  uvm_analysis_imp_xip_cov_apb #(qspi_apb_item_t,         qspi_xip_cov) apb_export;
  uvm_analysis_imp_xip_cov_spi #(qspi_transaction,        qspi_xip_cov) spi_export;

  // Batched same-edge observation queues with reset timestamps (drained in R -> AR -> SPI -> APB order)
  protected axil_master_transaction ar_batch_q[$];
  protected realtime                ar_ts_q[$];
  protected axil_master_transaction r_batch_q[$];
  protected realtime                r_ts_q[$];
  protected qspi_transaction        spi_batch_q[$];
  protected realtime                spi_ts_q[$];
  protected qspi_apb_item_t         apb_batch_q[$];
  protected realtime                apb_ts_q[$];
  protected realtime                last_reset_ts = 0.0;

  // Shared spec-compliant passive CSR shadow instance
  qspi_csr_shadow csr;

  // Ownership tracking: completed XIP configs waiting for R and physical SPI frame owners (1=XIP, 0=NON_XIP)
  protected xip_cfg_snap_t pending_xip_cfg_q[$];
  protected bit            xip_spi_owner_q[$];
  protected int unsigned   pending_reset_aborted_xip_spi = 0;
  int unsigned pending_xip_spi_frames = 0;

  // Sampled counters for sign-off audit
  int unsigned ar_sampled    = 0;
  int unsigned r_sampled     = 0;
  int unsigned spi_sampled   = 0;
  int unsigned abort_sampled = 0;

  // Sampled configuration variables (effective vs requested)
  bit [1:0]  cov_cmd_lanes;
  bit [1:0]  cov_addr_lanes;
  bit [1:0]  cov_data_lanes;
  bit [1:0]  cov_req_cmd_lanes;
  bit [1:0]  cov_req_addr_lanes;
  bit [1:0]  cov_req_data_lanes;
  bit [5:0]  cov_lane_profile;
  bit        cov_quad_en;
  bit        cov_req_quad_en;
  bit [1:0]  cov_addr_bytes;
  bit        cov_mode_en;
  bit [3:0]  cov_dummy_cycles;
  bit [2:0]  cov_clk_div;
  bit [1:0]  cov_spi_mode;
  bit [1:0]  cov_cs_delay;
  bit [7:0]  cov_read_opcode;
  bit [7:0]  cov_mode_bits;

  // Control enable-matrix & mode-transition telemetry
  bit [1:0]   cov_ctrl_enable_pair; // {ctrl.xip_en, ctrl.enable}
  qspi_mode_e cur_mode_state = QSPI_MODE_IDLE;
  bit [2:0]   cov_mode_switch; // 0:IDLE->XIP 1:XIP->IDLE 2:PIO->XIP 3:XIP->PIO 4:DMA->XIP 5:XIP->DMA 6:PIO->DMA 7:DMA->PIO

  // Sampled AXI4-Lite protocol variables
  bit [1:0]        cov_rresp;
  bit [2:0]        cov_arprot;
  bit [1:0]        cov_addr_align;
  bit [31:0]       cov_araddr;
  int unsigned     cov_ar_wait;
  int unsigned     cov_r_stall;
  bit              cov_reset_abort;
  bit              cov_ar_accepted_on_abort;

  // Sampled SPI physical frame variables
  bit [7:0]        cov_spi_opcode;
  int unsigned     cov_spi_end_phase;
  bit              cov_spi_aborted;

  covergroup cg_xip_config;
    option.per_instance = 1;

    cp_cmd_lanes: coverpoint cov_cmd_lanes {
      bins l1 = {2'b00};
      bins l2 = {2'b01};
      bins l4 = {2'b10};
    }
    cp_addr_lanes: coverpoint cov_addr_lanes {
      bins l1 = {2'b00};
      bins l2 = {2'b01};
      bins l4 = {2'b10};
    }
    cp_data_lanes: coverpoint cov_data_lanes {
      bins l1 = {2'b00};
      bins l2 = {2'b01};
      bins l4 = {2'b10};
    }
    cp_lane_profile: coverpoint cov_lane_profile {
      bins p_1_1_1 = {6'b00_00_00};
      bins p_1_1_2 = {6'b01_00_00};
      bins p_1_2_2 = {6'b01_01_00};
      bins p_1_1_4 = {6'b10_00_00};
      bins p_1_4_4 = {6'b10_10_00};
      bins p_4_4_4 = {6'b10_10_10};
    }
    cp_quad_en: coverpoint cov_quad_en {
      bins off = {1'b0};
      bins on  = {1'b1};
    }
    cp_addr_bytes: coverpoint cov_addr_bytes {
      bins addr_0b = {2'b00};
      bins addr_3b = {2'b01};
      bins addr_4b = {2'b10};
    }
    cp_mode_en: coverpoint cov_mode_en {
      bins off = {1'b0};
      bins on  = {1'b1};
    }
    cp_dummy_cycles: coverpoint cov_dummy_cycles {
      bins d[] = {[4'd0:4'd15]};
    }
    cp_clk_div: coverpoint cov_clk_div {
      bins div[] = {[3'd0:3'd7]};
    }
    cp_spi_mode: coverpoint cov_spi_mode {
      bins mode0 = {2'b00};
      bins mode1 = {2'b01};
      bins mode2 = {2'b10};
      bins mode3 = {2'b11};
    }
    cp_cs_delay: coverpoint cov_cs_delay {
      bins dly[] = {[2'd0:2'd3]};
    }
    cp_read_opcode: coverpoint cov_read_opcode {
      bins op_03    = {8'h03};
      bins op_0b    = {8'h0B};
      bins op_3b    = {8'h3B};
      bins op_6b    = {8'h6B};
      bins op_eb    = {8'hEB};
      bins op_other = default;
    }
    cp_mode_bits: coverpoint cov_mode_bits {
      bins m_00    = {8'h00};
      bins m_a5    = {8'hA5};
      bins m_5a    = {8'h5A};
      bins m_ff    = {8'hFF};
      bins m_other = default;
    }

    cx_profile_addr_bytes: cross cp_lane_profile, cp_addr_bytes {
      ignore_bins zero_addr = binsof(cp_addr_bytes.addr_0b);
    }
    cx_mode_div:           cross cp_spi_mode, cp_clk_div;
    cx_mode_en_dummy:      cross cp_mode_en, cp_dummy_cycles;
  endgroup

  covergroup cg_xip_protocol;
    option.per_instance = 1;

    cp_rresp: coverpoint cov_rresp {
      bins okay   = {2'b00};
      bins slverr = {2'b10};
    }
    cp_arprot: coverpoint cov_arprot {
      bins prot[] = {[3'b000:3'b111]};
    }
    cp_addr_align: coverpoint cov_addr_align {
      bins aligned = {2'b00};
      bins off1    = {2'b01};
      bins off2    = {2'b10};
      bins off3    = {2'b11};
    }
    cp_addr_region: coverpoint cov_araddr {
      bins base_zero       = {[32'h0000_0000:32'h0000_0003]};
      bins low_region      = {[32'h0000_0004:32'h00FF_FFFB]};
      bins boundary_16m_m4 = {[32'h00FF_FFFC:32'h00FF_FFFF]};
      bins boundary_16m    = {[32'h0100_0000:32'h0100_0003]};
      bins high_region     = {[32'h0100_0004:32'hFFFF_FFFB]};
      bins max_word        = {[32'hFFFF_FFFC:32'hFFFF_FFFF]};
    }
    cp_ar_wait: coverpoint cov_ar_wait {
      bins zero       = {0};
      bins short_wait = {[1:4]};
      bins long_wait  = {[5:$]};
    }

    cx_resp_align: cross cp_rresp, cp_addr_align {
      // Unaligned XIP reads return OKAY per XIP_TC_012 characterization.
      ignore_bins unaligned_slverr = binsof(cp_rresp.slverr) && !binsof(cp_addr_align.aligned);
    }
  endgroup

  // Standard AXI4-Lite post-valid backpressure coverage (short & long stall durations)
  covergroup cg_xip_strict_backpressure;
    option.per_instance = 1;

    cp_rresp_strict: coverpoint cov_rresp {
      bins okay   = {2'b00};
      bins slverr = {2'b10};
    }
    cp_r_stall_strict: coverpoint cov_r_stall {
      bins zero        = {0};
      bins short_stall = {[1:4]};
      bins long_stall  = {[5:$]};
    }
    cx_resp_stall_strict: cross cp_rresp_strict, cp_r_stall_strict;
  endgroup

  // Separate requested lanes vs QUAD_EN, plus full CTRL.{XIP_EN,ENABLE} 2x2 gating matrix.
  covergroup cg_xip_control_matrix;
    option.per_instance = 1;

    cp_ctrl_enable_matrix: coverpoint cov_ctrl_enable_pair {
      bins dis_all  = {2'b00};
      bins en_only  = {2'b01};
      bins xip_only = {2'b10};
      bins en_xip   = {2'b11};
    }
    cp_req_cmd_lanes: coverpoint cov_req_cmd_lanes {
      bins l1 = {2'b00};
      bins l2 = {2'b01};
      bins l4 = {2'b10};
    }
    cp_req_addr_lanes: coverpoint cov_req_addr_lanes {
      bins l1 = {2'b00};
      bins l2 = {2'b01};
      bins l4 = {2'b10};
    }
    cp_req_data_lanes: coverpoint cov_req_data_lanes {
      bins l1 = {2'b00};
      bins l2 = {2'b01};
      bins l4 = {2'b10};
    }
    cp_req_quad_en: coverpoint cov_req_quad_en {
      bins off = {1'b0};
      bins on  = {1'b1};
    }
    cx_req_cmd_quad:  cross cp_req_cmd_lanes,  cp_req_quad_en;
    cx_req_addr_quad: cross cp_req_addr_lanes, cp_req_quad_en;
    cx_req_data_quad: cross cp_req_data_lanes, cp_req_quad_en;
  endgroup

  covergroup cg_xip_mode_transitions;
    option.per_instance = 1;

    cp_mode_switch: coverpoint cov_mode_switch {
      bins idle_to_xip = {3'd0};
      bins xip_to_idle = {3'd1};
      bins pio_to_xip  = {3'd2};
      bins xip_to_pio  = {3'd3};
      bins dma_to_xip  = {3'd4};
      bins xip_to_dma  = {3'd5};
      bins pio_to_dma  = {3'd6};
      bins dma_to_pio  = {3'd7};
    }
  endgroup

  covergroup cg_xip_abort;
    option.per_instance = 1;

    cp_reset_abort: coverpoint cov_reset_abort {
      bins normal  = {1'b0};
      bins aborted = {1'b1};
    }
    cp_ar_accepted: coverpoint cov_ar_accepted_on_abort {
      bins pre_accept  = {1'b0};
      bins post_accept = {1'b1};
    }
    cx_abort_phase: cross cp_reset_abort, cp_ar_accepted {
      ignore_bins normal_pre_accept = binsof(cp_reset_abort.normal) && binsof(cp_ar_accepted.pre_accept);
    }
  endgroup

  covergroup cg_xip_spi_frame;
    option.per_instance = 1;

    cp_spi_opcode: coverpoint cov_spi_opcode {
      bins op_03    = {8'h03};
      bins op_0b    = {8'h0B};
      bins op_3b    = {8'h3B};
      bins op_6b    = {8'h6B};
      bins op_eb    = {8'hEB};
      bins op_other = default;
    }
    cp_spi_end_phase: coverpoint cov_spi_end_phase {
      bins phase_cmd      = {0};
      bins phase_addr     = {1};
      bins phase_mode     = {2};
      bins phase_dummy    = {3};
      bins phase_data_mid = {4};
      bins phase_complete = {5};
    }
    cp_spi_aborted: coverpoint cov_spi_aborted {
      bins complete = {1'b0};
      bins aborted  = {1'b1};
    }
  endgroup

  function new(string name = "qspi_xip_cov", uvm_component parent = null);
    super.new(name, parent);
    axil_ar_export = new("axil_ar_export", this);
    axil_r_export  = new("axil_r_export",  this);
    apb_export     = new("apb_export",     this);
    spi_export     = new("spi_export",     this);
    csr                        = qspi_csr_shadow::type_id::create("xip_cov_csr");
    cg_xip_config              = new();
    cg_xip_protocol            = new();
    cg_xip_strict_backpressure = new();
    cg_xip_abort               = new();
    cg_xip_spi_frame           = new();
    cg_xip_control_matrix      = new();
    cg_xip_mode_transitions    = new();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null && !uvm_config_db#(qspi_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("QSPI_XIP_COV", "Missing qspi_env_cfg")
    if (cfg.clk_vif == null)
      `uvm_fatal("QSPI_XIP_COV", "Missing clk_vif in qspi_env_cfg")
  endfunction

  virtual function void reset_shadows();
    if (csr != null)
      csr.reset();
    pending_xip_spi_frames = 0;
    pending_xip_cfg_q.delete();
    xip_spi_owner_q.delete();
    ar_batch_q.delete(); ar_ts_q.delete();
    r_batch_q.delete();  r_ts_q.delete();
    apb_batch_q.delete(); apb_ts_q.delete();
    spi_batch_q.delete(); spi_ts_q.delete();
  endfunction

  virtual function void process_ar(axil_master_transaction tr);
    xip_cfg_snap_t snap;
    bit [1:0] raw_cmd, raw_addr, raw_data, addr_bytes;
    bit       quad_en, valid_cfg;
    if (tr == null || tr.reset_abort || $isunknown({tr.addr, tr.prot}))
      return;
    raw_cmd    = csr.xip_cfg[1:0];
    raw_addr   = csr.xip_cfg[3:2];
    raw_data   = csr.xip_cfg[5:4];
    addr_bytes = csr.xip_cfg[7:6];
    quad_en    = csr.ctrl[2];
    valid_cfg  = (csr.ctrl[0] && csr.ctrl[1] &&
                  raw_cmd != 2'b11 && raw_addr != 2'b11 &&
                  raw_data != 2'b11 && addr_bytes != 2'b11);
    snap = '0;
    snap.valid        = valid_cfg;
    snap.quad_en      = quad_en;
    snap.cmd_lanes    = qspi_eff_lane_enc(raw_cmd,  quad_en);
    snap.addr_lanes   = qspi_eff_lane_enc(raw_addr, quad_en);
    snap.data_lanes   = qspi_eff_lane_enc(raw_data, quad_en);
    snap.lane_profile = {snap.data_lanes, snap.addr_lanes, snap.cmd_lanes};
    snap.addr_bytes   = addr_bytes;
    snap.mode_en      = csr.xip_cfg[8];
    snap.dummy_cycles = csr.xip_cfg[12:9];
    snap.clk_div      = csr.clk_div[2:0];
    snap.spi_mode     = {csr.ctrl[3], csr.ctrl[4]}; // {CPOL, CPHA}
    snap.cs_delay     = csr.cs_ctrl[3:2];
    snap.read_opcode  = csr.xip_cmd[7:0];
    snap.mode_bits    = csr.xip_cmd[23:16];
    pending_xip_cfg_q.push_back(snap);
    if (valid_cfg) begin
      xip_spi_owner_q.push_back(1'b1);
      pending_xip_spi_frames++;
      cov_ctrl_enable_pair = {csr.ctrl[1], csr.ctrl[0]};
      cov_req_cmd_lanes    = raw_cmd;
      cov_req_addr_lanes   = raw_addr;
      cov_req_data_lanes   = raw_data;
      cov_req_quad_en      = quad_en;
      cg_xip_control_matrix.sample();
      record_mode_switch(QSPI_MODE_XIP);
    end
  endfunction

  virtual function void process_r(axil_master_transaction tr);
    xip_cfg_snap_t snap;
    bit            have_snap;
    if (tr == null)
      return;
    cov_reset_abort          = tr.reset_abort;
    cov_ar_accepted_on_abort = tr.ar_accepted;
    cg_xip_abort.sample();
    if (tr.reset_abort) begin
      abort_sampled++;
      return;
    end
    have_snap = 1'b0;
    snap = '0;
    if (pending_xip_cfg_q.size() > 0) begin
      snap = pending_xip_cfg_q.pop_front();
      have_snap = 1'b1;
    end
    if (!tr.r_completed || $isunknown({tr.addr, tr.prot, tr.resp}))
      return;
    cov_rresp      = tr.resp;
    cov_arprot     = tr.prot;
    cov_addr_align = tr.addr[1:0];
    cov_araddr     = tr.addr;
    cov_ar_wait    = tr.ar_wait;
    cov_r_stall    = tr.r_stall;
    cg_xip_protocol.sample();
    if (cg_xip_strict_backpressure != null)
      cg_xip_strict_backpressure.sample();
    r_sampled++;
    if (have_snap && snap.valid && tr.resp == 2'b00) begin
      cov_cmd_lanes    = snap.cmd_lanes;
      cov_addr_lanes   = snap.addr_lanes;
      cov_data_lanes   = snap.data_lanes;
      cov_lane_profile = snap.lane_profile;
      cov_quad_en      = snap.quad_en;
      cov_addr_bytes   = snap.addr_bytes;
      cov_mode_en      = snap.mode_en;
      cov_dummy_cycles = snap.dummy_cycles;
      cov_clk_div      = snap.clk_div;
      cov_spi_mode     = snap.spi_mode;
      cov_cs_delay     = snap.cs_delay;
      cov_read_opcode  = snap.read_opcode;
      cov_mode_bits    = snap.mode_bits;
      cg_xip_config.sample();
      ar_sampled++;
    end
  endfunction

  virtual function void process_spi(qspi_transaction tr);
    bit is_xip;
    if (tr == null)
      return;
    if (xip_spi_owner_q.size() == 0)
      return;
    is_xip = xip_spi_owner_q.pop_front();
    if (!is_xip)
      return;
    if (pending_xip_spi_frames > 0)
      pending_xip_spi_frames--;
    if ($isunknown(tr.opcode))
      return;
    cov_spi_opcode    = tr.opcode;
    cov_spi_end_phase = tr.end_phase;
    cov_spi_aborted   = tr.aborted_early;
    cg_xip_spi_frame.sample();
    spi_sampled++;
  endfunction

  protected function void record_mode_switch(qspi_mode_e next_mode);
    if (next_mode == cur_mode_state)
      return;
    if (cur_mode_state == QSPI_MODE_IDLE && next_mode == QSPI_MODE_XIP)
      cov_mode_switch = 3'd0;
    else if (cur_mode_state == QSPI_MODE_XIP && next_mode == QSPI_MODE_IDLE)
      cov_mode_switch = 3'd1;
    else if (cur_mode_state == QSPI_MODE_PIO && next_mode == QSPI_MODE_XIP)
      cov_mode_switch = 3'd2;
    else if (cur_mode_state == QSPI_MODE_XIP && next_mode == QSPI_MODE_PIO)
      cov_mode_switch = 3'd3;
    else if (cur_mode_state == QSPI_MODE_DMA && next_mode == QSPI_MODE_XIP)
      cov_mode_switch = 3'd4;
    else if (cur_mode_state == QSPI_MODE_XIP && next_mode == QSPI_MODE_DMA)
      cov_mode_switch = 3'd5;
    else if (cur_mode_state == QSPI_MODE_PIO && next_mode == QSPI_MODE_DMA)
      cov_mode_switch = 3'd6;
    else if (cur_mode_state == QSPI_MODE_DMA && next_mode == QSPI_MODE_PIO)
      cov_mode_switch = 3'd7;
    else begin
      cur_mode_state = next_mode;
      return;
    end
    cg_xip_mode_transitions.sample();
    cur_mode_state = next_mode;
  endfunction

  virtual function void process_apb(qspi_apb_item_t tr);
    bit triggered;
    if (tr == null || tr.reset_abort || !tr.write || tr.slverr !== 1'b0)
      return;
    if ($isunknown({tr.write, tr.addr, tr.strb, tr.slverr}))
      return;
    for (int b = 0; b < 4; b++) begin
      if (tr.strb[b] === 1'b1 && $isunknown(tr.wdata[8*b +: 8]))
        return;
    end
    triggered = csr.apply_apb_write(tr);
    if (tr.addr == QSPI_REG_CTRL) begin
      if (triggered) begin
        xip_spi_owner_q.push_back(1'b0); // Non-XIP PIO/DMA SPI frame
        if (tr.wdata[9] === 1'b1)
          record_mode_switch(QSPI_MODE_DMA);
        else
          record_mode_switch(QSPI_MODE_PIO);
      end
      if (!csr.ctrl[0] && cur_mode_state == QSPI_MODE_XIP)
        record_mode_switch(QSPI_MODE_IDLE);
    end
  endfunction

  virtual function void drain_batches();
    realtime ts;
    while (r_batch_q.size() > 0) begin
      ts = r_ts_q.pop_front();
      if (ts >= last_reset_ts) process_r(r_batch_q.pop_front());
      else void'(r_batch_q.pop_front());
    end
    while (ar_batch_q.size() > 0) begin
      ts = ar_ts_q.pop_front();
      if (ts >= last_reset_ts) process_ar(ar_batch_q.pop_front());
      else void'(ar_batch_q.pop_front());
    end
    while (spi_batch_q.size() > 0) begin
      ts = spi_ts_q.pop_front();
      if (ts >= last_reset_ts) process_spi(spi_batch_q.pop_front());
      else void'(spi_batch_q.pop_front());
    end
    while (apb_batch_q.size() > 0) begin
      ts = apb_ts_q.pop_front();
      if (ts >= last_reset_ts) process_apb(apb_batch_q.pop_front());
      else void'(apb_batch_q.pop_front());
    end
  endfunction

  virtual function void write_xip_cov_ar(axil_master_transaction tr);
    if (tr != null) begin
      ar_batch_q.push_back(tr);
      ar_ts_q.push_back($realtime);
    end
  endfunction

  virtual function void write_xip_cov_r(axil_master_transaction tr);
    if (tr == null)
      return;
    if (tr.reset_abort === 1'b1) begin
      process_r(tr);
      return;
    end
    r_batch_q.push_back(tr);
    r_ts_q.push_back($realtime);
  endfunction

  virtual function void write_xip_cov_spi(qspi_transaction tr);
    if (tr == null)
      return;
    if (tr.aborted_early && ($realtime == last_reset_ts) && (pending_reset_aborted_xip_spi > 0) && !$isunknown(tr.opcode)) begin
      pending_reset_aborted_xip_spi--;
      cov_spi_opcode    = tr.opcode;
      cov_spi_end_phase = tr.end_phase;
      cov_spi_aborted   = tr.aborted_early;
      cg_xip_spi_frame.sample();
      spi_sampled++;
      return;
    end
    spi_batch_q.push_back(tr);
    spi_ts_q.push_back($realtime);
  endfunction

  virtual function void write_xip_cov_apb(qspi_apb_item_t tr);
    if (tr != null) begin
      apb_batch_q.push_back(tr);
      apb_ts_q.push_back($realtime);
    end
  endfunction

  virtual task run_phase(uvm_phase phase);
    virtual axil_if axil_vif_h;
    reset_shadows();
    axil_vif_h = (cfg != null && cfg.axil_cfg_h != null && cfg.axil_cfg_h.vif != null) ?
                 cfg.axil_cfg_h.vif : ((cfg != null) ? cfg.axil_vif : null);
    if (cfg != null && cfg.clk_vif != null) begin
      fork
        forever begin
          @(negedge cfg.clk_vif.rst_n);
          last_reset_ts = $realtime;
          pending_reset_aborted_xip_spi = 0;
          while (r_batch_q.size() > 0) begin
            void'(r_ts_q.pop_front());
            process_r(r_batch_q.pop_front());
          end
          while (spi_batch_q.size() > 0) begin
            void'(spi_ts_q.pop_front());
            process_spi(spi_batch_q.pop_front());
          end
          foreach (xip_spi_owner_q[i]) begin
            if (xip_spi_owner_q[i]) pending_reset_aborted_xip_spi++;
          end
          reset_shadows();
          cur_mode_state = QSPI_MODE_IDLE;
        end
        forever begin
          bit pre_ar_blocked;
          bit [1:0] pre_ctrl_pair;
          bit [1:0] pre_req_cmd, pre_req_addr, pre_req_data;
          bit       pre_quad;
          @(posedge cfg.clk_vif.clk);
          pre_ctrl_pair  = {csr.ctrl[1], csr.ctrl[0]};
          pre_req_cmd    = csr.xip_cfg[1:0];
          pre_req_addr   = csr.xip_cfg[3:2];
          pre_req_data   = csr.xip_cfg[5:4];
          pre_quad       = csr.ctrl[2];
          pre_ar_blocked = (axil_vif_h != null && cfg.clk_vif.rst_n === 1'b1 &&
                            axil_vif_h.arvalid === 1'b1 && !(csr.ctrl[0] && csr.ctrl[1]));
          #1ps;
          if (cfg.clk_vif.rst_n === 1'b1) begin
            if (pre_ar_blocked && pre_req_cmd != 2'b11 && pre_req_addr != 2'b11 && pre_req_data != 2'b11) begin
              cov_ctrl_enable_pair = pre_ctrl_pair;
              cov_req_cmd_lanes    = pre_req_cmd;
              cov_req_addr_lanes   = pre_req_addr;
              cov_req_data_lanes   = pre_req_data;
              cov_req_quad_en      = pre_quad;
              cg_xip_control_matrix.sample();
            end
            if ($realtime > last_reset_ts) pending_reset_aborted_xip_spi = 0;
            drain_batches();
          end
        end
      join
    end
  endtask

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    drain_batches();
    if (pending_xip_cfg_q.size() != 0 || xip_spi_owner_q.size() != 0 || pending_xip_spi_frames != 0) begin
      `uvm_error("XIP_COV_LEAK", $sformatf(
        "Unretired coverage ledgers at check_phase: cfg_q=%0d spi_owner_q=%0d pending_xip_spi=%0d",
        pending_xip_cfg_q.size(), xip_spi_owner_q.size(), pending_xip_spi_frames))
    end
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("XIP_COV_SUMMARY", $sformatf(
      "XIP coverage sampled: AR_cfg=%0d R_proto=%0d SPI_frame=%0d Aborts=%0d PendingSPI=%0d",
      ar_sampled, r_sampled, spi_sampled, abort_sampled, pending_xip_spi_frames), UVM_HIGH)
  endfunction

endclass : qspi_xip_cov

`endif // QSPI_XIP_COV_SV
