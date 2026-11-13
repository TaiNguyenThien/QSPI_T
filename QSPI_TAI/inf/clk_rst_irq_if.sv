`timescale 1ns/1ps

// One shared DUT clock/reset/IRQ interface for the project and SPI teammate.
// tb_top generates clk/rst_n; the DUT drives irq. Agents only observe them.
interface clk_rst_irq_if();
  logic clk;
  logic rst_n;
  logic irq;
endinterface : clk_rst_irq_if
