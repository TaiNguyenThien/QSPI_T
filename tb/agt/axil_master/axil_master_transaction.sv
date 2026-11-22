// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_master_transaction.sv
// Role   : Sequence item for AXI4-Lite Master Agent (Read Interface)
// Spec   : ARM AMBA AXI4-Lite Protocol & VNCHIP Spec Rev 1.0 (Section 3.3, 5.7)
// =============================================================================

`ifndef AXIL_MASTER_TRANSACTION_SV
`define AXIL_MASTER_TRANSACTION_SV

typedef enum bit {
  AXIL_RREADY_PRE_ASSERT = 1'b0, // Assert RREADY before RVALID (after optional ready_delay)
  AXIL_RREADY_POST_VALID = 1'b1  // Hold RREADY=0 until RVALID=1, then stall for ready_delay cycles
} axil_rready_mode_e;

typedef enum bit [2:0] {
  AXIL_STATUS_IDLE        = 3'b000,
  AXIL_STATUS_OK          = 3'b001,
  AXIL_STATUS_RESET_ABORT = 3'b010,
  AXIL_STATUS_AR_TIMEOUT  = 3'b011,
  AXIL_STATUS_R_TIMEOUT   = 3'b100,
  AXIL_STATUS_REJECTED    = 3'b101
} axil_completion_status_e;

