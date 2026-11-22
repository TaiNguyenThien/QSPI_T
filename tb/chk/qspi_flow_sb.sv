`ifndef QSPI_FLOW_SB_SV
`define QSPI_FLOW_SB_SV

// Private serial observations and command predictions belong to this checker.
// Cross-layer intent and result items are imported from qspi_cfg_pkg.
// Checker-owned serial observation. A producer must supply measured values.
// Do not fill edge/termination fields from expected cfg or manufacture RX bytes.
class qspi_serial_item extends uvm_sequence_item;
  `uvm_object_utils(qspi_serial_item)
  logic [7:0] opcode, mode_value;
  logic [31:0] address;
  logic [7:0] tx_data[$], rx_data[$];
  bit incomplete;
  // Decode widths/direction are profile assumptions. Edge counts and
  // termination metadata come from the physical monitor, never from expected cfg.
  bit has_edge_count=1, has_termination_metadata=1;
  int unsigned end_phase;
  longint unsigned sample_edges;
  time completed_at;

  function new(string name="qspi_serial_item");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    qspi_serial_item other;
    if (!$cast(other,rhs)) begin
      `uvm_fatal("QSPI_SERIAL_COPY","Expected qspi_serial_item")
      return;
    end
    super.do_copy(rhs);
    opcode=other.opcode;
    mode_value=other.mode_value;
    address=other.address;
    tx_data=other.tx_data;
    rx_data=other.rx_data;
    incomplete=other.incomplete;
    has_edge_count=other.has_edge_count;
    has_termination_metadata=other.has_termination_metadata;
    end_phase=other.end_phase;
    sample_edges=other.sample_edges;
    completed_at=other.completed_at;
  endfunction
endclass : qspi_serial_item


