// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_dma_cov.sv
// Role   : Passive Functional Coverage for DMA Mode (Group 4 - Checkpoint 2)
// Spec   : VNCHIP_QSPI_Controller_Specification_Rev1.1 & Clarifications 1-5.5
// =============================================================================

`ifndef QSPI_DMA_COV_SV
`define QSPI_DMA_COV_SV

`uvm_analysis_imp_decl(_dma_cov_apb)
`uvm_analysis_imp_decl(_dma_cov_axi)
`uvm_analysis_imp_decl(_dma_cov_axi_resp)

class qspi_dma_cov extends uvm_component;
  `uvm_component_utils(qspi_dma_cov)

  qspi_env_cfg cfg;
  qspi_csr_shadow csr;

  uvm_analysis_imp_dma_cov_apb      #(qspi_apb_item_t,       qspi_dma_cov) apb_export;
  uvm_analysis_imp_dma_cov_axi      #(axi_slave_transaction, qspi_dma_cov) axi_export;
  uvm_analysis_imp_dma_cov_axi_resp #(axi_slave_resp_event,  qspi_dma_cov) axi_resp_export;

  // Reset-aware & PSTRB-aware shadow CSR state
  bit [4:0]  shadow_int_stat;
  bit        shadow_int_stat_valid;
  bit [2:0]  shadow_err_stat;
  bit        shadow_err_stat_valid;
  bit [2:0]  pending_w1c_mask;
  bit [2:0]  pending_w1c_before;
  bit [2:0]  pending_w1c_wdata;

  // Active DMA & Error/Recovery tracking
  bit        dma_in_flight;
  bit        active_dir;
  bit [7:0]  active_opcode;
  int        active_lanes;
  int        last_fault_source;     // 0:none, 1:timeout, 2:underrun, 3:overrun, 4:wresp_err, 5:rresp_err, 6:mid_burst_reset
  bit        last_recovery_method;  // 0:W1C clear, 1:hardware reset

  // 1. cg_dma_cfg: Direction, address stepping, single vs multi-word
  covergroup cg_dma_cfg with function sample(bit dir, bit incr_addr, bit [31:0] len);
    option.per_instance = 1;
    cp_dir: coverpoint dir { bins ram_to_qspi = {1'b0}; bins qspi_to_ram = {1'b1}; }
    cp_incr_addr: coverpoint incr_addr { bins fixed = {1'b0}; bins incrementing = {1'b1}; }
    cp_word_count: coverpoint (len <= 32'd4 ? 1'b0 : 1'b1) {
      bins single_word = {1'b0};
      bins multi_word  = {1'b1};
    }
    cross_dir_incr:      cross cp_dir, cp_incr_addr;
    cross_incr_word:     cross cp_incr_addr, cp_word_count;
    cross_dir_incr_word: cross cp_dir, cp_incr_addr, cp_word_count;
  endgroup

  // 2. cg_dma_len: DMA_LEN vs TX_FIFO/RX_FIFO depth (16B = 4 words) & 4B alignment
  covergroup cg_dma_len with function sample(bit dir, bit [31:0] len);
    option.per_instance = 1;
    cp_dir: coverpoint dir { bins tx = {1'b0}; bins rx = {1'b1}; }
    cp_len_category: coverpoint len {
      bins partial_word = {[32'd1  : 32'd3]};    // < 1 word (1..3B)
      bins single_word  = {32'd4};               // == 1 word (4B)
      bins below_fifo   = {[32'd5  : 32'd15]};   // < TX/RX_FIFO depth (5..15B)
      bins exact_fifo   = {32'd16};              // == TX/RX_FIFO depth (16B = 4 words)
      bins beyond_fifo  = {[32'd17 : 32'd64]};   // > TX/RX_FIFO depth (17..64B streaming)
      bins large_burst  = {[32'd65 : $]};        // Multi-page / large burst (>=65B)
    }
    cp_len_alignment: coverpoint (len % 4) {
      bins aligned_4B = {0};
      bins partial_1B = {1};
      bins partial_2B = {2};
      bins partial_3B = {3};
    }
    cross_dir_len:   cross cp_dir, cp_len_category;
    cross_dir_align: cross cp_dir, cp_len_alignment;
    cross_len_align: cross cp_len_category, cp_len_alignment {
      ignore_bins aligned_only_bins = binsof(cp_len_category) intersect {32'd4, 32'd16} &&
                                      binsof(cp_len_alignment) intersect {1, 2, 3};
      ignore_bins partial_word_aligned = binsof(cp_len_category) intersect {[32'd1 : 32'd3]} &&
                                         binsof(cp_len_alignment) intersect {0};
    }
  endgroup

  // 3. cg_axi_addr_phase: AXI burst length across Read and Write channels
  covergroup cg_axi_addr_phase with function sample(bit is_write, bit [7:0] len);
    option.per_instance = 1;
    cp_burst_len: coverpoint len {
      bins single_beat  = {8'd0};
      bins short_burst  = {[8'd1  : 8'd15]};
      bins medium_burst = {[8'd16 : 8'd63]};
      bins large_burst  = {[8'd64 : 8'd255]};
    }
    cp_axi_chan: coverpoint is_write { bins ar_read = {1'b0}; bins aw_write = {1'b1}; }
    cross_burst_chan: cross cp_burst_len, cp_axi_chan;
  endgroup

  // 4. cg_axi_data_phase: AXI write byte strobes (WSTRB) and LAST assertions
  covergroup cg_axi_data_phase with function sample(bit is_write, bit [3:0] strb, bit wlast, bit rlast);
    option.per_instance = 1;
    cp_wstrb: coverpoint strb iff (is_write) {
      bins full_word = {4'b1111};
      bins rem_1B    = {4'b0001};
      bins rem_2B    = {4'b0011};
      bins rem_3B    = {4'b0111};
    }
    cp_wlast: coverpoint wlast iff (is_write) { bins mid_beat = {1'b0}; bins last_beat = {1'b1}; }
    cp_rlast: coverpoint rlast iff (!is_write) { bins mid_beat = {1'b0}; bins last_beat = {1'b1}; }
    cross_wstrb_wlast: cross cp_wstrb, cp_wlast iff (is_write) {
      ignore_bins mid_residual = binsof(cp_wstrb) intersect {4'b0001, 4'b0011, 4'b0111} &&
                                 binsof(cp_wlast) intersect {1'b0};
    }
  endgroup

  // 5. cg_dma_status_int: Interrupt generation and masking logic
  covergroup cg_dma_status_int with function sample(
    bit irq_source, bit source_enabled, bit source_pending,
    bit any_enabled_pending, bit irq_pin
  );
    option.per_instance = 1;
    cp_irq_source:          coverpoint irq_source          { bins cmd_done = {1'b0}; bins dma_done = {1'b1}; }
    cp_source_enabled:      coverpoint source_enabled      { bins disabled = {1'b0}; bins enabled  = {1'b1}; }
    cp_source_pending:      coverpoint source_pending      { bins cleared  = {1'b0}; bins latched  = {1'b1}; }
    cp_any_enabled_pending: coverpoint any_enabled_pending { bins none     = {1'b0}; bins present  = {1'b1}; }
    cp_irq_pin:             coverpoint irq_pin             { bins low      = {1'b0}; bins high     = {1'b1}; }
    cross_source_en_pend: cross cp_irq_source, cp_source_enabled, cp_source_pending;
    cross_any_irq_pin:    cross cp_any_enabled_pending, cp_irq_pin {
      ignore_bins mismatched_irq = (binsof(cp_any_enabled_pending) intersect {1'b0} && binsof(cp_irq_pin) intersect {1'b1}) ||
                                   (binsof(cp_any_enabled_pending) intersect {1'b1} && binsof(cp_irq_pin) intersect {1'b0});
    }
  endgroup

  // 6. cg_dma_int_clear: W1C protocol on INT_STAT (0x010)
  covergroup cg_dma_int_clear with function sample(
    bit [1:0] bit_sel, bit stat_before, bit w1c_write, bit stat_after
  );
    option.per_instance = 1;
    cp_bit_sel:     coverpoint bit_sel     { bins cmd_done = {2'd0}; bins dma_done = {2'd1}; bins err = {2'd2}; }
    cp_stat_before: coverpoint stat_before { bins cleared  = {1'b0}; bins latched  = {1'b1}; }
    cp_w1c_write:   coverpoint w1c_write   { bins write_0  = {1'b0}; bins write_1  = {1'b1}; }
    cp_stat_after:  coverpoint stat_after  { bins cleared  = {1'b0}; bins latched  = {1'b1}; }
    cross_w1c: cross cp_bit_sel, cp_stat_before, cp_w1c_write;
  endgroup

  // 7. cg_dma_error_events: Fault injection and error reporting
  covergroup cg_dma_error_events with function sample(
    int fault_injection, bit int_err_latched, bit err_timeout, bit err_overrun, bit err_underrun
  );
    option.per_instance = 1;
    cp_fault_injection: coverpoint fault_injection {
      bins dma_timeout   = {1};
      bins fifo_underrun = {2};
      bins fifo_overrun  = {3};
      bins axi_wresp_err = {4};
      bins axi_rresp_err = {5};
    }
    cp_int_err_latched: coverpoint int_err_latched { bins latched = {1'b1}; }
    cp_err_timeout:     coverpoint err_timeout     { bins clear = {1'b0}; bins set = {1'b1}; }
    cp_err_overrun:     coverpoint err_overrun     { bins clear = {1'b0}; bins set = {1'b1}; }
    cp_err_underrun:    coverpoint err_underrun    { bins clear = {1'b0}; bins set = {1'b1}; }
    cross_error_reporting: cross cp_fault_injection, cp_int_err_latched;
  endgroup

  // 8. cg_dma_qspi_lane_modes: Completed DMA across QSPI opcodes and lane widths
  covergroup cg_dma_qspi_lane_modes with function sample(bit dir, bit [7:0] opcode, int lane_width);
    option.per_instance = 1;
    cp_dma_dir: coverpoint dir { bins ram_to_qspi = {1'b0}; bins qspi_to_ram = {1'b1}; }
    cp_opcode: coverpoint opcode {
      bins Normal_03h       = {8'h03};
      bins Fast_0Bh         = {8'h0B};
      bins DualOut_3Bh      = {8'h3B};
      bins QuadOut_6Bh      = {8'h6B};
      bins QuadIO_EBh       = {8'hEB};
      bins PageProg_02h     = {8'h02};
      bins QuadPageProg_32h = {8'h32};
    }
    cp_lane_width: coverpoint lane_width { bins single = {1}; bins dual = {2}; bins quad = {4}; }
    cross_dir_opcode_lane: cross cp_dma_dir, cp_opcode, cp_lane_width {
      ignore_bins dir0_reads      = binsof(cp_dma_dir) intersect {1'b0} &&
                                    binsof(cp_opcode)  intersect {8'h03, 8'h0B, 8'h3B, 8'h6B, 8'hEB};
      ignore_bins dir1_programs   = binsof(cp_dma_dir) intersect {1'b1} &&
                                    binsof(cp_opcode)  intersect {8'h02, 8'h32};
      ignore_bins single_lane_ops = binsof(cp_opcode) intersect {8'h03, 8'h0B, 8'h02} &&
                                    binsof(cp_lane_width) intersect {2, 4};
      ignore_bins dual_lane_ops   = binsof(cp_opcode) intersect {8'h3B} &&
                                    binsof(cp_lane_width) intersect {1, 4};
      ignore_bins quad_lane_ops   = binsof(cp_opcode) intersect {8'h6B, 8'hEB, 8'h32} &&
                                    binsof(cp_lane_width) intersect {1, 2};
    }
  endgroup

  // 9. cg_axi_handshake_delays: AXI slave backpressure and response latency
  covergroup cg_axi_handshake_delays with function sample(
    bit is_write, int unsigned aw_delay, int unsigned w_delay,
    int unsigned ar_delay, int unsigned b_delay, int unsigned r_delay
  );
    option.per_instance = 1;

    cp_awready_delay: coverpoint aw_delay iff (is_write)  { bins zero = {0}; bins short_d = {[1:5]}; bins med_long = {[6:50]}; }
    cp_wready_delay:  coverpoint w_delay  iff (is_write)  { bins zero = {0}; bins short_d = {[1:5]}; bins med_long = {[6:50]}; }
    cp_arready_delay: coverpoint ar_delay iff (!is_write) { bins zero = {0}; bins short_d = {[1:5]}; bins med_long = {[6:50]}; }
    cp_bvalid_delay:  coverpoint b_delay  iff (is_write)  { bins zero = {0}; bins delayed = {[1:50]}; }
    cp_rvalid_delay:  coverpoint r_delay  iff (!is_write) { bins zero = {0}; bins delayed = {[1:50]}; }
  endgroup

  // 10. cg_dma_addr_boundary: 4KB page boundary relationship
  covergroup cg_dma_addr_boundary with function sample(bit dir, bit incr_addr, bit [31:0] addr, bit [31:0] len);
    option.per_instance = 1;
    cp_dma_dir: coverpoint dir iff (incr_addr) { bins tx = {1'b0}; bins rx = {1'b1}; }
    cp_4kb_cross: coverpoint (
      (((64'(addr) + 64'(len) - 64'd1) >> 12) == (64'(addr) >> 12)) ?
        ((((64'(addr) + 64'(len)) & 64'hFFF) == 64'd0 && len > 0) ? 1 : 0) : 2
    ) iff (incr_addr) {
      bins within_4KB           = {0};
      bins ends_at_boundary     = {1};
      bins crosses_4KB_boundary = {2};
    }
    cross_dir_boundary: cross cp_dma_dir, cp_4kb_cross;
  endgroup

  // 11. cg_dma_cmd_source: Direct CSR registers vs Command LUT (Banks 0..3)
  covergroup cg_dma_cmd_source with function sample(bit lut_en, bit [1:0] lut_index, bit dir);
    option.per_instance = 1;
    cp_lut_en:    coverpoint lut_en    { bins direct_CSR = {1'b0}; bins command_LUT = {1'b1}; }
    cp_lut_index: coverpoint lut_index { bins bank0 = {2'd0}; bins bank1 = {2'd1}; bins bank2 = {2'd2}; bins bank3 = {2'd3}; }
    cp_dma_dir:   coverpoint dir       { bins ram_to_qspi = {1'b0}; bins qspi_to_ram = {1'b1}; }
    cross_lut_en_dir:  cross cp_lut_en, cp_dma_dir;
    cross_lut_idx_dir: cross cp_lut_index, cp_dma_dir iff (lut_en == 1'b1);
  endgroup

  // 12. cg_dma_protocol_timing: CLK_DIV (0..7), SPI Modes (0..3), CS_DELAY (0..3)
  covergroup cg_dma_protocol_timing with function sample(bit [2:0] clk_div, bit [1:0] spi_mode, bit [1:0] cs_delay);
    option.per_instance = 1;
    cp_clk_div:     coverpoint clk_div { bins divs[] = {[0:7]}; }
    cp_clk_div_0_1: coverpoint clk_div iff (clk_div inside {3'd0, 3'd1}) { bins bypass_0 = {3'd0}; bins divided_1 = {3'd1}; }
    cp_spi_mode:    coverpoint spi_mode { bins modes[] = {[0:3]}; }
    cp_cs_delay:    coverpoint cs_delay { bins delays[] = {[0:3]}; }
    cross_div_mode: cross cp_clk_div,     cp_spi_mode;
    cross_div01_cs: cross cp_clk_div_0_1, cp_cs_delay;
    cross_mode_cs:  cross cp_spi_mode,    cp_cs_delay;
  endgroup

  // 13. cg_dma_axi_response: AXI BRESP / RRESP (OKAY, SLVERR, DECERR)
  covergroup cg_dma_axi_response with function sample(bit is_write, bit [1:0] resp_type);
    option.per_instance = 1;
    cp_axi_chan:  coverpoint is_write  { bins write_bresp = {1'b1}; bins read_rresp = {1'b0}; }
    cp_resp_type: coverpoint resp_type { bins okay = {2'b00}; bins slverr = {2'b10}; bins decerr = {2'b11}; }
    cross_chan_resp: cross cp_axi_chan, cp_resp_type;
  endgroup

  // 14. cg_dma_recovery: Return to IDLE and execute next legal command after error/reset
  covergroup cg_dma_recovery with function sample(int recovery_source, bit recovery_method);
    option.per_instance = 1;
    cp_recovery_source: coverpoint recovery_source {
      bins dma_timeout     = {1};
      bins fifo_error      = {2, 3};
      bins axi_wresp_err   = {4};
      bins axi_rresp_err   = {5};
      bins mid_burst_reset = {6};
    }
    cp_recovery_method: coverpoint recovery_method {
      bins status_clear_w1c = {1'b0};
      bins hardware_reset   = {1'b1};
    }
    cross_recovery: cross cp_recovery_source, cp_recovery_method;
  endgroup

  function new(string name = "qspi_dma_cov", uvm_component parent = null);
    super.new(name, parent);
    csr=new("csr");
    apb_export      = new("apb_export", this);
    axi_export      = new("axi_export", this);
    axi_resp_export = new("axi_resp_export", this);

    cg_dma_cfg              = new();
    cg_dma_len              = new();
    cg_axi_addr_phase       = new();
    cg_axi_data_phase       = new();
    cg_dma_status_int       = new();
    cg_dma_int_clear        = new();
    cg_dma_error_events     = new();
    cg_dma_qspi_lane_modes  = new();
    cg_axi_handshake_delays = new();
    cg_dma_addr_boundary    = new();
    cg_dma_cmd_source       = new();
    cg_dma_protocol_timing  = new();
    cg_dma_axi_response     = new();
    cg_dma_recovery         = new();
    reset_shadows();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null && !uvm_config_db#(qspi_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("QSPI_DMA_COV", "Missing qspi_env_cfg")
    if (cfg.clk_vif == null)
      `uvm_fatal("QSPI_DMA_COV", "Missing clk_vif in qspi_env_cfg")
  endfunction

  function void reset_shadows();
    csr.reset();
    shadow_int_stat=0;
    shadow_int_stat_valid = 0;
    shadow_err_stat       = 0;
    shadow_err_stat_valid = 0;
    pending_w1c_mask      = 0;
    pending_w1c_before    = 0;
    pending_w1c_wdata     = 0;
    dma_in_flight   = 0;
  endfunction

  task run_phase(uvm_phase phase);
    last_fault_source    = 0;
    last_recovery_method = 0;
    if (cfg == null || cfg.clk_vif == null) return;
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      if (dma_in_flight && last_fault_source == 0)
        last_fault_source = 6; // Mid-burst reset
      if (last_fault_source != 0)
        last_recovery_method = 1'b1; // Hardware reset recovery
      reset_shadows();
    end
  endtask

  virtual function void write_dma_cov_apb(qspi_apb_item_t tr);
    int lut_idx;
    bit triggered;
    if (tr == null || cfg == null || cfg.clk_vif == null || tr.reset_abort || tr.slverr !== 1'b0) return;
    if (cfg.clk_vif.rst_n !== 1'b1) return;
    if ($isunknown({tr.addr, tr.write, tr.strb, tr.slverr})) return;

    lut_idx = int'(csr.lut_ctrl[3:2]);

    if (tr.write) begin
      for (int b = 0; b < 4; b++) begin
        if (tr.strb[b] === 1'b1 && $isunknown(tr.wdata[8*b +: 8])) return;
      end
      triggered=csr.apply_apb_write(tr);
      case (tr.addr)
        QSPI_REG_INT_STAT: begin
          if (tr.strb[0]) begin
            if (shadow_int_stat_valid) begin
              for (int b = 0; b < 3; b++) begin
                pending_w1c_mask[b]   = 1'b1; // Observe write-zero preservation as well as clears.
                pending_w1c_before[b] = shadow_int_stat[b];
                pending_w1c_wdata[b]  = tr.wdata[b];
              end
            end
            shadow_int_stat=qspi_csr_shadow::apply_w1c_mask(shadow_int_stat,tr.wdata,tr.strb);
            shadow_int_stat_valid=0;
            if (tr.wdata[2] && last_fault_source != 0)
              last_recovery_method = 1'b0;
          end
        end
        QSPI_REG_CTRL: begin
          if (triggered && tr.wdata[9]) begin
            bit use_lut      = csr.lut_ctrl[0];
            bit [31:0] cfg_w = use_lut ? csr.lut_cfg[lut_idx] : csr.cmd_cfg;
            bit [31:0] op_w  = use_lut ? csr.lut_op[lut_idx]  : csr.cmd_op;
            bit dma_dir      = csr.dma_cfg[4];
            bit incr_addr    = csr.dma_cfg[5];
            bit cmd_dir      = cfg_w[13];
            bit [1:0] dlanes = cfg_w[5:4];
            // Correct SPI mode encoding: {CPOL (bit 3), CPHA (bit 4)}
            bit [1:0] mode   = {csr.ctrl[3], csr.ctrl[4]};

            active_dir    = dma_dir;
            active_opcode = op_w[7:0];

            active_lanes  = qspi_eff_lanes(dlanes,csr.ctrl[2]);
            dma_in_flight = 1'b1;

            // Sample valid configuration triggers meeting Spec Clarification 5.2 & 5.5
            if (csr.dma_len > 0 && csr.dma_len == csr.cmd_len &&
                dma_dir == cmd_dir && csr.dma_addr[1:0] == 2'b00) begin
              cg_dma_cfg.sample(dma_dir, incr_addr, csr.dma_len);
              cg_dma_len.sample(dma_dir, csr.dma_len);
              if (incr_addr)
                cg_dma_addr_boundary.sample(dma_dir, incr_addr, csr.dma_addr, csr.dma_len);
              cg_dma_cmd_source.sample(use_lut, csr.lut_ctrl[3:2], dma_dir);
              cg_dma_protocol_timing.sample(csr.clk_div[2:0], mode, csr.cs_ctrl[3:2]);
            end
          end
        end
      endcase
    end else begin
      // APB Read
      if ($isunknown(tr.rdata)) return;
      case (tr.addr)
        QSPI_REG_INT_STAT: begin
          bit any_en_pend;
          for (int b = 0; b < 3; b++) begin
            if (pending_w1c_mask[b]) begin
              cg_dma_int_clear.sample(2'(b), pending_w1c_before[b], pending_w1c_wdata[b], tr.rdata[b]);
              pending_w1c_mask[b] = 1'b0;
            end
          end
          shadow_int_stat = tr.rdata[4:0];
          shadow_int_stat_valid = 1'b1;
          any_en_pend = |(csr.int_en[4:0] & tr.rdata[4:0]);
          if (!$isunknown(cfg.clk_vif.irq)) begin
            cg_dma_status_int.sample(1'b1, csr.int_en[1], tr.rdata[1],
                                     any_en_pend, cfg.clk_vif.irq);
            cg_dma_status_int.sample(1'b0, csr.int_en[0], tr.rdata[0],
                                     any_en_pend, cfg.clk_vif.irq);
          end

          // Sample error reporting using real observed INT_STAT.ERR and ERR_STAT bits
          if (last_fault_source != 0 && tr.rdata[2] === 1'b1) begin
            bit err_to, err_ov, err_un;
            err_to = shadow_err_stat_valid ? shadow_err_stat[0] : 1'b0;
            err_ov = shadow_err_stat_valid ? shadow_err_stat[1] : 1'b0;
            err_un = shadow_err_stat_valid ? shadow_err_stat[2] : 1'b0;
            if ((last_fault_source inside {4, 5}) || shadow_err_stat_valid) begin
              cg_dma_error_events.sample(last_fault_source, 1'b1, err_to, err_ov, err_un);
            end
          end

          // Sample lane modes & recovery strictly upon full DMA+QSPI completion (DMA_DONE & CMD_DONE & !ERR)
          if (tr.rdata[1] && tr.rdata[0] && !tr.rdata[2] && dma_in_flight) begin
            cg_dma_qspi_lane_modes.sample(active_dir, active_opcode, active_lanes);
            if (last_fault_source != 0) begin
              cg_dma_recovery.sample(last_fault_source, last_recovery_method);
              last_fault_source = 0;
            end
            dma_in_flight = 1'b0;
          end
        end
        QSPI_REG_ERR_STAT: begin
          shadow_err_stat = tr.rdata[2:0];
          shadow_err_stat_valid = 1'b1;
          if (tr.rdata[0])      last_fault_source = 1; // Timeout
          else if (tr.rdata[2]) last_fault_source = 2; // Underrun
          else if (tr.rdata[1]) last_fault_source = 3; // Overrun
          if ((tr.rdata[2:0] != 3'b0) && shadow_int_stat_valid && shadow_int_stat[2]) begin
            cg_dma_error_events.sample(last_fault_source, shadow_int_stat[2],
                                       tr.rdata[0], tr.rdata[1], tr.rdata[2]);
          end
        end
      endcase
    end
  endfunction

  virtual function void write_dma_cov_axi(axi_slave_transaction tr);
    int total_beats;
    if (tr == null || cfg == null || cfg.clk_vif == null || cfg.clk_vif.rst_n !== 1'b1) return;
    if ($isunknown({tr.is_write, tr.len})) return;

    cg_axi_addr_phase.sample(tr.is_write, tr.len);
    cg_axi_handshake_delays.sample(tr.is_write, tr.awready_delay, tr.wready_delay,
                                   tr.arready_delay, tr.bvalid_delay, tr.rvalid_delay);

    if (tr.is_write) begin
      foreach (tr.wstrb[i]) begin
        bit is_last;
        if ($isunknown(tr.wstrb[i])) continue;
        is_last = (i == tr.wstrb.size() - 1) && (tr.wlast_seen === 1'b1);
        cg_axi_data_phase.sample(1'b1, tr.wstrb[i], is_last, 1'b0);
      end
      if (!$isunknown(tr.bresp)) begin
        cg_dma_axi_response.sample(1'b1, tr.bresp);
        if (tr.bresp != 2'b00) begin
          last_fault_source = 4; // AXI WRESP error (will sample cg_dma_error_events when INT_STAT is read)
        end
      end
    end else begin
      total_beats = tr.rresp.size();
      for (int i = 0; i < total_beats; i++) begin
        bit is_last;
        bit [1:0] beat_resp;
        if ($isunknown(tr.rresp[i])) continue;
        is_last   = (i == total_beats - 1) && (tr.rlast_seen === 1'b1);
        beat_resp = tr.rresp[i];
        cg_axi_data_phase.sample(1'b0, 4'b0, 1'b0, is_last);
        cg_dma_axi_response.sample(1'b0, beat_resp);
        if (beat_resp != 2'b00) begin
          last_fault_source = 5; // AXI RRESP error (will sample cg_dma_error_events when INT_STAT is read)
        end
      end
    end
  endfunction

  virtual function void write_dma_cov_axi_resp(axi_slave_resp_event evt);
    if (evt == null || cfg == null || cfg.clk_vif == null || cfg.clk_vif.rst_n !== 1'b1) return;
    if ($isunknown({evt.is_write, evt.resp}) || evt.resp == 2'b00) return;
    cg_dma_axi_response.sample(evt.is_write, evt.resp);
    last_fault_source = evt.is_write ? 4 : 5;
  endfunction

  virtual function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_DMA_COV", $sformatf(
      "DMA Functional Coverage: cfg=%.2f%% len=%.2f%% addr_phase=%.2f%% data_phase=%.2f%% int=%.2f%% w1c=%.2f%% err=%.2f%% lane=%.2f%% delay=%.2f%% boundary=%.2f%% src=%.2f%% timing=%.2f%% resp=%.2f%% recovery=%.2f%%",
      cg_dma_cfg.get_inst_coverage(),
      cg_dma_len.get_inst_coverage(),
      cg_axi_addr_phase.get_inst_coverage(),
      cg_axi_data_phase.get_inst_coverage(),
      cg_dma_status_int.get_inst_coverage(),
      cg_dma_int_clear.get_inst_coverage(),
      cg_dma_error_events.get_inst_coverage(),
      cg_dma_qspi_lane_modes.get_inst_coverage(),
      cg_axi_handshake_delays.get_inst_coverage(),
      cg_dma_addr_boundary.get_inst_coverage(),
      cg_dma_cmd_source.get_inst_coverage(),
      cg_dma_protocol_timing.get_inst_coverage(),
      cg_dma_axi_response.get_inst_coverage(),
      cg_dma_recovery.get_inst_coverage()
    ), UVM_HIGH)
  endfunction
endclass : qspi_dma_cov

`endif // QSPI_DMA_COV_SV