class axil_master_transaction extends uvm_sequence_item;

  // --- Request & Stimulus Knobs ---
  rand logic [31:0]            addr;
  rand logic [2:0]             prot;
  rand axil_rready_mode_e      rready_mode;
  rand int unsigned            ready_delay; // Stall cycles (post-AR or post-RVALID per rready_mode)
  rand int unsigned            ar_delay;    // Idle cycles inserted before asserting ARVALID
  rand bit                     pipeline_ar; // 1: acknowledge sequence immediately on AR handshake

  // --- Dynamic Timeout Override Knobs ---
  bit                          has_timeout_override;
  bit                          expect_ar_timeout;
  longint unsigned             ar_timeout_override;
  longint unsigned             rvalid_timeout_override;
  longint unsigned             completion_timeout_override;

  // --- Response & Completion Status ---
  logic [31:0]                 data;
  logic [1:0]                  resp;        // 2'b00: OKAY, 2'b10: SLVERR
  axil_completion_status_e     completion_status;
  bit                          reset_abort;
  bit                          timed_out;
  bit                          ar_accepted;
  bit                          r_completed;
  bit                          driver_done;

  // --- Cycle-Accurate Handshake Metrics & Epoch Tracking ---
  int unsigned                 ar_wait;     // Cycles ARVALID=1 && ARREADY=0
  int unsigned                 r_stall;     // Cycles RVALID=1 && RREADY=0
  longint unsigned             birth_epoch; // Reset epoch when transaction was initiated
  longint unsigned             abort_epoch; // Reset epoch when transaction was aborted (0 if normal)
  longint unsigned             ar_accept_cycle;
  longint unsigned             first_rvalid_cycle;
  longint unsigned             r_complete_cycle;

  constraint c_aligned {
    soft addr[1:0] == 2'b00;
  }

  constraint c_rready_ctrl {
    soft rready_mode == AXIL_RREADY_PRE_ASSERT;
    soft ready_delay == 0;
    (rready_mode == AXIL_RREADY_POST_VALID) -> (ready_delay >= 0);
    ready_delay <= 1024;
  }

  constraint c_ar_ctrl {
    soft ar_delay    == 0;
    ar_delay         <= 256;
    soft pipeline_ar == 1'b0;
  }

  constraint c_prot {
    soft prot == 3'b000;
  }

  // UVM Automation: Only compare true bus payload/protocol fields.
  // Stimulus knobs, internal completion flags, and diagnostic metrics are excluded with UVM_NOCOMPARE.
  `uvm_object_utils_begin(axil_master_transaction)
    `uvm_field_int(addr,                         UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(prot,                         UVM_DEFAULT | UVM_BIN)
    `uvm_field_int(data,                         UVM_DEFAULT | UVM_HEX)
    `uvm_field_int(resp,                         UVM_DEFAULT | UVM_BIN)
    `uvm_field_enum(axil_completion_status_e,    completion_status,           UVM_DEFAULT)
    `uvm_field_enum(axil_rready_mode_e,          rready_mode,                 UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(ready_delay,                  UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(ar_delay,                     UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(pipeline_ar,                  UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(has_timeout_override,         UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(expect_ar_timeout,            UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(ar_timeout_override,          UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(rvalid_timeout_override,      UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(completion_timeout_override,  UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(reset_abort,                  UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(timed_out,                    UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(ar_accepted,                  UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(r_completed,                  UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(driver_done,                  UVM_DEFAULT | UVM_NOCOMPARE)
    `uvm_field_int(ar_wait,                      UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(r_stall,                      UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(birth_epoch,                  UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(abort_epoch,                  UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(ar_accept_cycle,              UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(first_rvalid_cycle,           UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
    `uvm_field_int(r_complete_cycle,             UVM_DEFAULT | UVM_DEC | UVM_NOCOMPARE)
  `uvm_object_utils_end

  function new(string name = "axil_master_transaction");
    super.new(name);
    data               = 32'h0;
    resp               = 2'b00;
    completion_status  = AXIL_STATUS_IDLE;
    reset_abort        = 1'b0;
    timed_out          = 1'b0;
    ar_accepted        = 1'b0;
    r_completed        = 1'b0;
    driver_done        = 1'b0;
    ar_wait            = 0;
    r_stall            = 0;
    birth_epoch        = 0;
    abort_epoch        = 0;
    ar_accept_cycle    = 0;
    first_rvalid_cycle = 0;
    r_complete_cycle   = 0;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    axil_master_transaction rhs_;
    if (!$cast(rhs_, rhs)) begin
      `uvm_fatal("AXIL_COPY", "Cast failed in do_copy")
      return;
    end
    super.do_copy(rhs);
    this.addr                        = rhs_.addr;
    this.prot                        = rhs_.prot;
    this.rready_mode                 = rhs_.rready_mode;
    this.ready_delay                 = rhs_.ready_delay;
    this.ar_delay                    = rhs_.ar_delay;
    this.pipeline_ar                 = rhs_.pipeline_ar;
    this.has_timeout_override        = rhs_.has_timeout_override;
    this.expect_ar_timeout           = rhs_.expect_ar_timeout;
    this.ar_timeout_override         = rhs_.ar_timeout_override;
    this.rvalid_timeout_override     = rhs_.rvalid_timeout_override;
    this.completion_timeout_override = rhs_.completion_timeout_override;
    this.data                        = rhs_.data;
    this.resp                        = rhs_.resp;
    this.completion_status           = rhs_.completion_status;
    this.reset_abort                 = rhs_.reset_abort;
    this.timed_out                   = rhs_.timed_out;
    this.ar_accepted                 = rhs_.ar_accepted;
    this.r_completed                 = rhs_.r_completed;
    this.driver_done                 = rhs_.driver_done;
    this.ar_wait                     = rhs_.ar_wait;
    this.r_stall                     = rhs_.r_stall;
    this.birth_epoch                 = rhs_.birth_epoch;
    this.abort_epoch                 = rhs_.abort_epoch;
    this.ar_accept_cycle             = rhs_.ar_accept_cycle;
    this.first_rvalid_cycle          = rhs_.first_rvalid_cycle;
    this.r_complete_cycle            = rhs_.r_complete_cycle;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    axil_master_transaction rhs_;
    if (!$cast(rhs_, rhs)) return 1'b0;
    if (!super.do_compare(rhs, comparer)) return 1'b0;
    return (this.addr === rhs_.addr) &&
           (this.prot === rhs_.prot) &&
           (this.data === rhs_.data) &&
           (this.resp === rhs_.resp) &&
           (this.completion_status === rhs_.completion_status);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "AR[addr=0x%08h prot=%03b pipe=%0b ar_wait=%0d acc=%0b] -> R[data=0x%08h resp=%02b mode=%s r_stall=%0d status=%s]",
      addr, prot, pipeline_ar, ar_wait, ar_accepted, data, resp, rready_mode.name(),
      r_stall, completion_status.name());
  endfunction

endclass : axil_master_transaction

`endif // AXIL_MASTER_TRANSACTION_SV