// A prediction from software requests and the specification. No DUT outputs,
// virtual interfaces, or observed outcomes live in this object.
class qspi_cmd_exp extends uvm_object;
  `uvm_object_utils(qspi_cmd_exp)
  logic [7:0] opcode, mode_value;
  logic [31:0] address, payload_len;
  int unsigned cmd_lanes, addr_lanes, data_lanes, addr_bytes;
  int unsigned mode_lanes;
  int unsigned dummy_cycles, dummy_base, dummy_extra;
  bit use_lut;
  bit [1:0] lut_index;
  bit [1:0] cs_delay;
  bit mode_enable, read_direction, cpol, cpha;
  bit [2:0] clk_div;
  bit expect_error;
  bit [2:0] required_err_bits;
  bit [2:0] any_err_bits;
  bit allow_no_serial;
  logic [7:0] flash_source[$]; // Snapshot of external stimulus, never DUT readback.

  function new(string name = "qspi_cmd_exp");
    super.new(name);
  endfunction

  virtual function string convert2string();
    return $sformatf("PIO op=%02h addr=%08h bytes=%0d expect_err=%0b",
      opcode,address,payload_len,expect_error);
  endfunction
endclass

// Independent CSR shadow for command predictions. Only accepted REQUEST
// fields update it. Readback/status from the DUT never defines golden values.
class qspi_cmd_predictor extends qspi_csr_shadow;
  `uvm_object_utils(qspi_cmd_predictor)
  function new(string name = "qspi_cmd_predictor");
    super.new(name);
  endfunction
  function void reset_model();
    reset();
  endfunction
  function void apply_write(qspi_apb_item_t t);
    bit triggered;
    triggered = apply_apb_write(t);
    if (triggered) ctrl[9:8] = t.wdata[9:8];
  endfunction
  function void finish_indirect();
    ctrl[9:8] = 0;
  endfunction
  function qspi_cmd_exp predict();
    qspi_cmd_exp e;
    qspi_cmd_profile_t p;
    p = get_cmd_snapshot();
    e = qspi_cmd_exp::type_id::create("cmd_expectation");
    if (!qspi_is_legal_lane_enc(p.cmd_lanes_enc) ||
        !qspi_is_legal_lane_enc(p.addr_lanes_enc) ||
        !qspi_is_legal_lane_enc(p.data_lanes_enc) ||
        !qspi_is_legal_addr_enc(p.addr_bytes_enc)) begin
      `uvm_error("QSPI_FLOW_SPEC_INPUT", "Reserved encoding has no specified golden transaction")
      return null;
    end
    e.use_lut=p.use_lut; e.lut_index=p.lut_index;
    e.address=p.cmd_addr; e.payload_len=p.cmd_len; e.read_direction=p.dir;
    e.opcode=p.opcode; e.mode_value=p.mode_bits;
    e.cmd_lanes=qspi_eff_lanes(p.cmd_lanes_enc,p.quad_en);
    e.addr_lanes=qspi_eff_lanes(p.addr_lanes_enc,p.quad_en);
    e.data_lanes=qspi_eff_lanes(p.data_lanes_enc,p.quad_en);
    e.mode_lanes=e.addr_lanes;
    e.addr_bytes=qspi_enc_to_addr_bytes(p.addr_bytes_enc);
    if (e.addr_bytes==3) e.address[31:24]=0;
    if (e.addr_bytes==0) e.address=0;
    e.mode_enable=p.mode_en;
    e.dummy_base=int'(p.dummy_cycles); e.dummy_extra=int'(p.extra_dummy);
    e.dummy_cycles=e.dummy_base+e.dummy_extra;
    e.cpol=p.cpol; e.cpha=p.cpha; e.clk_div=p.clk_div; e.cs_delay=p.cs_delay;
    return e;
  endfunction
endclass

// Scoreboard-owned correlation state. Shared monitor items are read-only.
class qspi_cmd_ctx;
  qspi_cmd_exp exp_cmd;
  qspi_serial_item act_serial;
  bit data_checked;
  bit no_serial_complete;
  bit has_int_error;
  bit [2:0] act_err_bits;
  longint unsigned issue_order;
  bit clean_error_baseline;
  bit has_cmd_done;
  bit fresh_completion_baseline;
  bit has_err_read, pio_result_reported;
  bit rx_budget_reclaimed, err_cleared_by_w1c;
  time cmd_done_completed_at = 0;
  time serial_completed_at = 0;
  int unsigned mismatches_at_issue, rx_words_expected, rx_words_compared;

  function new(qspi_cmd_exp prediction, longint unsigned order);
    exp_cmd=prediction;
    issue_order=order;
    rx_words_expected=0; rx_words_compared=0; mismatches_at_issue=0;
  endfunction
endclass

// Spec predictions and observed outcomes have separate objects. One dispatcher
// drains the analysis FIFOs; independent consumer threads never race on state.
class qspi_flow_sb extends uvm_scoreboard;
  `uvm_component_utils(qspi_flow_sb)
  typedef qspi_apb_item_t apb_item_t;
  typedef struct {logic [31:0] data; logic [3:0] strb;} tx_word_t;
  typedef struct {logic [31:0] data; logic [31:0] mask; qspi_cmd_ctx owner;} rx_word_t;

  qspi_env_cfg cfg;
  qspi_cmd_predictor predictor;
  uvm_analysis_port #(qspi_pio_result_item) pio_result_ap;
  uvm_tlm_analysis_fifo #(apb_item_t) apb_fifo;
  uvm_tlm_analysis_fifo #(qspi_cmd_intent) cmd_intent_fifo;
  uvm_tlm_analysis_fifo #(qspi_transaction) agent_serial_fifo;
  uvm_tlm_analysis_fifo #(axil_master_transaction) xip_ar_fifo;
  uvm_tlm_analysis_fifo #(axil_master_transaction) xip_r_fifo;
  qspi_cmd_ctx cmds[$];
  qspi_cmd_ctx status_context;
  qspi_cmd_ctx latest_indirect;
  qspi_cmd_ctx last_errored_ctx;
  tx_word_t pio_tx[$];
  rx_word_t pio_rx[$];
  logic [31:0] pio_read_results[$];
  bit clean_int_error, clean_err_status;
  bit clean_cmd_done;
  bit dma_in_flight = 0;
  bit xip_ar_en_q[$];
  bit xip_err_pending = 0;
  int unsigned pending_dma_serial_frames = 0;
  int unsigned pending_xip_serial_frames = 0;
  longint unsigned pio_read_budget=0, issue_count=0;
  int unsigned serial_checked=0, mismatches=0;
  int unsigned pio_outcomes=0, pio_successes=0, pio_errors=0;

  function new(string name, uvm_component parent);
    super.new(name,parent);
    predictor=qspi_cmd_predictor::type_id::create("predictor");
    pio_result_ap=new("pio_result_ap",this);
    apb_fifo=new("apb_fifo",this);
    cmd_intent_fifo=new("cmd_intent_fifo",this);
    agent_serial_fifo=new("agent_serial_fifo",this);
    xip_ar_fifo=new("xip_ar_fifo",this);
    xip_r_fifo=new("xip_r_fifo",this);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null || cfg.clk_vif == null || cfg.flash_vif == null)
      `uvm_fatal("QSPI_FLOW_CFG", "qspi_flow_sb requires non-null cfg, clk_vif, and flash_vif")
  endfunction

  function void report_mismatch(string message);
    mismatches++;
    `uvm_error("QSPI_FLOW_MISMATCH",message)
  endfunction

  function void reset_model();
    predictor.reset_model();
    cmds.delete(); status_context=null; latest_indirect=null; last_errored_ctx=null;
    pio_tx.delete(); pio_rx.delete(); pio_read_results.delete();
    clean_int_error=1; clean_err_status=1; // Spec reset baseline.
    clean_cmd_done=1;
    pio_read_budget=0;
    dma_in_flight=0;
    xip_ar_en_q.delete();
    xip_err_pending=0;
    pending_dma_serial_frames=0;
    pending_xip_serial_frames=0;
    apb_fifo.flush(); cmd_intent_fifo.flush();
    agent_serial_fifo.flush();
    xip_ar_fifo.flush();
    xip_r_fifo.flush();
  endfunction

  function bit has_active_en_xip();
    foreach (xip_ar_en_q[i])
      if (xip_ar_en_q[i]) return 1'b1;
    return 1'b0;
  endfunction

  function qspi_cmd_ctx add_cmd();
    qspi_cmd_exp exp_cmd;
    qspi_cmd_ctx state;
    qspi_cmd_intent intent;
    exp_cmd=predictor.predict();
    if (exp_cmd==null) return null;
    exp_cmd.mode_lanes=exp_cmd.addr_lanes;
    if (predictor.ctrl[9]) begin
      report_mismatch("DMA_EN was set during a PIO command");
      return null;
    end
    if (!cmd_intent_fifo.try_get(intent) || intent == null) begin
      exp_cmd.expect_error      = 1'b0;
      exp_cmd.required_err_bits = 3'b000;
      exp_cmd.any_err_bits      = 3'b000;
      exp_cmd.allow_no_serial   = 1'b0;
      exp_cmd.flash_source.delete();
    end else begin
      exp_cmd.expect_error      = intent.expect_error;
      exp_cmd.required_err_bits = intent.required_err_bits;
      exp_cmd.any_err_bits      = intent.any_err_bits;
      exp_cmd.allow_no_serial   = intent.allow_no_serial;
      exp_cmd.flash_source.delete();
      foreach (intent.flash_bytes[i]) exp_cmd.flash_source.push_back(intent.flash_bytes[i]);
    end
    last_errored_ctx = null;
    state=new(exp_cmd,issue_count++);
    state.mismatches_at_issue=mismatches;
    state.clean_error_baseline=clean_int_error && clean_err_status;
    state.fresh_completion_baseline=clean_cmd_done;
    clean_int_error=0; clean_err_status=0;
    clean_cmd_done=0;
    cmds.push_back(state);
    // A global CSR cannot identify one of overlapping operations. Refuse
    // ambiguous attribution instead of blessing the newest negative request.
    if (status_context!=null && !status_context.data_checked &&
        !status_context.no_serial_complete) status_context=null;
    else status_context=state;
    latest_indirect=state;
    if (exp_cmd.read_direction)
      pio_read_budget+=(exp_cmd.payload_len/4)+((exp_cmd.payload_len%4)!=0);
    `uvm_info("QSPI_FLOW_EXPECT",exp_cmd.convert2string(),UVM_HIGH)
    return state;
  endfunction

  function bit expects_failure(qspi_cmd_ctx state);
    return state.exp_cmd.expect_error;
  endfunction

  function bit has_failure_evidence(qspi_cmd_ctx state);
    return state.has_int_error || (|state.act_err_bits);
  endfunction

  function bit may_omit_serial(qspi_cmd_ctx state);
    return state.exp_cmd.expect_error && state.exp_cmd.allow_no_serial;
  endfunction

  function void compare_pio_reads();
    rx_word_t exp_word;
    logic [31:0] act_data;
    while (pio_rx.size()!=0 && pio_read_results.size()!=0) begin
      exp_word=pio_rx.pop_front(); act_data=pio_read_results.pop_front();
      if (exp_word.owner!=null) exp_word.owner.rx_words_compared++;
      if ((act_data & exp_word.mask)!==(exp_word.data & exp_word.mask))
        report_mismatch($sformatf("READ_RX expected=%08h got=%08h mask=%08h",
                       exp_word.data,act_data,exp_word.mask));
      else
        `uvm_info("QSPI_FLOW_MATCH", $sformatf("READ_RX matched: expected=0x%08h actual=0x%08h mask=0x%08h",
                       exp_word.data,act_data,exp_word.mask), UVM_HIGH);
    end
  endfunction

  function void on_apb(apb_item_t t);
    qspi_cmd_ctx state;
    tx_word_t word_entry;
    if (t==null || t.reset_abort || t.slverr!==1'b0 ||
        $isunknown({t.addr,t.write,t.strb,t.prot})) return;
    if (t.write) begin
      bit pre_ctrl_en;
      bit eff_ctrl_en;
      for (int lane=0;lane<4;lane++)
        if (t.strb[lane] === 1'b1 && $isunknown(t.wdata[8*lane +: 8])) begin
          report_mismatch("Unknown enabled APB write byte");
          return;
        end
      if (t.addr==QSPI_REG_INT_STAT && t.strb[0] && t.wdata[2] === 1'b1) begin
        clean_int_error=0;
        xip_err_pending=0;
        if (last_errored_ctx != null) last_errored_ctx.err_cleared_by_w1c = 1'b1;
        last_errored_ctx = null;
      end
      if (t.addr==QSPI_REG_INT_STAT && t.strb[0] && t.wdata[0] === 1'b1) clean_cmd_done=0;
      pre_ctrl_en = predictor.ctrl[0];
      predictor.apply_write(t);
      eff_ctrl_en = t.strb[0] ? t.wdata[0] : pre_ctrl_en;
      if (t.addr==QSPI_REG_CTRL && t.strb[1] && t.wdata[8] && eff_ctrl_en && !predictor.ctrl[1]) begin
        xip_err_pending = 0;
        if (t.wdata[9]) begin
          status_context = null;
          last_errored_ctx = null;
          dma_in_flight = 1;
          pending_dma_serial_frames++;
        end else begin
          dma_in_flight = 0;
          state=add_cmd();
        end
      end
      if (t.addr==QSPI_REG_WRITE_TX) begin

        word_entry.data=t.wdata; word_entry.strb=4'hF;
        pio_tx.push_back(word_entry);
      end
      return;
    end
    if (t.addr==QSPI_REG_READ_RX && pio_read_budget!=0) begin
      pio_read_budget--;
      pio_read_results.push_back(t.rdata);
      compare_pio_reads();
    end
    if (t.addr==QSPI_REG_ERR_STAT && !$isunknown(t.rdata[2:0])) clean_err_status=t.rdata[2:0]==0;
    if (t.addr==QSPI_REG_INT_STAT && !$isunknown(t.rdata[2])) clean_int_error=!t.rdata[2];
    if (t.addr==QSPI_REG_INT_STAT && !$isunknown(t.rdata[0])) clean_cmd_done=!t.rdata[0];
    if (dma_in_flight && t.addr==QSPI_REG_INT_STAT && !$isunknown(t.rdata[2:0]) &&
        ((t.rdata[1] && t.rdata[0]) || t.rdata[2]))
      dma_in_flight = 1'b0;
    if (status_context==null && !dma_in_flight && !(xip_err_pending || has_active_en_xip()) &&
        !(last_errored_ctx != null && !last_errored_ctx.err_cleared_by_w1c) &&
        ((t.addr==QSPI_REG_ERR_STAT && (|t.rdata[2:0])===1'b1) ||
         (t.addr==QSPI_REG_INT_STAT && t.rdata[2]===1'b1)))
      report_mismatch("Error status has no unambiguous command context; isolate the error scenario and baseline");
    if (status_context==null && last_errored_ctx != null && !last_errored_ctx.err_cleared_by_w1c) begin
      if (t.addr==QSPI_REG_ERR_STAT && !$isunknown(t.rdata[2:0]))
        last_errored_ctx.act_err_bits |= t.rdata[2:0];
    end
    if (status_context!=null) begin
      if (t.addr==QSPI_REG_ERR_STAT && !$isunknown(t.rdata[2:0])) begin
        if ((|t.rdata[2:0]) && !expects_failure(status_context) && !status_context.has_err_read)
          report_mismatch($sformatf("Unexpected ERR_STAT on a success command: %03b", t.rdata[2:0]));
        status_context.act_err_bits |= t.rdata[2:0];
        status_context.has_err_read=1;
      end
      if (t.addr==QSPI_REG_INT_STAT && t.rdata[2]===1'b1) begin
        if (!expects_failure(status_context) && !status_context.has_int_error)
          report_mismatch("Unexpected INT_STAT.ERR on a success command");
        if (expects_failure(status_context) && !status_context.clean_error_baseline && !status_context.has_int_error)
          report_mismatch("Latched ERR without a clean pre-command baseline cannot prove a new expected failure");
        status_context.has_int_error=1;
      end
      if (t.addr==QSPI_REG_INT_STAT && t.rdata[0]===1'b0 && !status_context.has_cmd_done)
        status_context.fresh_completion_baseline=1;
      if (t.addr==QSPI_REG_INT_STAT && t.rdata[0]===1'b1 && status_context.fresh_completion_baseline &&
          !status_context.has_cmd_done) begin
        status_context.has_cmd_done=1;
        status_context.cmd_done_completed_at=t.completed_at;
        check_cmd_done_timing(status_context);
        if (status_context==latest_indirect) predictor.finish_indirect();
      end
    end
  endfunction

  function void check_cmd_done_timing(qspi_cmd_ctx state);
    if (state == null) return;
    if (state.has_cmd_done && state.cmd_done_completed_at > 0 &&
        state.act_serial != null && state.serial_completed_at > 0 &&
        !state.exp_cmd.allow_no_serial && !expects_failure(state)) begin
      if (state.cmd_done_completed_at < state.serial_completed_at) begin
        report_mismatch($sformatf(
          "Command %0d asserted CMD_DONE at time %0t before physical SPI frame completed at time %0t (violates Spec 5.3)",
          state.issue_order, state.cmd_done_completed_at, state.serial_completed_at));
      end
    end
  endfunction

  function void check_header(qspi_cmd_ctx state);
    qspi_cmd_exp exp_cmd;
    qspi_serial_item act_serial;
    bit permit_partial;
    longint unsigned exp_edges;
    exp_cmd=state.exp_cmd; act_serial=state.act_serial;
    permit_partial=expects_failure(state);
    exp_edges=64'd8/exp_cmd.cmd_lanes +
                   (64'd8*exp_cmd.addr_bytes)/exp_cmd.addr_lanes +
                   (exp_cmd.mode_enable ? 64'd8/exp_cmd.mode_lanes : 0) +
                   exp_cmd.dummy_cycles + (64'd8*exp_cmd.payload_len)/exp_cmd.data_lanes;
    if (act_serial.has_edge_count &&
        ((!permit_partial && (act_serial.sample_edges < exp_edges || act_serial.sample_edges > exp_edges + exp_cmd.cs_delay)) ||
         (permit_partial && act_serial.sample_edges > exp_edges + exp_cmd.cs_delay + 64'd2000)))
      report_mismatch($sformatf("Command %0d serial sample edges expected=%0d (allow up to +%0d for CS_DELAY) observed=%0d",
                     state.issue_order,exp_edges,exp_cmd.cs_delay,act_serial.sample_edges));
    check_cmd_done_timing(state);
    // A negative case may terminate within a phase; already complete phases
    // still have to match. A DUT-reported ERR never enables this exception.
    if ((!permit_partial || !act_serial.has_termination_metadata || act_serial.end_phase>0) && act_serial.opcode!==exp_cmd.opcode)
      report_mismatch($sformatf("Command %0d opcode expected=%02h got=%02h",
                     state.issue_order,exp_cmd.opcode,act_serial.opcode));
    else if (!permit_partial || !act_serial.has_termination_metadata || act_serial.end_phase>0)
      `uvm_info("QSPI_FLOW_MATCH", $sformatf("Command %0d opcode matched: 0x%02h", state.issue_order, act_serial.opcode), UVM_HIGH);

    if (exp_cmd.addr_bytes!=0) begin
      if ((!permit_partial || !act_serial.has_termination_metadata || act_serial.end_phase>1) && act_serial.address!==exp_cmd.address)
        report_mismatch($sformatf("Command %0d address expected=%08h got=%08h",
                       state.issue_order,exp_cmd.address,act_serial.address));
      else if (!permit_partial || !act_serial.has_termination_metadata || act_serial.end_phase>1)
        `uvm_info("QSPI_FLOW_MATCH", $sformatf("Command %0d address matched: 0x%08h", state.issue_order, act_serial.address), UVM_HIGH);
    end

    if (exp_cmd.mode_enable) begin
      if ((!permit_partial || !act_serial.has_termination_metadata || act_serial.end_phase>2) && act_serial.mode_value!==exp_cmd.mode_value)
        report_mismatch("Serial mode byte differs from the programmed request");
      else if (!permit_partial || !act_serial.has_termination_metadata || act_serial.end_phase>2)
        `uvm_info("QSPI_FLOW_MATCH", $sformatf("Command %0d mode byte matched: 0x%02h", state.issue_order, act_serial.mode_value), UVM_HIGH);
    end

    if (!permit_partial &&
        (exp_cmd.read_direction ? act_serial.rx_data.size() : act_serial.tx_data.size()) >
        (exp_cmd.payload_len + ((exp_cmd.cs_delay * exp_cmd.data_lanes) / 8)))
      report_mismatch("Serial payload exceeds the programmed CMD_LEN");
  endfunction

  function void check_pio(qspi_cmd_ctx state);
    qspi_cmd_exp exp_cmd;
    qspi_serial_item act_serial;
    tx_word_t tx;
    rx_word_t rx;
    int raw_count, count, words, lane_count, max_stop_bytes;
    bit all_matched;
    exp_cmd=state.exp_cmd; act_serial=state.act_serial;
    max_stop_bytes = (exp_cmd.cs_delay * exp_cmd.data_lanes) / 8;
    raw_count=exp_cmd.read_direction ? act_serial.rx_data.size() : act_serial.tx_data.size();
    count = (!expects_failure(state) && raw_count > exp_cmd.payload_len) ? exp_cmd.payload_len : raw_count;
    words=(count/4)+((count%4)!=0);
    if (!expects_failure(state) &&
        ((act_serial.has_termination_metadata && act_serial.incomplete) ||
         raw_count < exp_cmd.payload_len ||
         raw_count > exp_cmd.payload_len + max_stop_bytes))
      report_mismatch($sformatf("PIO command %0d requires %0d complete bytes (allow +%0d STOP_CS); got %0d (incomplete=%0b)",
                     state.issue_order,exp_cmd.payload_len,max_stop_bytes,raw_count,act_serial.incomplete));
    if (exp_cmd.read_direction) begin
      all_matched = 1;
      for (int i = 0; i < count; i++) begin
        if ($isunknown(act_serial.rx_data[i])) begin
          report_mismatch($sformatf("RX pin byte %0d contains unknown (X/Z): %02h", i, act_serial.rx_data[i]));
          all_matched = 0;
        end else if (i<exp_cmd.flash_source.size() && act_serial.rx_data[i]!==exp_cmd.flash_source[i]) begin
          report_mismatch($sformatf("RX pin byte %0d differs from the configured external stimulus: expected=%02h got=%02h",
                          i, exp_cmd.flash_source[i], act_serial.rx_data[i]));
          all_matched = 0;
        end
      end
      if (all_matched && count > 0)
        `uvm_info("QSPI_FLOW_MATCH", $sformatf("Command %0d all %0d RX pin bytes matched configured stimulus", state.issue_order, count), UVM_HIGH);

      for (int w=0;w<words;w++) begin
        int word_bytes;
        rx.data=0; rx.mask=0; rx.owner=state;
        word_bytes = ((4*w + 4) <= count) ? 4 : (count - 4*w);

        for (int lane=0; lane<word_bytes; lane++) begin
          int bit_lsb;
          bit_lsb = 8*lane;
          rx.data[bit_lsb +: 8]=act_serial.rx_data[4*w+lane];
          rx.mask[bit_lsb +: 8]=8'hff;
        end
        pio_rx.push_back(rx);
        state.rx_words_expected++;
      end
      if (expects_failure(state) && !state.rx_budget_reclaimed) begin
        // Only produced words can be drained after an early termination.
        lane_count=int'((exp_cmd.payload_len/4)+((exp_cmd.payload_len%4)!=0))-words;
        if (lane_count>0 && pio_read_budget>=lane_count) pio_read_budget-=lane_count;
        state.rx_budget_reclaimed = 1'b1;
      end
      compare_pio_reads();
    end else begin
      all_matched = 1;
      for (int w=0;w<words;w++) begin
        if (pio_tx.size()==0) begin
          if (!expects_failure(state)) report_mismatch("Serial TX has no WRITE_TX request data");
          all_matched = 0;
          break;
        end
        tx=pio_tx.pop_front();
        for (int lane=0;lane<4 && 4*w+lane<count;lane++) begin
          int tx_bit_lsb;

          tx_bit_lsb = 8*lane;
          if ($isunknown(act_serial.tx_data[4*w+lane])) begin
            report_mismatch($sformatf("PIO TX byte %0d contains unknown (X/Z): %02h",
                            4*w+lane, act_serial.tx_data[4*w+lane]));
            all_matched = 0;
          end else if (tx.strb[lane] && act_serial.tx_data[4*w+lane]!==tx.data[tx_bit_lsb +: 8]) begin
            report_mismatch($sformatf("PIO TX byte %0d differs from WRITE_TX: expected=%02h got=%02h",
                            4*w+lane, tx.data[tx_bit_lsb +: 8], act_serial.tx_data[4*w+lane]));
            all_matched = 0;
          end
        end
      end
      if (all_matched && count > 0)
        `uvm_info("QSPI_FLOW_MATCH", $sformatf("Command %0d all %0d TX pin bytes matched WRITE_TX data", state.issue_order, count), UVM_HIGH);
    end
    state.data_checked=1;
  endfunction


  function void reconcile();
    foreach (cmds[i]) begin
      if (cmds[i].data_checked || cmds[i].act_serial==null) continue;
      check_header(cmds[i]);
      check_pio(cmds[i]);
    end
  endfunction

  function qspi_cmd_ctx match_serial(qspi_serial_item act_serial);
    if (act_serial==null) return null;
    foreach (cmds[i])
      if (cmds[i].act_serial==null && !cmds[i].no_serial_complete) return cmds[i];
    return null;
  endfunction

  // Direction is the monitor's decode profile, not DUT output-enable evidence.
  function void on_agent_serial(qspi_transaction t);
    qspi_serial_item observed;
    qspi_cmd_ctx state;
    if (t==null) return;
    `uvm_info("QSPI_FLOW_SPI", $sformatf("Received act_pkt mosi[qspi0] = %02h%06h (edges=%0d end_phase=%0d abort=%0b)",
      t.opcode, t.addr[23:0], t.sclk_edges_total, t.end_phase, t.aborted_early), UVM_HIGH)
    observed=qspi_serial_item::type_id::create("agent_observation");
    observed.has_edge_count=1;
    observed.sample_edges=t.sclk_edges_total;
    observed.has_termination_metadata=1;
    observed.incomplete=t.aborted_early;
    observed.end_phase=t.end_phase;
    observed.opcode=t.opcode;
    observed.address=t.addr;
    observed.mode_value=t.mode_bits;
    observed.completed_at=t.completed_at;
    state=match_serial(observed);
    if (state!=null) foreach (t.data[i]) begin
      if (state.exp_cmd.read_direction) begin
        observed.rx_data.push_back(t.data[i]);
      end else begin
        observed.tx_data.push_back(t.data[i]);
      end
    end
    on_serial(observed);
  endfunction

  function void on_serial(qspi_serial_item act_serial);
    qspi_cmd_ctx state;
    if (act_serial==null) return;
    if (pending_xip_serial_frames > 0 &&
        (latest_indirect == null || latest_indirect.act_serial != null ||
         (predictor != null && predictor.ctrl[0] && predictor.ctrl[1]))) begin
      pending_xip_serial_frames--;
      return;
    end
    state=match_serial(act_serial);
    if (state==null) begin
      if (pending_xip_serial_frames > 0) begin
        pending_xip_serial_frames--;
        return;
      end
      if (pending_dma_serial_frames > 0) begin
        pending_dma_serial_frames--;
        return;
      end
      if (predictor != null && predictor.ctrl[0] && predictor.ctrl[1] &&
          (cfg == null || !cfg.enable_axil_agent)) begin
        return;
      end
      report_mismatch("Serial frame has no matching command request");
      return;
    end
    state.act_serial=act_serial;
    state.serial_completed_at=act_serial.completed_at;
    check_cmd_done_timing(state);
    if (act_serial.has_termination_metadata && state==latest_indirect) predictor.finish_indirect();
    serial_checked++;
    reconcile();
  endfunction


  function void drain_observations();
    apb_item_t apb;
    qspi_transaction agent_serial;
    axil_master_transaction xip_ar, xip_r;
    // Account XIP AR acceptances before R retirements, serial completions, and APB CSR
    // updates so pre-write CTRL.{XIP_EN,ENABLE} state matches the posedge flop boundary.
    while (xip_ar_fifo.try_get(xip_ar)) begin
      if (xip_ar != null && !xip_ar.reset_abort) begin
        bit was_en = (predictor != null && predictor.ctrl[0] && predictor.ctrl[1]);
        xip_ar_en_q.push_back(was_en);
        if (was_en) begin
          pending_xip_serial_frames++;
          status_context = null;
        end
      end
    end
    // Retire XIP CSR error immunity cleanly on OKAY completion while retaining error
    // attribution after SLVERR until INT_STAT.ERR W1C, next indirect command, or reset.
    while (xip_r_fifo.try_get(xip_r)) begin
      if (xip_r != null) begin
        bit was_en = 1'b0;
        if (xip_ar_en_q.size() > 0 && (!xip_r.reset_abort || xip_r.ar_accepted))
          was_en = xip_ar_en_q.pop_front();
        if (!xip_r.reset_abort && was_en && xip_r.resp !== 2'b00)
          xip_err_pending = 1'b1;
      end
    end
    // Active serial path receives pin observations directly from qspi_monitor
    while (agent_serial_fifo.try_get(agent_serial)) on_agent_serial(agent_serial);
    while (apb_fifo.try_get(apb)) on_apb(apb);
    foreach (cmds[i])
      if (cmds[i].act_serial==null && has_failure_evidence(cmds[i]) &&
           may_omit_serial(cmds[i]) &&
           cfg != null && cfg.flash_vif != null && cfg.flash_vif.qspi_cs_n===1'b1) begin
        cmds[i].no_serial_complete=1;
        if (cmds[i].exp_cmd.read_direction && !cmds[i].rx_budget_reclaimed) begin
          longint unsigned exp_words = (cmds[i].exp_cmd.payload_len/4) +
                                       ((cmds[i].exp_cmd.payload_len%4) != 0);
          if (pio_read_budget >= exp_words) pio_read_budget -= exp_words;
          else                              pio_read_budget  = 0;
          cmds[i].rx_budget_reclaimed = 1'b1;
        end
        if (cmds[i]==latest_indirect) predictor.finish_indirect();
      end
    publish_pio_results();
  endfunction

  function void publish_pio_results();
    qspi_pio_result_item result;
    bit negative, finished;
    foreach (cmds[i]) begin
      if (cmds[i].pio_result_reported) continue;
      negative=expects_failure(cmds[i]);
      finished=negative ?
        (cmds[i].has_int_error && cmds[i].has_err_read &&
          (cmds[i].data_checked || cmds[i].no_serial_complete)) :
        (cmds[i].data_checked && cmds[i].has_cmd_done && cmds[i].has_err_read &&
         (cmds[i].exp_cmd.read_direction ? (cmds[i].rx_words_compared == cmds[i].rx_words_expected) : 1));
      // ref_port publication is not proof that CS has deasserted.
      if (!finished || cfg == null || cfg.flash_vif == null || cfg.flash_vif.qspi_cs_n!==1'b1) continue;
      result=qspi_pio_result_item::type_id::create("checked_pio_outcome");
      result.issue_order=cmds[i].issue_order;
      result.opcode=cmds[i].exp_cmd.opcode;
      result.cpol=cmds[i].exp_cmd.cpol; result.cpha=cmds[i].exp_cmd.cpha;
      result.clk_div=cmds[i].exp_cmd.clk_div;
      result.read_direction=cmds[i].exp_cmd.read_direction;
      result.length=cmds[i].exp_cmd.payload_len;
      result.addr_bytes=cmds[i].exp_cmd.addr_bytes;
      result.data_lanes=cmds[i].exp_cmd.data_lanes;
      result.cmd_lanes=cmds[i].exp_cmd.cmd_lanes;
      result.addr_lanes=cmds[i].exp_cmd.addr_lanes;
      result.mode_lanes=cmds[i].exp_cmd.mode_lanes;
      result.dummy_base=cmds[i].exp_cmd.dummy_base;
      result.dummy_extra=cmds[i].exp_cmd.dummy_extra;
      result.dummy_total=cmds[i].exp_cmd.dummy_cycles;
      result.use_lut=cmds[i].exp_cmd.use_lut; result.lut_index=cmds[i].exp_cmd.lut_index;
      result.cs_delay=cmds[i].exp_cmd.cs_delay;
      result.mode_enable=cmds[i].exp_cmd.mode_enable; result.mode_value=cmds[i].exp_cmd.mode_value;
      result.success=!negative;
      result.checked_ok=mismatches==cmds[i].mismatches_at_issue &&
        (negative ? (cmds[i].clean_error_baseline && (|cmds[i].act_err_bits) &&
                     (cmds[i].exp_cmd.any_err_bits == 0 || (|(cmds[i].act_err_bits & cmds[i].exp_cmd.any_err_bits))) &&
                     ((cmds[i].act_err_bits & cmds[i].exp_cmd.required_err_bits) == cmds[i].exp_cmd.required_err_bits)) :
          (!cmds[i].has_int_error && cmds[i].act_err_bits==0 &&
           cmds[i].has_err_read &&
           cmds[i].rx_words_compared == cmds[i].rx_words_expected));
      cmds[i].pio_result_reported=1;
      if (status_context == cmds[i]) status_context = null;
      if (negative) last_errored_ctx = cmds[i];
      pio_outcomes++;
      if (result.success) pio_successes++; else pio_errors++;
      pio_result_ap.write(result);
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg == null || cfg.clk_vif == null)
      `uvm_fatal("QSPI_FLOW_CFG", "Missing qspi_env_cfg or clk_vif in run_phase")
    reset_model();
    forever begin
      @(negedge cfg.clk_vif.clk or negedge cfg.clk_vif.rst_n);
      uvm_wait_for_nba_region();
      if (cfg.clk_vif.rst_n!==1'b1) reset_model();
      else drain_observations();
    end
  endtask

  function void check_phase(uvm_phase phase);
    int unsigned unread_pos_rx;
    super.check_phase(phase);
    unread_pos_rx = 0;
    if (cfg == null || cfg.clk_vif == null || cfg.flash_vif == null) return;
    if (cfg.clk_vif.rst_n===1'b1) drain_observations();
    foreach (cmds[i]) begin
      check_cmd_done_timing(cmds[i]);
      if (cmds[i].act_serial==null && !cmds[i].no_serial_complete)
        report_mismatch($sformatf("Command %0d has no serial completion",cmds[i].issue_order));
      if (expects_failure(cmds[i])) begin
        if (!has_failure_evidence(cmds[i])) report_mismatch("Expected command failure was not observed");
        if ((cmds[i].act_err_bits==0 || (cmds[i].exp_cmd.any_err_bits!=0 &&
             (cmds[i].act_err_bits & cmds[i].exp_cmd.any_err_bits)==0)))
          report_mismatch("Negative PIO requires nonzero ERR_STAT and an allowed error cause");
        if ((cmds[i].act_err_bits & cmds[i].exp_cmd.required_err_bits)!=cmds[i].exp_cmd.required_err_bits)
          report_mismatch("Expected ERR_STAT bits were not observed for the negative command");
        if (!cmds[i].has_int_error)
          report_mismatch("Negative PIO command did not expose INT_STAT.ERR");
      end else if (cmds[i].has_int_error || (|cmds[i].act_err_bits))
        report_mismatch("DUT reported an unexpected command error; golden expectation remains success");
      if (!expects_failure(cmds[i])) begin
        if (!cmds[i].data_checked) report_mismatch("PIO payload checks did not complete");
        if (!cmds[i].has_cmd_done) report_mismatch("PIO command has no fresh CMD_DONE observation");
        if (!cmds[i].has_err_read) report_mismatch("PIO command has no ERR_STAT observation");
        if (cmds[i].rx_words_compared!=cmds[i].rx_words_expected)
          report_mismatch("PIO RX words remain without READ_RX comparisons");
      end
    end
    if (cmd_intent_fifo.used()!=0)
      report_mismatch($sformatf("%0d predeclared command intent(s) never triggered on APB", cmd_intent_fifo.used()));
    unread_pos_rx = 0;
    foreach (pio_rx[i]) begin
      if (pio_rx[i].owner == null || !expects_failure(pio_rx[i].owner))
        unread_pos_rx++;
    end
    if (unread_pos_rx != 0)
      report_mismatch($sformatf("%0d unread RX FIFO word(s) remain uncompared for positive commands at end of test", unread_pos_rx));
    if (pio_read_results.size()!=0) report_mismatch("READ_RX results have no matching flash bytes");
    if (cmds.size()!=0 && cfg.flash_vif.qspi_cs_n!==1'b1)
      report_mismatch("Test ended before the serial frame terminated");
    if (pending_xip_serial_frames != 0)
      report_mismatch($sformatf("%0d pending XIP serial frame(s) were never observed on QSPI bus", pending_xip_serial_frames));
    if (xip_ar_en_q.size() != 0)
      report_mismatch($sformatf("%0d accepted XIP AR request(s) never retired on AXI4-Lite R channel", xip_ar_en_q.size()));
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_FLOW_SUMMARY",$sformatf("PIO issued=%0d current-reset-epoch=%0d SPI=%0d mismatches=%0d",
      issue_count,cmds.size(),serial_checked,mismatches),
      (issue_count == 0 && mismatches == 0) ? UVM_HIGH : UVM_LOW)
  endfunction
endclass
`endif
