// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : axil_sva.sv
// Role   : SVA Protocol Checker for AXI4-Lite Slave Read Interface (XIP Mode)
// Spec   : ARM AMBA AXI4-Lite Protocol Specification & VNCHIP Spec Rev 1.0
// =============================================================================

`timescale 1ns/1ps

module axil_sva #(
  parameter int unsigned MAX_OUTSTANDING = 0
) (axil_if bus);

  // Handshake qualifiers
  wire ar_hs = (bus.arvalid === 1'b1) && (bus.arready === 1'b1);
  wire r_hs  = (bus.rvalid  === 1'b1) && (bus.rready  === 1'b1);

  // Atomic tracking of in-flight accepted AR requests
  // Safe under simultaneous AR and R handshakes on the same clock edge.
  int unsigned outstanding;

  always @(posedge bus.aclk or negedge bus.aresetn) begin
    if (!bus.aresetn) begin
      outstanding <= 0;
    end else begin
      case ({ar_hs, r_hs})
        2'b10:   outstanding <= outstanding + 1;
        2'b01:   if (outstanding != 0) outstanding <= outstanding - 1;
        2'b11:   outstanding <= (outstanding == 0) ? 1 : outstanding;
        default: outstanding <= outstanding;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // 1. Causality & Reset Checks (AMBA AXI4-Lite A3.1.2 & A3.3.1)
  // ---------------------------------------------------------------------------
  // Slave must not assert RVALID without a prior accepted AR request
  a_response_has_request: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    bus.rvalid |-> (outstanding != 0))
    else uvm_pkg::uvm_report_error("XIP_SVA_ORDER",
      "RVALID asserted without a prior accepted AR request!");

  // Optional parameterized max-outstanding check (disabled by default per AMBA AXI4-Lite)
  generate
    if (MAX_OUTSTANDING > 0) begin : gen_max_out
      // Fire once per capacity-exceeding AR handshake instead of spamming every ACLK cycle
      // while outstanding remains above MAX_OUTSTANDING.
      a_xip_max_outstanding: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
        ar_hs |=> (outstanding <= MAX_OUTSTANDING))
        else uvm_pkg::uvm_report_error("XIP_SVA_CAPACITY",
          $sformatf("XIP max outstanding capacity exceeded (outstanding=%0d max=%0d)!",
                    outstanding, MAX_OUTSTANDING));

      // Enforce that no additional AR handshake can occur when outstanding queue is at capacity.
      // Per AMBA AXI4-Lite, ARREADY may stay high while ARVALID=0; capacity violation only
      // occurs if a new ARVALID=1 is accepted while outstanding >= MAX_OUTSTANDING and !r_hs.
      a_xip_no_ar_at_capacity: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
        (outstanding >= MAX_OUTSTANDING && !r_hs && (bus.arvalid === 1'b1)) |-> (bus.arready === 1'b0))
        else uvm_pkg::uvm_report_error("XIP_SVA_CAP_ARREADY",
          $sformatf("AR accepted at outstanding capacity (outstanding=%0d max=%0d)!",
                    outstanding, MAX_OUTSTANDING));
    end
  endgenerate

  // Slave RVALID and Master ARVALID must be low during reset and on the first rising clock edge out of reset (A3.1.2)
  a_dut_reset_rvalid: assert property (@(posedge bus.aclk)
    (!bus.aresetn || $rose(bus.aresetn)) |-> (bus.rvalid === 1'b0))
    else uvm_pkg::uvm_report_error("XIP_SVA_DUT_RESET",
      "Slave RVALID remained asserted during or immediately exiting reset!");

  // Asynchronous reset check for RVALID between rising clock edges
  always @(negedge bus.aresetn) begin
    if (bus.aresetn === 1'b0) begin
      #1ps;
      if (bus.aresetn === 1'b0 && bus.rvalid !== 1'b0) begin
        uvm_pkg::uvm_report_error("XIP_SVA_ASYNC_DUT_RESET",
          "Slave RVALID failed asynchronous reset deassertion (expected 1'b0 after negedge aresetn)!");
      end
    end
  end

  // Master ARVALID must be low during reset and on the first rising edge exiting reset
  a_mst_reset_arvalid: assert property (@(posedge bus.aclk)
    (!bus.aresetn || $rose(bus.aresetn)) |-> (bus.arvalid === 1'b0))
    else uvm_pkg::uvm_report_error("XIP_SVA_MST_RESET",
      "Master ARVALID remained asserted during or immediately exiting reset!");

  // ---------------------------------------------------------------------------
  // 2. Handshake Stability Checks (AMBA AXI4-Lite A3.2.1)
  // ---------------------------------------------------------------------------
  // Once ARVALID is asserted, ARVALID, ARADDR and ARPROT must remain stable until ARREADY
  a_ar_stable: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    (bus.arvalid && !bus.arready) |=> (bus.arvalid && $stable({bus.araddr, bus.arprot})))
    else uvm_pkg::uvm_report_error("XIP_SVA_AR_STABLE",
      "AR channel signals changed or ARVALID dropped while stalled before ARREADY!");

  // Once RVALID is asserted, RVALID, RDATA and RRESP must remain stable until RREADY
  a_r_stable: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    (bus.rvalid && !bus.rready) |=> (bus.rvalid && $stable({bus.rdata, bus.rresp})))
    else uvm_pkg::uvm_report_error("XIP_SVA_R_STABLE",
      "R channel signals (RVALID/RDATA/RRESP) changed or dropped while stalled before RREADY!");

  // ---------------------------------------------------------------------------
  // 3. Known-Value (No X/Z) Checks
  // ---------------------------------------------------------------------------
  a_controls_known: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    !$isunknown({bus.arvalid, bus.arready, bus.rvalid, bus.rready}))
    else uvm_pkg::uvm_report_error("XIP_SVA_X_CTRL",
      "Unknown logic (X/Z) detected on AXI-Lite handshake control signals!");

  a_ar_known: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    bus.arvalid |-> !$isunknown({bus.araddr, bus.arprot}))
    else uvm_pkg::uvm_report_error("XIP_SVA_X_ADDR",
      "Unknown logic (X/Z) detected on ARADDR or ARPROT when ARVALID=1!");

  // ---------------------------------------------------------------------------
  // 4. Response Legitimacy Checks (VNCHIP Spec Rev 1.0 Section 3.3 & 5.7)
  // ---------------------------------------------------------------------------
  // XIP only supports OKAY (2'b00) or SLVERR (2'b10)
  a_response_legal: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    bus.rvalid |-> (bus.rresp inside {2'b00, 2'b10}))
    else uvm_pkg::uvm_report_error("XIP_SVA_RESP_ILLEGAL",
      $sformatf("Illegal RRESP value 2'b%02b (expected OKAY=00 or SLVERR=10)!", bus.rresp));

  // When response is OKAY, RDATA must be fully resolved (no X/Z)
  a_data_known: assert property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    (bus.rvalid && (bus.rresp == 2'b00)) |-> !$isunknown(bus.rdata))
    else uvm_pkg::uvm_report_error("XIP_SVA_X_DATA",
      "Unknown logic (X/Z) detected on RDATA during OKAY response!");

  // ---------------------------------------------------------------------------
  // 4. Functional Protocol Cover Properties
  // ---------------------------------------------------------------------------
  c_axil_ar_hs: cover property (@(posedge bus.aclk) disable iff (!bus.aresetn) ar_hs);
  c_axil_ar_wait: cover property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    (bus.arvalid === 1'b1 && bus.arready === 1'b0));
  c_axil_r_hs: cover property (@(posedge bus.aclk) disable iff (!bus.aresetn) r_hs);
  c_axil_r_stall: cover property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    (bus.rvalid === 1'b1 && bus.rready === 1'b0));
  c_axil_slverr: cover property (@(posedge bus.aclk) disable iff (!bus.aresetn)
    (r_hs && bus.rresp === 2'b10));

endmodule : axil_sva
