`ifndef QSPI_MEM_SERVICE_SV
`define QSPI_MEM_SERVICE_SV

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_mem_service.sv
// Role   : Abstract Memory & Responder Service Contract for Virtual Sequences
// Notes  : Included in qspi_vseq_pkg BEFORE qspi_vsequencer. Concrete class
//          (qspi_tb_mem_service) lives in qspi_env_pkg and is bound by qspi_env.
//          Abstract class omits `uvm_object_utils by design.
// =============================================================================

virtual class qspi_mem_service extends uvm_object;

  function new(string name = "qspi_mem_service");
    super.new(name);
  endfunction

  // --- AXI Slave RAM Backdoor ---
  pure virtual function void clear_ram();
  pure virtual task write_ram_byte(bit [31:0] addr, bit [7:0] data);
  pure virtual function bit [7:0] read_ram_byte(bit [31:0] addr);
  pure virtual task fill_ram_range(bit [31:0] base_addr, int unsigned len, bit [7:0] seed_base);

  // --- External SPI Flash Memory & Device State ---
  // clear_flash(reset_device=0) clears memory array only; reset_device=1 also resets WEL/WIP/SR.
  pure virtual function void clear_flash(bit reset_device = 1'b0);
  pure virtual function void preload_flash_byte(bit [31:0] addr, bit [7:0] data, bit mirror_sb = 1'b1);
  // Little-Endian 32-bit word preload: data[7:0] -> addr+0 .. data[31:24] -> addr+3
  pure virtual function void preload_flash_word(bit [31:0] addr, bit [31:0] data, bit mirror_sb = 1'b1);
  pure virtual function void preload_flash_range(bit [31:0] base_addr, int unsigned len, bit [7:0] seed_base, bit mirror_sb = 1'b1);
  pure virtual function bit [7:0] get_flash_byte(bit [31:0] addr);

  // Explicit override buffer control for non-memory wire-pattern PIO tests only
  pure virtual function void set_flash_override(bit [7:0] bytes[$], bit [7:0] pad = 8'hFF);
  pure virtual function void clear_flash_override();

  // --- AXI Slave Responder Response & Delay Policy ---
  pure virtual function void set_axi_resp(bit [1:0] default_bresp, bit [1:0] default_rresp, int inject_beat = -1);
  pure virtual function void set_axi_delays(int unsigned awready_d, int unsigned wready_d, int unsigned arready_d, int unsigned bvalid_d, int unsigned rvalid_d);
  pure virtual function void reset_axi_knobs();

endclass : qspi_mem_service

`endif // QSPI_MEM_SERVICE_SV
