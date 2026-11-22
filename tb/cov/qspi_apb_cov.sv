`ifndef QSPI_APB_COV_SV
`define QSPI_APB_COV_SV

// APB4 protocol coverage. All samples come from the independent APB monitor.
// No aborted transfer is counted as a completed APB access.
// CSR data correctness is checked in the QSPI scoreboard, not here.
class qspi_apb_cov extends uvm_subscriber #(qspi_apb_item_t);
  `uvm_component_utils(qspi_apb_cov)

  typedef qspi_apb_item_t apb_item_t;
  qspi_env_cfg cfg; // Assigned by the parent before child build.

  int unsigned completed_count=0;
  int unsigned aborted_count=0;
  int unsigned back_to_back_count=0;
  int unsigned b2b_rr_count=0;
  int unsigned b2b_rw_count=0;
  int unsigned b2b_wr_count=0;
  int unsigned b2b_ww_count=0;

  // The previous completed transaction provides the direction of the first
  // transfer in a back-to-back pair. No Agent/Driver changes are necessary.
  protected bit have_previous_completed;
  protected bit previous_write;

  covergroup cg_apb_abort with function sample(bit access_phase,bit is_write);
    option.per_instance=1;
    cp_phase: coverpoint access_phase { bins setup={0}; bins access={1}; }
    cp_direction: coverpoint is_write { bins read={0}; bins write={1}; }
    phase_direction: cross cp_phase,cp_direction;
  endgroup

  covergroup cg_apb_proto with function sample(
    bit          is_write,
    bit [3:0]    strb,
    bit [2:0]    protection,
    bit          slave_error,
    int unsigned wait_count,
    bit          back_to_back,
    bit          prev_write
  );
    option.per_instance = 1;

    cp_direction: coverpoint is_write {
      bins read  = {0};
      bins write = {1};
    }

    cp_pstrb_write: coverpoint strb iff (is_write) {
      bins no_bytes  = {4'h0};
      bins all_bytes = {4'hf};
      bins partial[] = {[4'h1:4'he]};
    }

    cp_pprot: coverpoint protection {
      bins values[] = {[0:7]};
    }

    cp_pslverr: coverpoint slave_error {
      bins success = {0};
      bins error   = {1};
    }

    cp_wait: coverpoint wait_count {
      bins zero_wait = {0};
      bins wait_states = {[1:$]};
    }

    cp_back_to_back: coverpoint back_to_back {
      bins after_idle = {0};
      bins direct_next = {1};
    }

    // Cross only transactions whose SETUP directly follows a completion.
    // The four bins correspond to RR, RW, WR, WW, respectively.
    cp_b2b_prev: coverpoint prev_write iff (back_to_back) {
      bins read  = {0};
      bins write = {1};
    }
    cp_b2b_curr: coverpoint is_write iff (back_to_back) {
      bins read  = {0};
      bins write = {1};
    }

    cx_direction_error: cross cp_direction, cp_pslverr;
    cx_direction_wait:  cross cp_direction, cp_wait;
    cx_direction_b2b:   cross cp_direction, cp_back_to_back;
    cx_b2b_transition: cross cp_b2b_prev, cp_b2b_curr;
  endgroup

  function new(string name = "apb_cov", uvm_component parent = null);
    super.new(name, parent);
    cg_apb_proto = new();
    cg_apb_abort = new();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null && !uvm_config_db#(qspi_env_cfg)::get(this, "", "cfg", cfg))
      `uvm_fatal("QSPI_APB_COV", "Missing qspi_env_cfg")
    if (cfg.clk_vif == null)
      `uvm_fatal("QSPI_APB_COV", "Missing clk_vif in qspi_env_cfg")
  endfunction

  virtual function void write(apb_item_t t);
    bit valid_b2b;

    if (t == null || cfg == null || cfg.clk_vif == null) begin
      return;
    end

    if (t.reset_abort) begin
      aborted_count++;
      if (!$isunknown(t.write)) cg_apb_abort.sample(t.abort_in_access,t.write);
      have_previous_completed = 1'b0;
      return;
    end
    if (cfg.clk_vif.rst_n !== 1'b1) return;

    if ($isunknown({t.write,t.strb,t.prot,t.slverr})) begin
      // Do not turn X/Z into zero in the two-state covergroup arguments,
      // or carry an unknown direction into the next back-to-back pair.
      have_previous_completed = 0;
      return;
    end

    valid_b2b = t.back_to_back && have_previous_completed;

    completed_count++;

    if (valid_b2b) begin
      back_to_back_count++;
      case ({previous_write, t.write})
        2'b00: b2b_rr_count++;
        2'b01: b2b_rw_count++;
        2'b10: b2b_wr_count++;
        2'b11: b2b_ww_count++;
      endcase
    end

    cg_apb_proto.sample(t.write, t.strb, t.prot,
                        (t.slverr == 1'b1), t.wait_cycles,
                        valid_b2b, previous_write);

    previous_write = t.write;
    have_previous_completed = 1'b1;
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg == null || cfg.clk_vif == null) return;
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      have_previous_completed = 0;
      previous_write = 0;
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_APB_COV", $sformatf(
      "APB4: completed=%0d aborted=%0d b2b=%0d (RR=%0d RW=%0d WR=%0d WW=%0d) cg_apb_proto=%0.2f%%",
      completed_count, aborted_count, back_to_back_count,
      b2b_rr_count, b2b_rw_count, b2b_wr_count, b2b_ww_count,
      cg_apb_proto.get_inst_coverage()), UVM_HIGH)
  endfunction
endclass : qspi_apb_cov

`endif // QSPI_APB_COV_SV
