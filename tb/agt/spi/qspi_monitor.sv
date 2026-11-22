`ifndef QSPI_MONITOR_SV
`define QSPI_MONITOR_SV

class qspi_monitor extends uvm_monitor;
  `uvm_component_utils(qspi_monitor)

  virtual qspi_if qspi_vif;
  qspi_cfg        cfg;

  // Analysis port broadcasting observed physical SPI frames
  uvm_analysis_port #(qspi_transaction) ref_port;

  protected int unsigned sclk_edges_seen;

  function new(string name = "qspi_monitor", uvm_component parent = null);
    super.new(name, parent);
    ref_port = new("ref_port", this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db #(virtual qspi_if)::get(this, "", "qspi_vif", qspi_vif))
      `uvm_fatal("QSPI_MON_VIF", "Failed to retrieve virtual interface: qspi_vif")
    if (!uvm_config_db #(qspi_cfg)::get(this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal("QSPI_MON_CFG", "Failed to retrieve configuration: qspi_cfg")
  endfunction

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    forever begin
      @(negedge qspi_vif.qspi_cs_n);
      monitoring();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Low-Level 4-State Pin Sampling Primitives
  // ---------------------------------------------------------------------------
  // Active sampling edges strictly follow CS assertion: the CS_n assertion clock
  // edge itself is a launch edge (CS_n was still high pre-NBA) and never a sample edge.
  task count_physical_edges(qspi_cfg frame_cfg);
    bit sample_on_posedge = (frame_cfg.cpol == frame_cfg.cpha);
    while (qspi_vif.qspi_cs_n === 1'b0) begin
      if (sample_on_posedge)
        @(posedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
      else
        @(negedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
      #0;
      if (qspi_vif.qspi_cs_n === 1'b0)
        sclk_edges_seen++;
    end
  endtask

  task sample_edge(qspi_cfg frame_cfg);
    bit sample_on_posedge = (frame_cfg.cpol == frame_cfg.cpha);
    if (qspi_vif.qspi_cs_n !== 1'b0) begin
      return;
    end
    if (sample_on_posedge)
      @(posedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
    else
      @(negedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
  endtask

  // Reusable MSB-first 4-state byte sampler across 1, 2, or 4 lanes
  task sample_serial_byte(
    qspi_cfg           frame_cfg,
    output logic [7:0] data_byte,
    output bit         completed_byte,
    output bit         mid_byte_abort,
    output int unsigned edges_sampled,
    input  bit [1:0]   lanes,
    input  bit         use_miso_on_single = 1'b0
  );
    int step       = (lanes == 2'd2) ? 4 : (lanes == 2'd1) ? 2 : 1;
    data_byte      = 8'h00;
    completed_byte = 1'b0;
    mid_byte_abort = 1'b0;
    edges_sampled  = 0;

    for (int i = 7; i >= 0; i -= step) begin
      sample_edge(frame_cfg);
      if (qspi_vif.qspi_cs_n !== 1'b0) begin
        mid_byte_abort = (edges_sampled > 0);
        return;
      end
      edges_sampled++;
      case (lanes)
        2'd1: begin
          data_byte[i]   = qspi_vif.qspi_io1;
          data_byte[i-1] = qspi_vif.qspi_io0;
        end
        2'd2: begin
          data_byte[i]   = qspi_vif.qspi_io3;
          data_byte[i-1] = qspi_vif.qspi_io2;
          data_byte[i-2] = qspi_vif.qspi_io1;
          data_byte[i-3] = qspi_vif.qspi_io0;
        end
        default: begin
          data_byte[i]   = use_miso_on_single ? qspi_vif.qspi_io1 : qspi_vif.qspi_io0;
        end
      endcase
    end
    completed_byte = 1'b1;
  endtask

  // ---------------------------------------------------------------------------
  // Frame Capture Pipeline (Mode-Agnostic across PIO, DMA, LUT, and XIP)
  // ---------------------------------------------------------------------------
  task capture_address(qspi_cfg frame_cfg, qspi_transaction tr, output bit addr_done);
    logic [7:0]  byte_addr;
    bit          byte_ok, mid_abort;
    int unsigned edges_unused;
    int num_bytes = (frame_cfg.addr_bytes == 2'b00) ? 0 :
                    (frame_cfg.addr_bytes == 2'b10) ? 4 : 3;
    addr_done = 1'b0;
    tr.addr   = 32'h0;
    for (int count = 0; count < num_bytes; count++) begin
      sample_serial_byte(frame_cfg, byte_addr, byte_ok, mid_abort, edges_unused, frame_cfg.addr_lanes);
      if (!byte_ok) return;
      tr.addr = {tr.addr[23:0], byte_addr};
    end
    if (num_bytes == 3)      tr.addr &= 32'h00FF_FFFF;
    else if (num_bytes == 0) tr.addr  = 32'h0;
    addr_done = 1'b1;
  endtask

  task skip_dummy_cycles(qspi_cfg frame_cfg, output bit dummy_done);
    int total_dummy;
    total_dummy = int'(frame_cfg.dummy_cycles) + int'(frame_cfg.extra_dummy);
    dummy_done = 1'b0;
    for (int d = 0; d < total_dummy; d++) begin
      sample_edge(frame_cfg);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
    end
    dummy_done = 1'b1;
  endtask

  task capture_data(qspi_cfg frame_cfg, qspi_transaction tr, output bit mid_data_abort);
    logic [7:0]  byte_data;
    logic [7:0]  payload_q[$];
    time         byte_time_q[$];
    bit          byte_ok, mid_abort;
    int unsigned partial_edges;
    mid_data_abort    = 1'b0;
    tr.trailing_edges = 0;

    while (qspi_vif.qspi_cs_n === 1'b0) begin
      sample_serial_byte(frame_cfg, byte_data, byte_ok, mid_abort, partial_edges, frame_cfg.data_lanes, frame_cfg.dir);
      if (!byte_ok) begin
        tr.trailing_edges = partial_edges;
        mid_data_abort = (partial_edges > int'(frame_cfg.cs_delay));
        break;
      end
      payload_q.push_back(byte_data);
      byte_time_q.push_back($time);
      tr.data_completed_at = $time;
    end
    tr.data              = new[payload_q.size()];
    tr.byte_completed_at = new[byte_time_q.size()];
    foreach (payload_q[i])   tr.data[i]              = payload_q[i];
    foreach (byte_time_q[i]) tr.byte_completed_at[i] = byte_time_q[i];
  endtask

  task decode_frame(qspi_cfg frame_cfg, qspi_transaction tr);
    bit          phase_done, mid_abort;
    int unsigned hdr_edges;
    bit          has_dummy = (frame_cfg.dummy_cycles != 0 || frame_cfg.extra_dummy != 0);

    tr.data              = new[0];
    tr.byte_completed_at = new[0];
    tr.trailing_edges    = 0;
    tr.data_completed_at = 0;
    tr.cmd_lanes         = frame_cfg.cmd_lanes;
    tr.addr_lanes        = frame_cfg.addr_lanes;
    tr.data_lanes        = frame_cfg.data_lanes;
    tr.addr_bytes        = frame_cfg.addr_bytes;
    tr.mode_en           = frame_cfg.mode_en;
    tr.dir               = frame_cfg.dir;
    tr.end_phase         = 0;
    tr.aborted_early     = 1'b0;

    // 1. Opcode Phase
    sample_serial_byte(frame_cfg, tr.opcode, phase_done, mid_abort, hdr_edges, frame_cfg.cmd_lanes, 1'b0);
    if (!phase_done) begin
      tr.end_phase = 0; tr.aborted_early = 1'b1; tr.trailing_edges = hdr_edges;
      return;
    end
    if (qspi_vif.qspi_cs_n !== 1'b0) begin
      bit missing_hdr = (frame_cfg.addr_bytes != 0) || frame_cfg.mode_en || has_dummy;
      tr.end_phase = missing_hdr ? 1 : 5; tr.aborted_early = missing_hdr;
      tr.data_completed_at = $time;
      return;
    end

    // 2. Optional Address Phase
    if (frame_cfg.addr_bytes != 0) begin
      capture_address(frame_cfg, tr, phase_done);
      if (!phase_done) begin
        tr.end_phase = 1; tr.aborted_early = 1'b1;
        return;
      end
      if (qspi_vif.qspi_cs_n !== 1'b0) begin
        bit missing_hdr = frame_cfg.mode_en || has_dummy;
        tr.end_phase = missing_hdr ? 2 : 5; tr.aborted_early = missing_hdr;
        tr.data_completed_at = $time;
        return;
      end
    end

    // 3. Optional Mode Phase (transmitted on addr_lanes per Controller framing)
    if (frame_cfg.mode_en) begin
      sample_serial_byte(frame_cfg, tr.mode_bits, phase_done, mid_abort, hdr_edges, frame_cfg.addr_lanes);
      if (!phase_done) begin
        tr.end_phase = 2; tr.aborted_early = 1'b1; tr.trailing_edges = hdr_edges;
        return;
      end
      if (qspi_vif.qspi_cs_n !== 1'b0) begin
        tr.end_phase = has_dummy ? 3 : 5; tr.aborted_early = has_dummy;
        tr.data_completed_at = $time;
        return;
      end
    end

    // 4. Optional Dummy Phase
    if (has_dummy) begin
      skip_dummy_cycles(frame_cfg, phase_done);
      if (!phase_done) begin
        tr.end_phase = 3; tr.aborted_early = 1'b1;
        return;
      end
      if (qspi_vif.qspi_cs_n !== 1'b0) begin
        tr.end_phase = 5; tr.aborted_early = 1'b0;
        tr.data_completed_at = $time;
        return;
      end
    end

    tr.data_completed_at = $time;

    // 5. Data Phase (passive capture to CS deassertion)
    capture_data(frame_cfg, tr, mid_abort);
    if (!mid_abort && qspi_vif.qspi_cs_n === 1'b0) begin
      @(posedge qspi_vif.qspi_cs_n);
    end
    tr.end_phase = mid_abort ? 4 : 5;
    tr.aborted_early = mid_abort;
  endtask

  task monitoring();
    time             start_time = $time;
    // Snapshot configuration atomically at CS assertion so mid-frame CSR/test
    // updates cannot mutate the active frame's decode profile.
    qspi_cfg         frame_cfg = cfg.snapshot("mon_frame_cfg");
    qspi_transaction tr        = qspi_transaction::type_id::create("tr");

    tr.started_at   = start_time;
    sclk_edges_seen = 0;
    fork
      count_physical_edges(frame_cfg);
      decode_frame(frame_cfg, tr);
    join
    tr.sclk_edges_total = sclk_edges_seen;
    tr.completed_at     = $time;
    ref_port.write(tr);
  endtask

  virtual function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (qspi_vif != null && qspi_vif.qspi_cs_n === 1'b0) begin
      `uvm_error("QSPI_MON_HANGING", "Test ended with physical SPI CS_N held active low (hanging serial transfer)")
    end
  endfunction

endclass : qspi_monitor

`endif
