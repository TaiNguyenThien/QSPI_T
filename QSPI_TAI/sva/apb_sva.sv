`timescale 1ns/1ps

// APB4 protocol assertions for the QSPI APB interface.
// Interface-level checker: no assumptions about CSR values or wait count.
module apb_sva #(
  parameter int unsigned ADDR_WIDTH = 12,
  parameter int unsigned DATA_WIDTH = 32
) (
  input logic                      pclk,
  input logic                      presetn,
  input logic                      psel,
  input logic                      penable,
  input logic                      pwrite,
  input logic [ADDR_WIDTH-1:0]     paddr,
  input logic [DATA_WIDTH-1:0]     pwdata,
  input logic [DATA_WIDTH/8-1:0]   pstrb,
  input logic [2:0]                pprot,
  input logic                      pready,
  input logic                      pslverr
);
  a_controls_known: assert property (
    @(posedge pclk) disable iff (!presetn)
    !$isunknown({psel,penable})
  ) else uvm_pkg::uvm_report_error("APB_SVA_X", "Unknown PSEL/PENABLE");

  a_request_known: assert property (
    @(posedge pclk) disable iff (!presetn)
    psel |-> !$isunknown({paddr,pwrite,pprot,pstrb})
  ) else uvm_pkg::uvm_report_error("APB_SVA_REQ_X", "Unknown selected request controls");

  for (genvar lane=0;lane<DATA_WIDTH/8;lane++) begin : g_write_known
    a_data_known: assert property (
      @(posedge pclk) disable iff (!presetn)
      psel && pwrite && pstrb[lane] |-> !$isunknown(pwdata[8*lane +: 8])
    ) else uvm_pkg::uvm_report_error("APB_SVA_DATA_X", "Unknown enabled write byte");
  end

  // PENABLE must never be asserted while PSEL is deasserted.
  a_penable_requires_psel: assert property (
    @(posedge pclk) disable iff (!presetn)
    penable |-> psel
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_SELECT", "PENABLE asserted while PSEL is low");

  // Every SETUP phase is followed by ACCESS; control signals remain stable.
  a_setup_to_access: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && !penable) |=>
      (psel && penable && $stable({paddr, pwrite, pprot}))
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_SETUP", "SETUP not followed by stable ACCESS");

  // During a WRITE, data and byte strobes must not change across phases.
  a_setup_write_stable: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && !penable && pwrite) |=>
      $stable({pwdata, pstrb})
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_WSETUP", "Write data/strobes changed from SETUP to ACCESS");

  // A stalled ACCESS must remain in ACCESS with stable control signals.
  a_wait_control_stable: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && penable && !pready) |=>
      (psel && penable && $stable({paddr, pwrite, pprot}))
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_WAIT", "ACCESS controls changed while PREADY was low");

  a_wait_write_stable: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && penable && !pready && pwrite) |=>
      $stable({pwdata, pstrb})
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_WWAIT", "Write data/strobes changed during a wait state");

  // After an ACCESS handshake, the next cycle is IDLE or SETUP, not ACCESS.
  a_complete_leaves_access: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && penable && pready) |=> !penable
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_COMPLETE", "ACCESS continued without a new SETUP phase");

  // APB4 requires all byte strobes low during READ transactions.
  a_read_strobes_zero: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && !pwrite) |-> (pstrb == '0)
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_RSTRB", "PSTRB must be zero during APB READ");

  // Sampled response control signals must be known when they are relevant.
  a_pready_known_in_access: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && penable) |-> !$isunknown(pready)
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_PREADY", "PREADY is X/Z during ACCESS");

  a_pslverr_known_on_completion: assert property (
    @(posedge pclk) disable iff (!presetn)
    (psel && penable && pready) |-> !$isunknown(pslverr)
  ) else uvm_pkg::uvm_report_error(
    "APB_SVA_PSLVERR", "PSLVERR is X/Z at ACCESS completion");

endmodule : apb_sva
