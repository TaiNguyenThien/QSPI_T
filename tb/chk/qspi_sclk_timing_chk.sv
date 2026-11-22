`ifndef QSPI_SCLK_TIMING_CHK_SV
`define QSPI_SCLK_TIMING_CHK_SV

// Observes the DUT clocks; never drives an interface. Consecutive SCLK
// rising edges must be 2^CLK_DIV system clock cycles apart, including the
// CLK_DIV=0 bypass (one system clock period).
class qspi_sclk_timing_chk extends uvm_component;
  `uvm_component_utils(qspi_sclk_timing_chk)
  typedef qspi_apb_item_t apb_item_t;
  uvm_analysis_imp #(apb_item_t, qspi_sclk_timing_chk) apb_imp;
  uvm_analysis_imp_sclk_spi #(qspi_transaction, qspi_sclk_timing_chk) spi_imp;
  qspi_csr_shadow csr;
  bit indirect_dma;
  qspi_mode_e active_mode;
  qspi_env_cfg cfg; // Assigned by the parent before child build.
  longint unsigned core_edges, previous_sclk_edge;
  bit cs_active, has_previous;
  bit [2:0] exp_active_clk_div;
  bit active_cpol, active_cpha;
  bit [2:0] exp_clk_div;
  bit programmed_cpol, programmed_cpha;
  bit programmed_quad_en, programmed_enable, programmed_xip_en;
  bit programmed_cs_auto, programmed_cs_level;
  bit [1:0] programmed_cs_delay;
  bit active_quad_en, active_cs_auto, active_cs_level;
  bit [1:0] active_cs_delay;
  bit active_frame_reset_or_err;
  string active_profile_key;
  time cs_delay_min_tail[string];
  time cs_delay_max_tail[string];
  bit has_first_edge, has_first_sample_edge;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    apb_imp = new("apb_imp", this);
    spi_imp = new("spi_imp", this);
    csr = new("csr");
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null || cfg.clk_vif == null || cfg.flash_vif == null)
      `uvm_fatal("QSPI_SCLK_CFG", "Missing qspi_env_cfg / clk_vif / flash_vif")
  endfunction

  protected function void sync_programmed();
    exp_clk_div=csr.clk_div[2:0];
    programmed_enable=csr.ctrl[0]; programmed_xip_en=csr.ctrl[1];
    programmed_quad_en=csr.ctrl[2]; programmed_cpol=csr.ctrl[3]; programmed_cpha=csr.ctrl[4];
    programmed_cs_auto=csr.cs_ctrl[0]; programmed_cs_level=csr.cs_ctrl[1];
    programmed_cs_delay=csr.cs_ctrl[3:2];
  endfunction

  protected function void reset_apb_shadows();
    csr.reset();
    indirect_dma=0;
    sync_programmed();
  endfunction

  function void write(apb_item_t t);
    bit triggered;
    if (cfg == null || cfg.clk_vif == null) return;
    if (t == null || t.reset_abort || t.slverr !== 1'b0 || cfg.clk_vif.rst_n !== 1'b1) return;
    if ($isunknown({t.addr,t.write,t.strb})) begin
      `uvm_error("QSPI_SCLK_XZ", "Unknown APB controls")
      return;
    end
    if (t.write === 1'b0) begin
      if ((t.addr == QSPI_REG_ERR_STAT && !$isunknown(t.rdata[2:0]) && |t.rdata[2:0]) ||
          (t.addr == QSPI_REG_INT_STAT && t.rdata[2] === 1'b1))
        active_frame_reset_or_err=1;
      return;
    end
    for (int lane=0;lane<4;lane++)
      if (t.strb[lane] === 1'b1 && $isunknown(t.wdata[8*lane +: 8])) begin
        `uvm_error("QSPI_SCLK_XZ", "Unknown enabled APB write byte")
        return;
      end
    triggered=csr.apply_apb_write(t);
    if (triggered) indirect_dma=t.wdata[9];
    sync_programmed();
    if (cs_active && exp_clk_div != exp_active_clk_div)
      `uvm_error("QSPI_SCLK_PROGRAM", "Clock divider changed while CS active")
    if (cs_active && (programmed_cpol != active_cpol || programmed_cpha != active_cpha))
      `uvm_error("QSPI_SCLK_PROGRAM", "SPI mode changed while CS active")
  endfunction

  // Compare only the measured post-payload STOP_CS tail for a common clock/mode.
  function void write_sclk_spi(qspi_transaction tr);
    time tail;
    string delay_key, other_key;
    if (tr==null || cfg.clk_vif.rst_n !== 1'b1 || tr.aborted_early ||
        active_frame_reset_or_err || !active_cs_auto ||
        tr.completed_at <= tr.data_completed_at) return;
    tail=tr.completed_at-tr.data_completed_at;
    delay_key=$sformatf("%s|d%0d",active_profile_key,active_cs_delay);
    for (int d=0;d<4;d++) begin
      if (d==int'(active_cs_delay)) continue;
      other_key=$sformatf("%s|d%0d",active_profile_key,d);
      if (!cs_delay_min_tail.exists(other_key)) continue;
      if ((d<int'(active_cs_delay) && cs_delay_max_tail[other_key]>=tail) ||
          (d>int'(active_cs_delay) && cs_delay_min_tail[other_key]<=tail))
        `uvm_error("QSPI_CS_DELAY_MONO", $sformatf(
          "CS_DELAY=%0d STOP_CS tail=%0t is not monotonic against delay=%0d for %s",
          active_cs_delay,tail,d,active_profile_key))
    end
    if (!cs_delay_min_tail.exists(delay_key) || tail<cs_delay_min_tail[delay_key])
      cs_delay_min_tail[delay_key]=tail;
    if (!cs_delay_max_tail.exists(delay_key) || tail>cs_delay_max_tail[delay_key])
      cs_delay_max_tail[delay_key]=tail;
  endfunction

  task automatic count_core_clock();
    forever begin
      @(posedge cfg.clk_vif.clk or negedge cfg.clk_vif.rst_n);
      if (cfg.clk_vif.rst_n !== 1'b1) begin
        core_edges = 0;
        active_frame_reset_or_err = 1'b1;
        reset_apb_shadows();
      end
      else core_edges++;
    end
  endtask

  task automatic track_cs();
    forever begin
      @(negedge cfg.flash_vif.qspi_cs_n or negedge cfg.clk_vif.rst_n);
      if (cfg.clk_vif.rst_n !== 1'b1) begin
        cs_active = 0;
        has_previous = 0;
        has_first_edge = 0;
        has_first_sample_edge = 0;
        active_frame_reset_or_err = 1'b1;
        continue;
      end
      if (cfg.flash_vif.qspi_cs_n !== 1'b0) begin
        `uvm_error("QSPI_SCLK_XZ", "Unknown (X/Z) transition observed on QSPI CS_N")
        cs_active = 0;
        has_previous = 0;
        continue;
      end
      cs_active = 1;
      // Golden clock & pin mode come from APB request history, independent of flash responder.
      exp_active_clk_div        = exp_clk_div;
      active_cpol               = programmed_cpol;
      active_cpha               = programmed_cpha;
      active_quad_en            = programmed_quad_en;
      active_cs_auto            = programmed_cs_auto;
      active_cs_level           = programmed_cs_level;
      active_cs_delay           = programmed_cs_delay;
      active_frame_reset_or_err = 1'b0;
      active_mode=programmed_xip_en ? QSPI_MODE_XIP : indirect_dma ? QSPI_MODE_DMA : QSPI_MODE_PIO;
      active_profile_key=$sformatf("%0d_%0d_%0b_%0b",active_mode,exp_active_clk_div,active_cpol,active_cpha);
      has_previous = 0;
      has_first_edge = 0;
      has_first_sample_edge = 0;
      @(posedge cfg.flash_vif.qspi_cs_n or negedge cfg.clk_vif.rst_n);
      if (cfg.clk_vif.rst_n === 1'b1 && cfg.flash_vif.qspi_cs_n !== 1'b1)
        `uvm_error("QSPI_SCLK_XZ", "Unknown (X/Z) deassertion observed on QSPI CS_N")
      cs_active = 0;
      has_previous = 0;
    end
  endtask

  // Observe leading edge polarity (CPOL), sample-phase alignment (CPHA),
  // and passive SVA_XIP_05 (IO[3:2] tristate when QUAD_EN=0 and Flash not driving).
  task automatic check_leading_edge();
    bit   sample_is_posedge, cs_was_low;
    logic sampled_sclk, sampled_io0;
    forever begin
      @(posedge cfg.flash_vif.qspi_sclk or negedge cfg.flash_vif.qspi_sclk);
      sampled_sclk = cfg.flash_vif.qspi_sclk;
      sampled_io0  = cfg.flash_vif.qspi_io0;
      #0; // Let coincident track_cs() NBA wakeups settle cs_active/active_cpol/has_first_edge.
      cs_was_low = (cs_active && cfg.flash_vif.qspi_cs_n === 1'b0);
      if (cfg.clk_vif.rst_n !== 1'b1) continue;
      if ($isunknown(sampled_sclk)) begin
        `uvm_error("QSPI_SCLK_XZ", "Unknown (X/Z) transition on QSPI SCLK")
        continue;
      end
      sample_is_posedge = (active_cpol == active_cpha);
      if (cs_was_low) begin
        if (!has_first_sample_edge && (sampled_sclk === sample_is_posedge)) begin
          has_first_sample_edge = 1;
          if (active_cpha && !has_first_edge)
            `uvm_error("QSPI_SCLK_CPHA", "CPHA=1 sampled before a leading launch edge occurred")
          if ($isunknown(sampled_io0))
            `uvm_error("QSPI_SCLK_CPHA", "First serial command bit on IO0 is X/Z at first sample edge")
        end
      end
      #1ps; // qspi_chk_pkg precision is 1ps; allow edge updates to settle.
      if (cs_was_low && cs_active && cfg.clk_vif.rst_n === 1'b1 && cfg.flash_vif.qspi_cs_n === 1'b0) begin
        if (!active_quad_en) begin
          if (cfg.flash_vif.flash_drive_en[2] === 1'b0 && cfg.flash_vif.qspi_io2 !== 1'bz)
            `uvm_error("SVA_XIP_05", $sformatf(
              "qspi_io2=%b driven while QUAD_EN=0 and flash_drive_en[2]=0", cfg.flash_vif.qspi_io2))
          if (cfg.flash_vif.flash_drive_en[3] === 1'b0 && cfg.flash_vif.qspi_io3 !== 1'bz)
            `uvm_error("SVA_XIP_05", $sformatf(
              "qspi_io3=%b driven while QUAD_EN=0 and flash_drive_en[3]=0", cfg.flash_vif.qspi_io3))
        end
        if (!has_first_edge) begin
          has_first_edge = 1;
          if (sampled_sclk !== !active_cpol)
            `uvm_error("QSPI_SCLK_CPOL", "First active SCLK edge has the wrong leading polarity for CPOL")
        end
      end
    end
  endtask

  task automatic check_period();
    longint unsigned act_cycles, exp_cycles;
    forever begin
      @(posedge cfg.flash_vif.qspi_sclk);
      if (cfg.clk_vif.rst_n !== 1'b1 || $isunknown(cfg.flash_vif.qspi_sclk)) continue;
      #1ps; // One package precision tick lets coincident CLK/SCLK counters settle.
      if (!cs_active || cfg.clk_vif.rst_n !== 1'b1 ||
          cfg.flash_vif.qspi_cs_n !== 1'b0) continue;
      if (has_previous) begin
        act_cycles = core_edges - previous_sclk_edge;
        exp_cycles = 64'(1) << exp_active_clk_div;
        if (act_cycles != exp_cycles)
          `uvm_error("QSPI_SCLK_DIV", $sformatf(
            "CLK_DIV=%0d expects %0d CLK cycles/SCLK, observed %0d",
            exp_active_clk_div, exp_cycles, act_cycles))
      end
      previous_sclk_edge = core_edges;
      has_previous = 1;
    end
  endtask

  task run_phase(uvm_phase phase);
    if (cfg == null || cfg.clk_vif == null || cfg.flash_vif == null)
      `uvm_fatal("QSPI_SCLK_CFG", "Missing qspi_env_cfg / clk_vif / flash_vif in run_phase")
    reset_apb_shadows();
    fork
      count_core_clock();
      track_cs();
      check_period();
      check_leading_edge();
    join
  endtask
endclass : qspi_sclk_timing_chk
`endif
