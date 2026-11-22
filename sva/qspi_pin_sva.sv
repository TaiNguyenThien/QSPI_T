// Physical QSPI Pin SVA Monitor
// Verifies hardware pin reset safety, known control/clock states, and DUT IO2/IO3 activity.
// Spec-level black-box boundary monitor; SCLK CPOL/CPHA timing is checked in qspi_sclk_timing_chk.
`timescale 1ns/1ps

module qspi_pin_sva (
  input logic clk,
  input logic rst_n,
  qspi_if     qspi
);

  // ---------------------------------------------------------------------------
  // 1. Reset Safety (Clocked + Asynchronous NBA Settle)
  // ---------------------------------------------------------------------------
  // Never attach disable iff (!rst_n) to reset assertions.
  a_pin_reset_cs_high: assert property (@(posedge clk)
    (!rst_n || $rose(rst_n)) |-> (qspi.qspi_cs_n === 1'b1))
    else uvm_pkg::uvm_report_error("PIN_SVA_RST_CS",
      "qspi_cs_n was not deasserted (1'b1) during or immediately exiting reset!");

  // Asynchronous reset pulse coverage between rising clock edges
  always @(negedge rst_n) begin
    if (rst_n === 1'b0) begin
      #1ps;
      if (rst_n === 1'b0 && qspi.qspi_cs_n !== 1'b1) begin
        uvm_pkg::uvm_report_error("PIN_SVA_ASYNC_RST_CS",
          "qspi_cs_n failed asynchronous reset deassertion (expected 1'b1 after negedge rst_n)!");
      end
    end
  end

  // ---------------------------------------------------------------------------
  // 2. X/Z Checks Out of Reset
  // ---------------------------------------------------------------------------
  a_pin_cs_known: assert property (@(posedge clk) disable iff (!rst_n)
    !$isunknown(qspi.qspi_cs_n))
    else uvm_pkg::uvm_report_error("PIN_SVA_X_CS",
      "Unknown logic (X/Z) detected on qspi_cs_n out of reset!");

  a_pin_sclk_known: assert property (@(posedge clk) disable iff (!rst_n)
    !$isunknown(qspi.qspi_sclk))
    else uvm_pkg::uvm_report_error("PIN_SVA_X_SCLK",
      "Unknown logic (X/Z) detected on qspi_sclk out of reset!");

  // ---------------------------------------------------------------------------
  // 3. Pin Protocol & DUT-Qualified IO[3:2] Cover Properties
  // ---------------------------------------------------------------------------
  c_pin_cs_assert: cover property (@(posedge clk) disable iff (!rst_n)
    $fell(qspi.qspi_cs_n));

  c_pin_cs_deassert: cover property (@(posedge clk) disable iff (!rst_n)
    $rose(qspi.qspi_cs_n));

  c_pin_sclk_active: cover property (@(posedge clk) disable iff (!rst_n)
    (qspi.qspi_cs_n === 1'b0) && ($rose(qspi.qspi_sclk) || $fell(qspi.qspi_sclk)));

  // Qualify IO2/IO3 activity with flash_drive_en==0 so Flash driving does not create false cover hits.
  c_pin_dut_drive_io2: cover property (@(posedge clk) disable iff (!rst_n)
    (qspi.qspi_cs_n === 1'b0 && qspi.flash_drive_en[2] === 1'b0 &&
     (qspi.qspi_io2 === 1'b0 || qspi.qspi_io2 === 1'b1)));

  c_pin_dut_drive_io3: cover property (@(posedge clk) disable iff (!rst_n)
    (qspi.qspi_cs_n === 1'b0 && qspi.flash_drive_en[3] === 1'b0 &&
     (qspi.qspi_io3 === 1'b0 || qspi.qspi_io3 === 1'b1)));

endmodule : qspi_pin_sva
