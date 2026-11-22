// Passive coverage only. Published items are never modified.
class qspi_pio_cov extends uvm_subscriber #(qspi_pio_result_item);
  `uvm_component_utils(qspi_pio_cov)
  qspi_env_cfg cfg;
  int unsigned success_count=0,error_count=0,reset_count=0;
  int last_outcome=-1;
  covergroup pio_cmd_cg with function sample(qspi_pio_result_item t);
    option.per_instance=1;
    cp_opcode: coverpoint t.opcode {
      bins supported[] = {8'h9f,8'h05,8'h06,8'h04,8'h02,8'h32,8'h03,
        8'h0b,8'h3b,8'h6b,8'heb,8'h20,8'hd8,8'hc7};
    }
    cp_mode: coverpoint {t.cpol,t.cpha} { bins modes[]={[0:3]}; }
    cp_clk_div: coverpoint t.clk_div {
      bins div_bypass = {0};
      bins div_counter[] = {[1:7]};
    }
    cp_addr_bytes: coverpoint t.addr_bytes { bins counts[]={0,3,4}; }
    cp_length: coverpoint t.length {
      bins none={0}; bins partial[]={[1:3]}; bins word={4};
      bins below_fifo={[5:15]}; bins fifo={16}; bins beyond_fifo={[17:31]}; bins stream={[32:$]};
    }
    opcode_modes: cross cp_opcode,cp_mode {
      ignore_bins other_opcodes = !binsof(cp_opcode) intersect {8'h02, 8'h03};
    }
    opcode_dividers: cross cp_opcode,cp_clk_div {
      ignore_bins other_opcodes = !binsof(cp_opcode) intersect {8'h02, 8'h03};
    }
    mode_dividers: cross cp_mode,cp_clk_div;
  endgroup
  covergroup pio_payload_cg with function sample(qspi_pio_result_item t);
    option.per_instance=1;
    cp_direction: coverpoint t.read_direction { bins tx = {0}; bins rx = {1}; }
    cp_lanes: coverpoint t.data_lanes { bins single = {1}; bins dual = {2}; bins quad = {4}; }
    cp_mode: coverpoint {t.cpol,t.cpha} { bins modes[]={[0:3]}; }
    cp_remainder: coverpoint (t.length%4) { bins bytes[]={[0:3]}; }
    cx_half_duplex_lanes: cross cp_lanes, cp_direction;
    lane_modes: cross cp_lanes,cp_mode,cp_direction;
    tails: cross cp_remainder,cp_direction;
  endgroup
  // These fields describe the accepted request that passed the flow checks.
  // They are not independent observations of physical lane count or DUT OE.
  covergroup pio_format_cg with function sample(qspi_pio_result_item t);
    option.per_instance=1;
    cp_cmd_lanes: coverpoint t.cmd_lanes {
      bins single = {1};
      bins dual   = {2};
      bins quad   = {4};
    }
    cp_addr_lanes: coverpoint t.addr_lanes iff (t.addr_bytes!=0) {
      bins lanes[]={1,2,4};
    }
    cp_mode_enable: coverpoint t.mode_enable { bins disabled={0}; bins enabled={1}; }
    cp_mode_value: coverpoint t.mode_value iff (t.mode_enable) {
      bins zeros={8'h00}; bins ones={8'hff}; bins mixed={[8'h01:8'hfe]};
    }
    cp_mode_lanes: coverpoint t.mode_lanes iff (t.mode_enable) {
      bins lanes[]={1,2,4};
    }
    // Requested CS_DELAY values with a successful transfer, not delay units.
    cp_cs_delay: coverpoint t.cs_delay { bins settings[]={[0:3]}; }
    command_address_lanes: cross cp_cmd_lanes,cp_addr_lanes iff (t.addr_bytes!=0);
  endgroup
  covergroup pio_source_cg with function sample(qspi_pio_result_item t);
    option.per_instance=1;
    cp_source: coverpoint t.use_lut { bins direct={0}; bins lut={1}; }
    cp_bank: coverpoint t.lut_index iff (t.use_lut) { bins entries[]={[0:3]}; }
    cp_direction: coverpoint t.read_direction { bins tx={0}; bins rx={1}; }
    source_direction: cross cp_source,cp_direction;
  endgroup
  // Dummy clocks apply to receive payloads. Do not create TX-dummy or
  // no-payload crosses whose behavior is outside the current spec contract.
  covergroup pio_dummy_cg with function sample(qspi_pio_result_item t);
    option.per_instance=1;
    cp_base: coverpoint t.dummy_base { bins values[]={[0:15]}; }
    cp_extra: coverpoint t.dummy_extra {
      bins zero = {0};
      bins low  = {[1:15]};
      bins mid  = {[16:254]};
      bins max  = {255};
    }
    cp_total: coverpoint t.dummy_total {
      bins zero = {0};
      bins low  = {[1:15]};
      bins mid  = {[16:269]};
      bins max  = {270};
    }
    cp_lanes: coverpoint t.data_lanes { bins lanes[]={1,2,4}; }
    base_lanes: cross cp_base,cp_lanes;
    extra_lanes: cross cp_extra,cp_lanes;
  endgroup
  // Expected-error outcomes are sampled only after the checker has required
  // fresh INT_STAT.ERR, nonzero allowed ERR_STAT and its termination contract.
  covergroup pio_outcome_cg with function sample(qspi_pio_result_item t);
    option.per_instance=1;
    cp_success: coverpoint t.success { bins success={1}; bins expected_error={0}; }
    cp_direction: coverpoint t.read_direction { bins tx={0}; bins rx={1}; }
    direction_outcome: cross cp_direction,cp_success;
  endgroup
  covergroup recovery_cg with function sample(int outcome);
    option.per_instance = 1;
    cp_outcome: coverpoint outcome {
      bins success = {0}; bins error = {1}; bins reset = {2};
      bins error_to_success = (1 => 0);
      bins reset_to_success = (2 => 0);
      bins error_reset_success = (1 => 2 => 0);
    }
  endgroup

  function new(string name="qspi_pio_cov",uvm_component parent=null);
    super.new(name,parent);
    pio_cmd_cg=new();
    pio_payload_cg=new();
    pio_format_cg=new();
    pio_source_cg=new();
    pio_dummy_cg=new();
    pio_outcome_cg=new();
    recovery_cg=new();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg==null && !uvm_config_db#(qspi_env_cfg)::get(this,"","cfg",cfg))
      `uvm_fatal("QSPI_PIO_COV","Missing qspi_env_cfg")
    if (cfg.clk_vif==null)
      `uvm_fatal("QSPI_PIO_COV","Missing clk_vif in qspi_env_cfg")
  endfunction

  virtual function void write(qspi_pio_result_item t);
    if (t==null || cfg==null || cfg.clk_vif==null || cfg.clk_vif.rst_n!==1'b1 || !t.checked_ok) return;
    pio_outcome_cg.sample(t);
    if (last_outcome!=(t.success ? 0 : 1)) begin
      recovery_cg.sample(t.success ? 0 : 1);
      last_outcome=t.success ? 0 : 1;
    end
    if (t.success) begin
      success_count++;
      pio_cmd_cg.sample(t);
      pio_format_cg.sample(t);
      pio_source_cg.sample(t);
      if (t.length!=0) pio_payload_cg.sample(t);
      if (t.read_direction && t.length!=0) pio_dummy_cg.sample(t);
    end else begin
      error_count++;
    end
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg==null || cfg.clk_vif==null) return;
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      reset_count++;
      if (last_outcome!=2) recovery_cg.sample(2);
      last_outcome=2;
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_PIO_COV",$sformatf("checked-success=%0d expected-error=%0d resets=%0d command=%.2f payload=%.2f format=%.2f source=%.2f dummy=%.2f outcome=%.2f recovery=%.2f percent",
      success_count,error_count,reset_count,pio_cmd_cg.get_inst_coverage(),
      pio_payload_cg.get_inst_coverage(),pio_format_cg.get_inst_coverage(),
      pio_source_cg.get_inst_coverage(),pio_dummy_cg.get_inst_coverage(),
      pio_outcome_cg.get_inst_coverage(),recovery_cg.get_inst_coverage()),UVM_HIGH)
  endfunction
endclass : qspi_pio_cov

// Coverage of fields published by the QSPI SPI transaction (gated with PIO flow cov).
class qspi_spi_cov extends uvm_subscriber #(qspi_transaction);
  `uvm_component_utils(qspi_spi_cov)
  qspi_env_cfg cfg;
  int unsigned publication_count = 0;

  covergroup spi_cg with function sample(qspi_transaction t);
    option.per_instance = 1;
    cp_opcode: coverpoint t.opcode {
      bins cmds[] = {8'h9f, 8'h05, 8'h06, 8'h04, 8'h02, 8'h32, 8'h03,
                     8'h0b, 8'h3b, 8'h6b, 8'heb, 8'h20, 8'hd8, 8'hc7};
      bins other = default;
    }
    // These are reported values. The API cannot distinguish an absent phase
    // from a phase that was captured as zero.
    cp_reported_address: coverpoint t.addr iff (t.addr_bytes != 2'b00) {
      bins zero    = {0};
      bins last24  = {32'h00ff_ffff};
      bins first32 = {32'h0100_0000};
      bins last32  = {32'hffff_ffff};
      bins other   = default;
    }
    cp_reported_mode: coverpoint t.mode_bits iff (t.mode_en) {
      bins zero  = {0};
      bins ones  = {255};
      bins other = default;
    }
    cp_reported_length: coverpoint t.data.size() {
      bins none        = {0};
      bins partial[]   = {[1:3]};
      bins word        = {4};
      bins below_fifo  = {[5:15]};
      bins fifo        = {16};
      bins beyond_fifo = {[17:31]};
      bins stream      = {[32:$]};
    }
  endgroup

  function new(string name = "qspi_spi_cov", uvm_component parent = null);
    super.new(name, parent);
    spi_cg = new();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null && !uvm_config_db#(qspi_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("QSPI_SPI_COV", "Missing qspi_env_cfg")
    if (cfg.clk_vif == null)
      `uvm_fatal("QSPI_SPI_COV", "Missing clk_vif in qspi_env_cfg")
  endfunction

  virtual function void write(qspi_transaction t);
    if (t == null || cfg == null || cfg.clk_vif == null) return;
    if (cfg.clk_vif.rst_n === 1'b1 && !t.aborted_early && !$isunknown(t.opcode) &&
        ((t.addr_bytes == 2'b00) || !$isunknown(t.addr)) &&
        (!t.mode_en || !$isunknown(t.mode_bits))) spi_cg.sample(t);
    publication_count++;
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_SPI_COV", $sformatf(
      "agent-publications=%0d reported-fields=%.2f percent; lane/direction use decode profile, not DUT OE measurement",
      publication_count, spi_cg.get_inst_coverage()), UVM_HIGH)
  endfunction
endclass : qspi_spi_cov
