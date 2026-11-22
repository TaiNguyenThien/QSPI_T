`timescale 1ns/1ps

// Pin names and the flash drive contribution match the shared QSPI VIP API.
// Drive helpers are testbench controls, not additional DUT ports.
interface qspi_if();
  logic qspi_sclk;
  logic qspi_cs_n;
  tri   qspi_io0;
  tri   qspi_io1;
  tri   qspi_io2;
  tri   qspi_io3;
  logic [3:0] flash_drive_en   = '0;
  logic [3:0] flash_drive_data = '0;

  assign qspi_io0 = flash_drive_en[0] ? flash_drive_data[0] : 1'bz;
  assign qspi_io1 = flash_drive_en[1] ? flash_drive_data[1] : 1'bz;
  assign qspi_io2 = flash_drive_en[2] ? flash_drive_data[2] : 1'bz;
  assign qspi_io3 = flash_drive_en[3] ? flash_drive_data[3] : 1'bz;
endinterface : qspi_if
