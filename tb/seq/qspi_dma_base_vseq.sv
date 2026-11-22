// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_dma_base_vseq.sv
// Role   : Base Virtual Sequence for DMA Mode Verification (Group 4)
// Spec   : VNCHIP_QSPI_Controller_Specification_Rev1.1 & Spec Clarifications 1-5
// =============================================================================

`ifndef QSPI_DMA_BASE_VSEQ_SV
`define QSPI_DMA_BASE_VSEQ_SV

class qspi_dma_base_vseq extends qspi_base_vseq;
  `uvm_object_utils(qspi_dma_base_vseq)

  function new(string name = "qspi_dma_base_vseq");
    super.new(name);
    check_read_data_known = 1'b0;
  endfunction

  task wait_idle(output bit idle_ok, input int unsigned timeout_cycles = 50000);
    logic [31:0] status;
    longint unsigned elapsed;
    idle_ok = 1'b0;
    elapsed = 0;
    while (elapsed < timeout_cycles) begin
      read_csr(QSPI_REG_STATUS, status);
      if (reset_aborted) return;
      if (status[0] === 1'b0) begin
        idle_ok = 1'b1;
        return;
      end
      repeat (4) @(posedge p_sequencer.cfg.clk_vif.clk);
      elapsed += 6;
    end
    `uvm_error("QSPI_DMA_TIMEOUT", $sformatf(
      "Controller timed out waiting for STATUS.BUSY == 0 after %0d cycles (last STATUS=0x%08h)",
      timeout_cycles, status))
  endtask

  // Per Spec Clarification 5.3: CMD_DONE asserts only after both QSPI and DMA finish,
  // and must be checked alongside INT_STAT.ERR to determine success vs failure.
  task wait_dma_done(
    output bit done_success,
    input  bit expect_err = 0,
    input  int unsigned timeout_cycles = 100000
  );
    logic [31:0]     int_stat;
    logic [31:0]     status_val;
    bit              saw_err;
    bit              drain_idle;
    longint unsigned elapsed;
    longint unsigned remaining;
    longint unsigned drain_budget;
    longint unsigned drain_elapsed;

    done_success = 1'b0;
    saw_err      = 1'b0;
    drain_idle   = 1'b0;
    elapsed      = 0;

    while (elapsed < timeout_cycles) begin
      read_csr(QSPI_REG_INT_STAT, int_stat);
      if (reset_aborted) return;
      if ($isunknown(int_stat[2:0])) begin
        `uvm_error("DMA_INT_STAT_XZ", $sformatf("INT_STAT contains unknown (X/Z) bits: 0x%08h", int_stat))
        return;
      end
      if (int_stat[2] === 1'b1) begin
        saw_err       = 1'b1;
        remaining     = (timeout_cycles > elapsed) ? (timeout_cycles - elapsed) : 0;
        drain_budget  = (remaining < 20000) ? remaining : 20000;
        drain_elapsed = 0;
        drain_idle    = 1'b0;
        while (drain_elapsed < drain_budget) begin
          read_csr(QSPI_REG_STATUS, status_val);
          if (reset_aborted) return;
          if (status_val[0] === 1'b0) begin
            drain_idle = 1'b1;
            break;
          end
          repeat (5) @(posedge p_sequencer.cfg.clk_vif.clk);
          drain_elapsed += 7;
        end
        if (!drain_idle) begin
          `uvm_error("DMA_ERR_DRAIN_TIMEOUT", $sformatf(
            "STATUS.BUSY failed to clear after INT_STAT.ERR=1 within %0d-cycle drain budget (last STATUS=0x%08h)",
            drain_budget, status_val))
        end
        done_success = 1'b0;
        break;
      end
      if (!expect_err && int_stat[0] === 1'b1 && int_stat[1] === 1'b0) begin
        `uvm_error("DMA_CMD_DONE_EARLY", "CMD_DONE asserted before DMA_DONE in DMA mode (violates Spec 5.3)")
      end
      if (!expect_err && int_stat[2] === 1'b0 && int_stat[1] === 1'b1 && int_stat[0] === 1'b1) begin
        done_success = 1'b1;
        break;
      end
      repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
      elapsed += 12;
    end

    if (expect_err) begin
      if (!saw_err) begin
        `uvm_error("DMA_ERR_MISS", $sformatf("Expected INT_STAT.ERR=1 on DMA error, got INT_STAT=0x%08h", int_stat))
      end
    end else begin
      if (!done_success) begin
        `uvm_error("DMA_WAIT_TIMEOUT", $sformatf("DMA transfer did not complete cleanly (INT_STAT=0x%08h)", int_stat))
      end
    end
  endtask

  // ---------------------------------------------------------------------------
  // Memory & AXI Slave Service Wrappers (Decoupled via qspi_mem_service)
  // ---------------------------------------------------------------------------
  task write_ram_byte(bit [31:0] addr, bit [7:0] data);
    p_sequencer.mem_svc.write_ram_byte(addr, data);
  endtask

  function bit [7:0] read_ram_byte(bit [31:0] addr);
    return p_sequencer.mem_svc.read_ram_byte(addr);
  endfunction

  task clear_ram();
    p_sequencer.mem_svc.clear_ram();
  endtask

  task fill_ram_range(bit [31:0] base_addr, int unsigned len, bit [7:0] seed = 8'h10);
    p_sequencer.mem_svc.fill_ram_range(base_addr, len, seed);
  endtask

  task write_flash_byte(bit [31:0] addr, bit [7:0] data);
    p_sequencer.mem_svc.preload_flash_byte(addr, data, 1'b1);
  endtask

  task fill_flash_range(bit [31:0] base_addr, int unsigned len, bit [7:0] seed = 8'h20);
    p_sequencer.mem_svc.preload_flash_range(base_addr, len, seed, 1'b1);
  endtask

  // ---------------------------------------------------------------------------
  // Persistent Command LUT Bank Programming Helper
  // ---------------------------------------------------------------------------
  task program_lut_bank(
    input bit [1:0]    lut_idx,
    input bit          dir,
    input bit [7:0]    opcode,
    input int unsigned addr_bytes   = 3,
    input int unsigned cmd_lanes    = 1,
    input int unsigned addr_lanes   = 1,
    input int unsigned data_lanes   = 1,
    input int unsigned dummy_cycles = 0,
    input bit [7:0]    extra_dummy  = 8'h00,
    input bit          mode_en      = 1'b0,
    input bit [7:0]    mode_bits    = 8'h00
  );
    logic [31:0] cfg_val;
    cfg_val       = 32'h0;
    cfg_val[1:0]  = qspi_lanes_to_enc(cmd_lanes);
    cfg_val[3:2]  = qspi_lanes_to_enc(addr_lanes);
    cfg_val[5:4]  = qspi_lanes_to_enc(data_lanes);
    cfg_val[7:6]  = qspi_addr_bytes_to_enc(addr_bytes);
    cfg_val[8]    = mode_en;
    cfg_val[12:9] = dummy_cycles[3:0];
    cfg_val[13]   = dir;

    write_csr(QSPI_REG_LUT_CTRL,  {28'b0, lut_idx, 2'b00});
    write_csr(QSPI_REG_LUT_CFG,   cfg_val);
    write_csr(QSPI_REG_LUT_OP,    {16'h0000, mode_bits, opcode});
    write_csr(QSPI_REG_LUT_DUMMY, {24'h0, extra_dummy});
  endtask

  // ---------------------------------------------------------------------------
  // DMA Configuration & Trigger Helper
  //   Passive qspi_flash_profile_sync mirrors APB CSRs into qspi_agent cfg.
  // ---------------------------------------------------------------------------
  task start_dma(
    input bit          dir,              // 0: TX (RAM->Flash), 1: RX (Flash->RAM)
    input bit [31:0]   mem_addr,         // AXI RAM address
    input bit [31:0]   len,              // Transfer length in bytes
    input bit          incr_addr    = 1, // 1: Incrementing, 0: Fixed
    input logic [7:0]  opcode       = 8'hxx, // Unspecified -> 8'h02 (TX) / 8'h03 (RX)
    input bit [31:0]   flash_addr   = 32'h0010_0000,
    input int unsigned addr_bytes   = 3,
    input int unsigned cmd_lanes    = 1,
    input int unsigned addr_lanes   = 1,
    input int unsigned data_lanes   = 1,
    input int unsigned dummy_cycles = 0,
    input bit [2:0]    clk_div      = 0,
    input bit [1:0]    spi_mode     = 0,
    input bit [1:0]    cs_delay     = 0,
    input bit          lut_en       = 0,
    input bit [1:0]    lut_idx      = 0,
    input bit [4:0]    int_en       = 5'h1F,
    input bit          program_lut  = 1
  );
    logic [31:0] cfg_val, ctrl_val;
    bit [7:0]    eff_opcode;
    bit [7:0]    decoy_op;
    bit          idle_ok;

    eff_opcode = $isunknown(opcode) ? (dir ? 8'h03 : 8'h02) : opcode[7:0];

    wait_idle(idle_ok);
    if (!idle_ok || reset_aborted) return;

    p_sequencer.mem_svc.clear_flash_override();

    // 1. Configure Chip-Select, Interrupts, Clock Divider
    write_csr(QSPI_REG_CS_CTRL,  {28'b0, cs_delay, 1'b0, 1'b1}); // CS_AUTO=1, CS_LEVEL=0
    write_csr(QSPI_REG_INT_STAT, 32'h0000_001F);
    write_csr(QSPI_REG_INT_EN,   {27'b0, int_en});
    write_csr(QSPI_REG_CLK_DIV,  {29'b0, clk_div});

    // 2. Configure DMA Registers
    write_csr(QSPI_REG_DMA_ADDR, mem_addr);
    write_csr(QSPI_REG_DMA_LEN,  len);
    write_csr(QSPI_REG_DMA_CFG,  {26'b0, incr_addr, dir, 4'b0});

    // 3. Configure Command Registers (direct or LUT bank)
    cfg_val       = 32'h0;
    cfg_val[1:0]  = qspi_lanes_to_enc(cmd_lanes);
    cfg_val[3:2]  = qspi_lanes_to_enc(addr_lanes);
    cfg_val[5:4]  = qspi_lanes_to_enc(data_lanes);
    cfg_val[7:6]  = qspi_addr_bytes_to_enc(addr_bytes);
    cfg_val[8]    = 1'b0;
    cfg_val[12:9] = dummy_cycles[3:0];
    cfg_val[13]   = dir;

    write_csr(QSPI_REG_CMD_ADDR, flash_addr);
    write_csr(QSPI_REG_CMD_LEN,  len);

    if (lut_en) begin
      if (program_lut) begin
        decoy_op = (eff_opcode == 8'hA5) ? 8'h5A : 8'hA5;
        write_csr(QSPI_REG_CMD_CFG,   cfg_val ^ 32'h0000_2000);
        write_csr(QSPI_REG_CMD_OP,    {24'h0, decoy_op});
        write_csr(QSPI_REG_CMD_DUMMY, 32'h0000_0055);
        program_lut_bank(lut_idx, dir, eff_opcode, addr_bytes, cmd_lanes, addr_lanes, data_lanes, dummy_cycles);
      end
      write_csr(QSPI_REG_LUT_CTRL, {28'b0, lut_idx, 2'b01}); // LUT_EN=1
    end else begin
      write_csr(QSPI_REG_CMD_CFG,   cfg_val);
      write_csr(QSPI_REG_CMD_OP,    {24'h0, eff_opcode});
      write_csr(QSPI_REG_CMD_DUMMY, 32'h0);
      write_csr(QSPI_REG_LUT_CTRL,  32'h0);
    end

    // 4. Fire Trigger with DMA_EN=1, CMD_TRIGGER=1, ENABLE=1
    ctrl_val    = 32'h0;
    ctrl_val[0] = 1'b1; // ENABLE
    ctrl_val[1] = 1'b0; // XIP_EN = 0
    ctrl_val[2] = (cmd_lanes == 4 || addr_lanes == 4 || data_lanes == 4);
    ctrl_val[3] = spi_mode[1]; // CPOL
    ctrl_val[4] = spi_mode[0]; // CPHA
    ctrl_val[8] = 1'b1; // CMD_TRIGGER
    ctrl_val[9] = 1'b1; // DMA_EN

    write_csr(QSPI_REG_CTRL, ctrl_val);
  endtask

  virtual task request_reset();
    do_request_reset(5);
  endtask

endclass : qspi_dma_base_vseq

`endif // QSPI_DMA_BASE_VSEQ_SV
