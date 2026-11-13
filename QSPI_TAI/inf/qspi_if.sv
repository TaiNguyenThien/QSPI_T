`timescale 1ns/1ps

// Pin names and the flash drive contribution match the teammate agent API.
// Drive helpers are testbench controls, not additional DUT ports.
interface qspi_if();
  logic qspi_sclk;
  logic qspi_cs_n;
  tri   qspi_io0;
  tri   qspi_io1;
  tri   qspi_io2;
  tri   qspi_io3;
  logic [3:0] flash_drive_en = '0;
  logic [3:0] flash_drive_data = '0;

  assign qspi_io0 = flash_drive_en[0] ? flash_drive_data[0] : 1'bz;
  assign qspi_io1 = flash_drive_en[1] ? flash_drive_data[1] : 1'bz;
  assign qspi_io2 = flash_drive_en[2] ? flash_drive_data[2] : 1'bz;
  assign qspi_io3 = flash_drive_en[3] ? flash_drive_data[3] : 1'bz;

  // Passive timing view: sample pins before the clock edge, after the source
  // has had its setup interval. This is interface timing, not DUT behavior.
  clocking monitor_cb @(posedge qspi_sclk or negedge qspi_sclk);
    input #0 qspi_sclk;
    input #1step qspi_cs_n, qspi_io0, qspi_io1, qspi_io2, qspi_io3;
  endclocking
endinterface : qspi_if
