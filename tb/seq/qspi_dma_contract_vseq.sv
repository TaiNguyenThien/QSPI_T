// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_dma_contract_vseq.sv
// Role   : Suite of 30 Standardized DMA Verification Scenarios (Group 4)
// Spec   : VNCHIP_QSPI_Controller_Specification_Rev1.1 & Spec Clarifications 1-5
// =============================================================================

`ifndef QSPI_DMA_CONTRACT_VSEQ_SV
`define QSPI_DMA_CONTRACT_VSEQ_SV

class qspi_dma_contract_vseq extends qspi_dma_base_vseq;
  `uvm_object_utils(qspi_dma_contract_vseq)

  string selection = "smoke";
  int unsigned dma_count = 0;

  function new(string name = "qspi_dma_contract_vseq");
    super.new(name);
  endfunction

  // Helper: execute a clean 4-byte post-error/reset recovery transfer
  task run_recovery_transfer(
    bit [31:0] ram_addr   = 32'h0001_F000,
    bit [31:0] flash_addr = 32'h001F_0000
  );
    bit ok;
    fill_flash_range(flash_addr, 4, 8'hC0);
    start_dma(.dir(1), .mem_addr(ram_addr), .len(4), .incr_addr(1),
              .opcode(8'h03), .flash_addr(flash_addr));
    wait_dma_done(ok);
    dma_count++;
  endtask

  virtual task body();
    bit dma_success;
    logic [31:0] rdata, rdata2;

    `uvm_info("DMA_VSEQ", $sformatf("=== Executing DMA Scenario: %s ===", selection), UVM_LOW)

    case (selection)
      // -----------------------------------------------------------------------
      // SMOKE: Basic 4-byte TX and 4-byte RX DMA
      // -----------------------------------------------------------------------
      "smoke": begin
        clear_ram();
        write_ram_byte(32'h0000_1000, 8'hA1);
        write_ram_byte(32'h0000_1001, 8'hB2);
        write_ram_byte(32'h0000_1002, 8'hC3);
        write_ram_byte(32'h0000_1003, 8'hD4);

        start_dma(.dir(0), .mem_addr(32'h0000_1000), .len(4), .incr_addr(1),
                  .opcode(8'h02), .flash_addr(32'h0010_0000));
        wait_dma_done(dma_success);
        dma_count++;

        write_flash_byte(32'h0020_0000, 8'h11);
        write_flash_byte(32'h0020_0001, 8'h22);
        write_flash_byte(32'h0020_0002, 8'h33);
        write_flash_byte(32'h0020_0003, 8'h44);

        start_dma(.dir(1), .mem_addr(32'h0000_2000), .len(4), .incr_addr(1),
                  .opcode(8'h03), .flash_addr(32'h0020_0000));
        wait_dma_done(dma_success);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_REG_01 (dma_01): Reset and RW/RO of DMA registers
      // -----------------------------------------------------------------------
      "dma_01", "TC_DMA_REG_01": begin
        request_reset();
        read_csr(QSPI_REG_DMA_ADDR, rdata);
        read_csr(QSPI_REG_DMA_LEN,  rdata);
        read_csr(QSPI_REG_DMA_CFG,  rdata);

        write_csr(QSPI_REG_DMA_ADDR, 32'h1234_5678);
        read_csr(QSPI_REG_DMA_ADDR,  rdata);

        write_csr(QSPI_REG_DMA_LEN, 32'h0000_0100);
        read_csr(QSPI_REG_DMA_LEN,  rdata);

        // Write all 1s to verify RW bits [5:4] and RO/0 reserved bits [31:6]
        write_csr(QSPI_REG_DMA_CFG, 32'hFFFF_FF30);
        read_csr(QSPI_REG_DMA_CFG,  rdata);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_REG_02: DMA Register RW, RO STATUS protection, and W1C Access
      // -----------------------------------------------------------------------
      "TC_DMA_REG_02": begin
        request_reset();
        write_csr(QSPI_REG_DMA_CFG,  32'hFFFF_FF30);
        write_csr(QSPI_REG_DMA_ADDR, 32'hA5A5_5A50);
        write_csr(QSPI_REG_DMA_LEN,  32'h0000_0400);
        write_csr(QSPI_REG_STATUS,   32'hFFFF_FFFF);
        read_csr(QSPI_REG_DMA_CFG,   rdata);
        read_csr(QSPI_REG_DMA_ADDR,  rdata);
        read_csr(QSPI_REG_DMA_LEN,   rdata);
        read_csr(QSPI_REG_STATUS,    rdata);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_REG_03: CTRL.DMA_EN & CMD_TRIGGER Execution and Return to IDLE
      // -----------------------------------------------------------------------
      "TC_DMA_REG_03": begin
        fill_flash_range(32'h0010_0000, 4, 8'h55);
        start_dma(.dir(1), .mem_addr(32'h0000_3000), .len(4), .opcode(8'h03), .flash_addr(32'h0010_0000));
        wait_dma_done(dma_success);
        read_csr(QSPI_REG_STATUS, rdata);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_REG_04: CSR Write Attempt During Active DMA Busy Window
      // -----------------------------------------------------------------------
      "TC_DMA_REG_04": begin
        fill_flash_range(32'h0010_0200, 32, 8'h5A);
        start_dma(.dir(1), .mem_addr(32'h0000_3200), .len(32), .opcode(8'h03), .flash_addr(32'h0010_0200));
        repeat (15) @(posedge p_sequencer.cfg.clk_vif.clk);
        write_csr(QSPI_REG_DMA_LEN, 32'h0000_0020);
        wait_dma_done(dma_success);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_RX_01 (dma_02): Aligned RX DMA across RX_FIFO depth (4..64B)
      // -----------------------------------------------------------------------
      "dma_02", "TC_DMA_RX_01": begin
        int unsigned rx_lens[6];
        bit [31:0] r_addr, f_addr;
        rx_lens = '{4, 12, 16, 20, 32, 64};
        foreach (rx_lens[k]) begin
          r_addr = 32'h0000_4000 + (k * 32'h100);
          f_addr = 32'h0010_0000 + (k * 32'h100);
          fill_flash_range(f_addr, rx_lens[k], 8'(8'h10 + k * 8'h11));
          start_dma(.dir(1), .mem_addr(r_addr), .len(rx_lens[k]), .incr_addr(1),
                    .opcode(8'h03), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_RX_02 (dma_03): RX DMA Fixed Address Mode (INCR_ADDR=0)
      // -----------------------------------------------------------------------
      "dma_03", "TC_DMA_RX_02": begin
        int unsigned fixed_lens[2];
        bit [31:0] r_addr, f_addr;
        fixed_lens = '{4, 16};
        foreach (fixed_lens[k]) begin
          r_addr = 32'h0000_5000 + (k * 32'h100);
          f_addr = 32'h0010_1000 + (k * 32'h100);
          for (int unsigned b = 0; b < 16; b++)
            write_ram_byte(r_addr + b, 8'hAA);
          for (int unsigned b = 0; b < fixed_lens[k]; b++)
            write_flash_byte(f_addr + b, 8'h55);
          start_dma(.dir(1), .mem_addr(r_addr), .len(fixed_lens[k]), .incr_addr(0),
                    .opcode(8'h03), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_RX_03 (dma_04): Unaligned RX DMA (DMA_LEN % 4 != 0) & WSTRB
      // -----------------------------------------------------------------------
      "dma_04", "TC_DMA_RX_03": begin
        int unsigned unaligned_lens[9];
        bit [31:0] r_addr, f_addr;
        int unsigned aligned_span;
        unaligned_lens = '{1, 2, 3, 5, 6, 7, 17, 18, 19};
        foreach (unaligned_lens[k]) begin
          r_addr       = 32'h0000_6000 + (k * 32'h100);
          f_addr       = 32'h0010_2000 + (k * 32'h100);
          aligned_span = ((unaligned_lens[k] + 3) / 4) * 4;
          for (int unsigned b = 0; b < aligned_span; b++)
            write_ram_byte(r_addr + b, 8'hAA);
          for (int unsigned b = 0; b < unaligned_lens[k]; b++)
            write_flash_byte(f_addr + b, 8'h55);
          start_dma(.dir(1), .mem_addr(r_addr), .len(unaligned_lens[k]), .incr_addr(1),
                    .opcode(8'h03), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_TX_01 (dma_05): Aligned TX DMA across TX_FIFO depth (4..64B)
      // -----------------------------------------------------------------------
      "dma_05", "TC_DMA_TX_01": begin
        int unsigned tx_lens[6];
        bit [31:0] r_addr, f_addr;
        tx_lens = '{4, 12, 16, 20, 32, 64};
        foreach (tx_lens[k]) begin
          r_addr = 32'h0000_7000 + (k * 32'h100);
          f_addr = 32'h0010_4000 + (k * 32'h100);
          fill_ram_range(r_addr, tx_lens[k], 8'(8'h50 + k * 8'h09));
          start_dma(.dir(0), .mem_addr(r_addr), .len(tx_lens[k]), .incr_addr(1),
                    .opcode(8'h02), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_TX_02 (dma_06): TX DMA Fixed Address Mode (INCR_ADDR=0)
      // -----------------------------------------------------------------------
      "dma_06", "TC_DMA_TX_02": begin
        int unsigned fixed_lens[2];
        bit [31:0] r_addr, f_addr;
        int unsigned aligned_span;
        fixed_lens = '{4, 16};
        foreach (fixed_lens[k]) begin
          r_addr       = 32'h0000_8000 + (k * 32'h100);
          f_addr       = 32'h0010_5000 + (k * 32'h100);
          aligned_span = ((fixed_lens[k] + 3) / 4) * 4;
          for (int unsigned b = 0; b < aligned_span + 4; b++)
            write_flash_byte(f_addr + b, 8'hAA);
          write_ram_byte(r_addr + 0, 8'h55);
          write_ram_byte(r_addr + 1, 8'hAA);
          write_ram_byte(r_addr + 2, 8'h33);
          write_ram_byte(r_addr + 3, 8'hCC);
          start_dma(.dir(0), .mem_addr(r_addr), .len(fixed_lens[k]), .incr_addr(0),
                    .opcode(8'h02), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_TX_03 (dma_07): Unaligned TX DMA (DMA_LEN % 4 != 0)
      // -----------------------------------------------------------------------
      "dma_07", "TC_DMA_TX_03": begin
        int unsigned unaligned_lens[9];
        bit [31:0] r_addr, f_addr;
        int unsigned aligned_span;
        unaligned_lens = '{1, 2, 3, 5, 6, 7, 17, 18, 19};
        foreach (unaligned_lens[k]) begin
          r_addr       = 32'h0000_9000 + (k * 32'h100);
          f_addr       = 32'h0010_6000 + (k * 32'h100);
          aligned_span = ((unaligned_lens[k] + 3) / 4) * 4;
          for (int unsigned b = 0; b < aligned_span + 4; b++)
            write_flash_byte(f_addr + b, 8'hAA);
          fill_ram_range(r_addr, aligned_span, 8'(8'h60 + k * 8'h05));
          start_dma(.dir(0), .mem_addr(r_addr), .len(unaligned_lens[k]), .incr_addr(1),
                    .opcode(8'h02), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_CFG_01 (dma_08): Direct vs Persistent 4-Bank Command LUT Dispatch
      //   Programs 4 independent LUT banks ONCE, poisons direct CSRs, then
      //   revisits banks in shuffled order without rewriting banks (Spec 2364).
      // -----------------------------------------------------------------------
      "dma_08", "TC_DMA_CFG_01": begin
        bit [1:0]    visit_order[6];
        bit [31:0]   ram_a, fls_a;
        visit_order = '{2'd2, 2'd0, 2'd3, 2'd1, 2'd2, 2'd3};

        // 1. Direct mode TX and RX
        fill_ram_range(32'h0000_A000, 8, 8'h70);
        start_dma(.dir(0), .mem_addr(32'h0000_A000), .len(8), .lut_en(0),
                  .opcode(8'h02), .flash_addr(32'h0010_7000));
        wait_dma_done(dma_success);
        dma_count++;

        fill_flash_range(32'h0010_7100, 8, 8'h78);
        start_dma(.dir(1), .mem_addr(32'h0000_A100), .len(8), .lut_en(0),
                  .opcode(8'h03), .flash_addr(32'h0010_7100));
        wait_dma_done(dma_success);
        dma_count++;

        // 2. Program all 4 distinct LUT banks ONCE
        program_lut_bank(.lut_idx(2'd0), .dir(1'b0), .opcode(8'h02), .addr_bytes(3), .data_lanes(1), .dummy_cycles(0));
        program_lut_bank(.lut_idx(2'd1), .dir(1'b1), .opcode(8'h03), .addr_bytes(3), .data_lanes(1), .dummy_cycles(0));
        program_lut_bank(.lut_idx(2'd2), .dir(1'b1), .opcode(8'h3B), .addr_bytes(3), .data_lanes(2), .dummy_cycles(8));
        program_lut_bank(.lut_idx(2'd3), .dir(1'b1), .opcode(8'h6B), .addr_bytes(3), .data_lanes(4), .dummy_cycles(8));

        // 3. Poison direct command CSRs to prove LUT banks override direct CSRs
        write_csr(QSPI_REG_CMD_CFG,   32'h0000_1F55);
        write_csr(QSPI_REG_CMD_OP,    32'h0000_00A5);
        write_csr(QSPI_REG_CMD_DUMMY, 32'h0000_0033);

        // 4. Dispatch persistent LUT banks in shuffled order with program_lut=0
        foreach (visit_order[k]) begin
          ram_a = 32'h0000_A200 + k * 32'h40;
          fls_a = 32'h0010_7200 + k * 32'h40;
          case (visit_order[k])
            2'd0: begin
              fill_ram_range(ram_a, 8, 8'(8'h80 + k * 8));
              start_dma(.dir(0), .mem_addr(ram_a), .len(8), .data_lanes(1),
                        .opcode(8'h02), .flash_addr(fls_a),
                        .lut_en(1), .lut_idx(2'd0), .program_lut(0));
            end
            2'd1: begin
              fill_flash_range(fls_a, 8, 8'(8'h90 + k * 8));
              start_dma(.dir(1), .mem_addr(ram_a), .len(8), .data_lanes(1),
                        .opcode(8'h03), .flash_addr(fls_a),
                        .lut_en(1), .lut_idx(2'd1), .program_lut(0));
            end
            2'd2: begin
              fill_flash_range(fls_a, 8, 8'(8'hA0 + k * 8));
              start_dma(.dir(1), .mem_addr(ram_a), .len(8), .data_lanes(2), .dummy_cycles(8),
                        .opcode(8'h3B), .flash_addr(fls_a),
                        .lut_en(1), .lut_idx(2'd2), .program_lut(0));
            end
            default: begin
              fill_flash_range(fls_a, 8, 8'(8'hB0 + k * 8));
              start_dma(.dir(1), .mem_addr(ram_a), .len(8), .data_lanes(4), .dummy_cycles(8),
                        .opcode(8'h6B), .flash_addr(fls_a),
                        .lut_en(1), .lut_idx(2'd3), .program_lut(0));
            end
          endcase
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_CFG_02 (dma_09): Multi-lane configurations (1-1-1..1-4-4)
      // -----------------------------------------------------------------------
      "dma_09", "TC_DMA_CFG_02": begin
        fill_flash_range(32'h0010_8000, 8, 8'h11);
        start_dma(.dir(1), .mem_addr(32'h0000_B000), .len(8), .cmd_lanes(1), .addr_lanes(1), .data_lanes(1),
                  .opcode(8'h03), .flash_addr(32'h0010_8000));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_8020, 8, 8'h22);
        start_dma(.dir(1), .mem_addr(32'h0000_B020), .len(8), .cmd_lanes(1), .addr_lanes(1), .data_lanes(1),
                  .opcode(8'h0B), .dummy_cycles(8), .flash_addr(32'h0010_8020));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_8040, 8, 8'h33);
        start_dma(.dir(1), .mem_addr(32'h0000_B040), .len(8), .cmd_lanes(1), .addr_lanes(1), .data_lanes(2),
                  .opcode(8'h3B), .dummy_cycles(8), .flash_addr(32'h0010_8040));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_8060, 8, 8'h44);
        start_dma(.dir(1), .mem_addr(32'h0000_B060), .len(8), .cmd_lanes(1), .addr_lanes(2), .data_lanes(2),
                  .opcode(8'h3B), .dummy_cycles(4), .flash_addr(32'h0010_8060));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_8080, 8, 8'h55);
        start_dma(.dir(1), .mem_addr(32'h0000_B080), .len(8), .cmd_lanes(1), .addr_lanes(1), .data_lanes(4),
                  .opcode(8'h6B), .dummy_cycles(8), .flash_addr(32'h0010_8080));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_80A0, 8, 8'h66);
        start_dma(.dir(1), .mem_addr(32'h0000_B0A0), .len(8), .cmd_lanes(1), .addr_lanes(4), .data_lanes(4),
                  .opcode(8'hEB), .dummy_cycles(6), .flash_addr(32'h0010_80A0));
        wait_dma_done(dma_success); dma_count++;

        fill_ram_range(32'h0000_B0C0, 8, 8'h77);
        start_dma(.dir(0), .mem_addr(32'h0000_B0C0), .len(8), .cmd_lanes(1), .addr_lanes(1), .data_lanes(1),
                  .opcode(8'h02), .flash_addr(32'h0010_80C0));
        wait_dma_done(dma_success); dma_count++;

        fill_ram_range(32'h0000_B0E0, 8, 8'h88);
        start_dma(.dir(0), .mem_addr(32'h0000_B0E0), .len(8), .cmd_lanes(1), .addr_lanes(1), .data_lanes(4),
                  .opcode(8'h32), .flash_addr(32'h0010_80E0));
        wait_dma_done(dma_success); dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_CFG_03 (dma_10): Timing sweep (SPI modes 0-3, CLK_DIV 0-7, CS_DELAY 0-3)
      // -----------------------------------------------------------------------
      "dma_10", "TC_DMA_CFG_03": begin
        bit [31:0] r_addr, f_addr;
        for (int m = 0; m < 4; m++) begin
          for (int d = 0; d < 8; d++) begin
            r_addr = 32'h0000_C000 + ((m * 8 + d) * 16);
            f_addr = 32'h0010_9000 + ((m * 8 + d) * 16);
            fill_ram_range(r_addr, 4, 8'(m * 16 + d));
            start_dma(.dir(0), .mem_addr(r_addr), .len(4), .clk_div(3'(d)),
                      .spi_mode(2'(m)), .cs_delay(2'(d % 4)), .opcode(8'h02), .flash_addr(f_addr));
            wait_dma_done(dma_success);
            dma_count++;
          end
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_AXI_01 (dma_11): AXI burst type INCR & 4-byte beats
      // -----------------------------------------------------------------------
      "dma_11", "TC_DMA_AXI_01": begin
        fill_flash_range(32'h0010_A000, 16, 8'hA0);
        start_dma(.dir(1), .mem_addr(32'h0000_D000), .len(16), .opcode(8'h03), .flash_addr(32'h0010_A000));
        wait_dma_done(dma_success); dma_count++;

        fill_ram_range(32'h0000_D100, 16, 8'hA8);
        start_dma(.dir(0), .mem_addr(32'h0000_D100), .len(16), .opcode(8'h02), .flash_addr(32'h0010_A100));
        wait_dma_done(dma_success); dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_AXI_02 (dma_12): Large burst length reachability (1024B)
      // -----------------------------------------------------------------------
      "dma_12", "TC_DMA_AXI_02": begin
        fill_flash_range(32'h0010_B000, 1024, 8'hB0);
        start_dma(.dir(1), .mem_addr(32'h0000_E000), .len(1024), .opcode(8'h03), .flash_addr(32'h0010_B000));
        wait_dma_done(dma_success, 0, 500000);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_AXI_03 (dma_13): 5-channel AXI4 backpressure delays (incl. AWREADY)
      // -----------------------------------------------------------------------
      "dma_13", "TC_DMA_AXI_03": begin
        p_sequencer.mem_svc.set_axi_delays(3, 3, 4, 2, 2);
        fill_flash_range(32'h0010_C000, 16, 8'hC1);
        start_dma(.dir(1), .mem_addr(32'h0000_F000), .len(16), .opcode(8'h03), .flash_addr(32'h0010_C000));
        wait_dma_done(dma_success); dma_count++;

        fill_ram_range(32'h0000_F100, 16, 8'hC2);
        start_dma(.dir(0), .mem_addr(32'h0000_F100), .len(16), .opcode(8'h02), .flash_addr(32'h0010_C100));
        wait_dma_done(dma_success); dma_count++;

        p_sequencer.mem_svc.reset_axi_knobs();
      end

      // -----------------------------------------------------------------------
      // TC_DMA_AXI_04 (dma_14): 4KB boundary crossing prevention
      // -----------------------------------------------------------------------
      "dma_14", "TC_DMA_AXI_04": begin
        fill_flash_range(32'h0010_D000, 16, 8'hD0);
        start_dma(.dir(1), .mem_addr(32'h0000_1000), .len(16), .opcode(8'h03), .flash_addr(32'h0010_D000));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_D100, 16, 8'hD1);
        start_dma(.dir(1), .mem_addr(32'h0000_0FF0), .len(16), .opcode(8'h03), .flash_addr(32'h0010_D100));
        wait_dma_done(dma_success); dma_count++;

        fill_flash_range(32'h0010_D200, 32, 8'hD2);
        start_dma(.dir(1), .mem_addr(32'h0000_0FF0), .len(32), .opcode(8'h03), .flash_addr(32'h0010_D200));
        wait_dma_done(dma_success); dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_AXI_05 (dma_15): Back-to-back DMA transfers
      // -----------------------------------------------------------------------
      "dma_15", "TC_DMA_AXI_05": begin
        bit dir_b;
        bit [31:0] r_addr, f_addr;
        for (int i = 0; i < 4; i++) begin
          dir_b  = bit'(i % 2);
          r_addr = 32'h0001_0000 + i * 64;
          f_addr = 32'h0010_E000 + i * 64;
          if (dir_b) fill_flash_range(f_addr, 16, 8'(8'hE0 + i));
          else       fill_ram_range(r_addr, 16, 8'(8'hE8 + i));
          start_dma(.dir(dir_b), .mem_addr(r_addr), .len(16),
                    .opcode(dir_b ? 8'h03 : 8'h02), .flash_addr(f_addr));
          wait_dma_done(dma_success);
          dma_count++;
        end
      end

      // -----------------------------------------------------------------------
      // TC_DMA_INT_01 (dma_16): Normal completion interrupt (DMA_DONE & CMD_DONE)
      // -----------------------------------------------------------------------
      "dma_16", "TC_DMA_INT_01": begin
        fill_flash_range(32'h0011_0000, 8, 8'h41);
        start_dma(.dir(1), .mem_addr(32'h0001_1000), .len(8), .opcode(8'h03),
                  .flash_addr(32'h0011_0000), .int_en(5'h1F));
        wait_dma_done(dma_success);
        read_csr(QSPI_REG_INT_STAT, rdata);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_INT_02 (dma_17): Interrupt masking via INT_EN
      // -----------------------------------------------------------------------
      "dma_17", "TC_DMA_INT_02": begin
        fill_flash_range(32'h0011_1000, 8, 8'h42);
        start_dma(.dir(1), .mem_addr(32'h0001_2000), .len(8), .opcode(8'h03),
                  .flash_addr(32'h0011_1000), .int_en(5'h00));
        wait_dma_done(dma_success);
        read_csr(QSPI_REG_INT_STAT, rdata);
        write_csr(QSPI_REG_INT_EN, 32'h0000_0002);
        repeat (2) @(posedge p_sequencer.cfg.clk_vif.clk);
        read_csr(QSPI_REG_INT_STAT, rdata);
        write_csr(QSPI_REG_INT_EN, 32'h0000_0000);
        repeat (2) @(posedge p_sequencer.cfg.clk_vif.clk);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_INT_03 (dma_18): Per-bit W1C clearing of DMA_DONE & CMD_DONE
      // -----------------------------------------------------------------------
      "dma_18", "TC_DMA_INT_03": begin
        fill_flash_range(32'h0011_2000, 8, 8'h43);
        start_dma(.dir(1), .mem_addr(32'h0001_3000), .len(8), .opcode(8'h03),
                  .flash_addr(32'h0011_2000), .int_en(5'h03));
        wait_dma_done(dma_success);
        // 1. Write 0 -> no-op, both bits [1:0] remain latched
        write_csr(QSPI_REG_INT_STAT, 32'h0);
        read_csr(QSPI_REG_INT_STAT, rdata);
        // 2. Per-bit W1C on DMA_DONE (bit 1) -> clears bit 1 only, preserves CMD_DONE (bit 0)
        write_csr(QSPI_REG_INT_STAT, 32'h2);
        read_csr(QSPI_REG_INT_STAT, rdata2);
        if (rdata2[1:0] !== 2'b01) begin
          `uvm_error("DMA_INT_W1C", $sformatf(
            "Spec per-bit W1C violation: writing INT_STAT=0x2 expected [1:0]==2'b01, got 0x%08h", rdata2))
        end
        // 3. Per-bit W1C on CMD_DONE (bit 0) -> clears bit 0 and deasserts irq
        write_csr(QSPI_REG_INT_STAT, 32'h1);
        read_csr(QSPI_REG_INT_STAT, rdata);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_INT_04 (dma_19): Error interrupt latching on AXI DECERR
      // -----------------------------------------------------------------------
      "dma_19", "TC_DMA_INT_04": begin
        p_sequencer.mem_svc.set_axi_resp(2'b11, 2'b00);
        start_dma(.dir(1), .mem_addr(32'h0001_4000), .len(8), .opcode(8'h03), .int_en(5'h04));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(10000));
        read_csr(QSPI_REG_INT_STAT, rdata);
        p_sequencer.mem_svc.reset_axi_knobs();
        write_csr(QSPI_REG_INT_STAT, 32'h04);
        read_csr(QSPI_REG_INT_STAT, rdata2);
        request_reset();
        run_recovery_transfer();
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_01 (dma_20): AXI SLVERR (2'b10) on RX & TX + recovery
      // -----------------------------------------------------------------------
      "dma_20", "TC_DMA_ERR_01": begin
        p_sequencer.mem_svc.set_axi_resp(2'b10, 2'b00);
        start_dma(.dir(1), .mem_addr(32'h0001_5000), .len(16), .opcode(8'h03));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(10000));
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();
        run_recovery_transfer(32'h0001_5100, 32'h0015_0100);

        p_sequencer.mem_svc.set_axi_resp(2'b00, 2'b10);
        start_dma(.dir(0), .mem_addr(32'h0001_5200), .len(16), .opcode(8'h02));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(10000));
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();
        run_recovery_transfer(32'h0001_5300, 32'h0015_0300);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_02 (dma_21): AXI DECERR (2'b11) on TX & RX + recovery
      // -----------------------------------------------------------------------
      "dma_21", "TC_DMA_ERR_02": begin
        p_sequencer.mem_svc.set_axi_resp(2'b00, 2'b11);
        start_dma(.dir(0), .mem_addr(32'h0001_6000), .len(16), .opcode(8'h02));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(10000));
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();
        run_recovery_transfer(32'h0001_6100, 32'h0016_0100);

        p_sequencer.mem_svc.set_axi_resp(2'b11, 2'b00);
        start_dma(.dir(1), .mem_addr(32'h0001_6200), .len(16), .opcode(8'h03));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(10000));
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();
        run_recovery_transfer(32'h0001_6300, 32'h0016_0300);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_03 (dma_22): FIFO Backpressure, RX Overrun, TX Underrun
      // -----------------------------------------------------------------------
      "dma_22", "TC_DMA_ERR_03": begin
        // 1. Moderate WREADY stall across >16B FIFO depth (must complete cleanly)
        p_sequencer.mem_svc.set_axi_delays(0, 8, 0, 0, 0);
        fill_flash_range(32'h0011_7000, 32, 8'h71);
        start_dma(.dir(1), .mem_addr(32'h0001_7000), .len(32), .opcode(8'h03), .flash_addr(32'h0011_7000));
        wait_dma_done(dma_success);
        p_sequencer.mem_svc.reset_axi_knobs();
        dma_count++;

        // 2. RX FIFO overrun (heavy WREADY stall during fast Quad RX)
        p_sequencer.mem_svc.set_axi_delays(0, 40, 0, 0, 0);
        fill_flash_range(32'h0011_7080, 32, 8'h73);
        start_dma(.dir(1), .mem_addr(32'h0001_7080), .len(32), .clk_div(0), .data_lanes(4),
                  .opcode(8'h6B), .dummy_cycles(8), .flash_addr(32'h0011_7080));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(20000));
        read_csr(QSPI_REG_ERR_STAT, rdata);
        read_csr(QSPI_REG_INT_STAT, rdata2);
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();

        // 3. TX FIFO underrun (heavy RVALID stall during fast Quad TX)
        p_sequencer.mem_svc.set_axi_delays(0, 0, 0, 0, 80);
        fill_ram_range(32'h0001_7100, 16, 8'h72);
        start_dma(.dir(0), .mem_addr(32'h0001_7100), .len(16), .clk_div(0), .data_lanes(4),
                  .opcode(8'h32), .flash_addr(32'h0011_7100));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(20000));
        read_csr(QSPI_REG_ERR_STAT, rdata);
        read_csr(QSPI_REG_INT_STAT, rdata2);
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();
        run_recovery_transfer(32'h0001_7200, 32'h0011_7200);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_04 (dma_23): Extended AXI AWREADY & WREADY Stall
      // -----------------------------------------------------------------------
      "dma_23", "TC_DMA_ERR_04": begin
        p_sequencer.mem_svc.set_axi_delays(12, 12, 0, 0, 0);
        fill_flash_range(32'h0011_8000, 16, 8'h81);
        start_dma(.dir(1), .mem_addr(32'h0001_8000), .len(16), .opcode(8'h03), .flash_addr(32'h0011_8000));
        wait_dma_done(dma_success);
        p_sequencer.mem_svc.reset_axi_knobs();
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_05 (dma_24): Mid-transfer Hard Reset During Active AXI Burst
      // -----------------------------------------------------------------------
      "dma_24", "TC_DMA_ERR_05": begin
        int wait_cyc;
        fill_flash_range(32'h0019_0000, 64, 8'h91);
        start_dma(.dir(1), .mem_addr(32'h0001_9000), .len(64), .opcode(8'h03), .flash_addr(32'h0019_0000));
        if (p_sequencer.cfg.axi_vif != null) begin
          wait_cyc = 0;
          while (!(p_sequencer.cfg.axi_vif.m_awvalid === 1'b1 ||
                   p_sequencer.cfg.axi_vif.m_wvalid  === 1'b1 ||
                   p_sequencer.cfg.axi_vif.m_arvalid === 1'b1) && wait_cyc < 5000) begin
            @(posedge p_sequencer.cfg.clk_vif.clk);
            wait_cyc++;
          end
          if (wait_cyc >= 5000)
            `uvm_error("DMA_RESET_WAIT", "TC_DMA_ERR_05 timed out waiting for active AXI burst before reset")
        end else begin
          repeat (120) @(posedge p_sequencer.cfg.clk_vif.clk);
        end
        allow_reset_abort = 1;
        request_reset();
        allow_reset_abort = 0;
        reset_aborted     = 0;
        read_csr(QSPI_REG_STATUS,   rdata);
        read_csr(QSPI_REG_INT_STAT, rdata2);
        run_recovery_transfer(32'h0001_9100, 32'h0019_0100);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_06 (dma_25): Length Mismatch (Out-of-Scope per Spec 5.2)
      // -----------------------------------------------------------------------
      "dma_25", "TC_DMA_ERR_06": begin
        write_csr(QSPI_REG_DMA_ADDR, 32'h0001_9700);
        write_csr(QSPI_REG_DMA_LEN,  32'h0000_0008);
        write_csr(QSPI_REG_CMD_LEN,  32'h0000_0010);
        read_csr(QSPI_REG_DMA_LEN,   rdata);
        read_csr(QSPI_REG_CMD_LEN,   rdata2);
        write_csr(QSPI_REG_DMA_CFG,  32'h0000_0030);
        write_csr(QSPI_REG_CMD_CFG,  32'h0000_2040);
        write_csr(QSPI_REG_CMD_OP,   32'h0000_0003);
        write_csr(QSPI_REG_CTRL,     32'h0000_0301);
        repeat (80) @(posedge p_sequencer.cfg.clk_vif.clk);
        request_reset();
        run_recovery_transfer(32'h0001_9800, 32'h0019_0800);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_ERR_07 (dma_26): Zero Length Config (Out-of-Scope per Spec 5.5)
      // -----------------------------------------------------------------------
      "dma_26", "TC_DMA_ERR_07": begin
        write_csr(QSPI_REG_DMA_ADDR, 32'h0001_9F00);
        write_csr(QSPI_REG_DMA_LEN,  32'h0);
        write_csr(QSPI_REG_CMD_LEN,  32'h0);
        read_csr(QSPI_REG_DMA_LEN,   rdata);
        write_csr(QSPI_REG_DMA_CFG,  32'h0000_0030);
        write_csr(QSPI_REG_CMD_CFG,  32'h0000_2040);
        write_csr(QSPI_REG_CMD_OP,   32'h0000_0003);
        write_csr(QSPI_REG_CTRL,     32'h0000_0301);
        repeat (40) @(posedge p_sequencer.cfg.clk_vif.clk);
        request_reset();
        run_recovery_transfer(32'h0001_A000, 32'h001A_0000);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_RND_01 (dma_27): CRV DMA Stress + 4100B 4KB-Crossing Quad RX
      // -----------------------------------------------------------------------
      "dma_27", "TC_DMA_RND_01": begin
        qspi_dma_crv_item crv;
        int unsigned      aligned_span;
        for (int i = 0; i < 8; i++) begin
          crv = qspi_dma_crv_item::type_id::create($sformatf("dma_crv_%0d", i));
          crv.c_policy_zero_axi_delay.constraint_mode(0);
          if (!crv.randomize() with {
                mem_addr   == 32'h0002_0000 + (i * 32'h100);
                flash_addr == 32'h0012_0000 + (i * 32'h100);
                if (i == 0) { dir == 1'b0; len inside {3, 5, 7}; }
                if (i == 1) { dir == 1'b1; len inside {3, 5, 7}; }
              }) begin
            `uvm_fatal("DMA_CRV_RAND", $sformatf("Failed to randomize qspi_dma_crv_item[%0d]", i))
          end
          if (!crv.validate())
            `uvm_fatal("DMA_CRV_VAL", $sformatf("Invalid qspi_dma_crv_item[%0d]: %s", i, crv.convert2string()))

          aligned_span = ((crv.len + 3) / 4) * 4;
          if (crv.dir) fill_flash_range(crv.flash_addr, crv.len, 8'(8'hA0 + i * 7));
          else         fill_ram_range(crv.mem_addr, aligned_span, 8'(8'hB0 + i * 7));

          p_sequencer.mem_svc.set_axi_delays(crv.aw_delay, crv.w_delay, crv.ar_delay, crv.b_delay, crv.r_delay);
          start_dma(
            .dir          (crv.dir),
            .mem_addr     (crv.mem_addr),
            .len          (crv.len),
            .incr_addr    (crv.incr_addr),
            .opcode       (crv.opcode),
            .flash_addr   (crv.flash_addr),
            .addr_bytes   (qspi_enc_to_addr_bytes(crv.addr_bytes_enc)),
            .cmd_lanes    (qspi_enc_to_lanes(crv.cmd_lanes)),
            .addr_lanes   (qspi_enc_to_lanes(crv.addr_lanes)),
            .data_lanes   (qspi_enc_to_lanes(crv.data_lanes)),
            .dummy_cycles (crv.dummy_cycles),
            .clk_div      (crv.clk_div),
            .spi_mode     (crv.spi_mode),
            .cs_delay     (crv.cs_delay),
            .lut_en       (crv.lut_en),
            .lut_idx      (crv.lut_idx)
          );
          wait_dma_done(dma_success);
          dma_count++;
        end
        p_sequencer.mem_svc.reset_axi_knobs();

        // Deterministic >4KB multi-burst Quad RX crossing 4KB boundary
        fill_flash_range(32'h0012_1000, 4100, 8'h5C);
        start_dma(.dir(1), .mem_addr(32'h0002_1F00), .len(4100), .data_lanes(4),
                  .dummy_cycles(8), .opcode(8'h6B), .flash_addr(32'h0012_1000));
        wait_dma_done(dma_success, 0, 500000);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_XIP_01 (dma_28): DMA and XIP Mode Switching Coexistence
      // -----------------------------------------------------------------------
      "dma_28", "TC_DMA_XIP_01": begin
        qspi_xip_read_seq xip_rd;
        p_sequencer.mem_svc.clear_flash_override();
        p_sequencer.mem_svc.preload_flash_word(32'h0013_0000, 32'hCAFE_BABE, 1'b1);
        write_csr(QSPI_REG_CS_CTRL, 32'h0000_0001);
        write_csr(QSPI_REG_CLK_DIV, 32'h0000_0001);
        write_csr(QSPI_REG_XIP_CFG, 32'h0000_0040);
        write_csr(QSPI_REG_XIP_CMD, 32'h0000_0003);
        write_csr(QSPI_REG_CTRL,    32'h0000_0003); // ENABLE=1, XIP_EN=1

        if (p_sequencer.axil_seqr != null) begin
          xip_rd = qspi_xip_read_seq::type_id::create("dma28_xip_rd");
          xip_rd.addr = 32'h0013_0000;
          xip_rd.prot = 3'b000;
          xip_rd.start(p_sequencer.axil_seqr);
        end

        // Attempt DMA trigger while XIP_EN=1 -> must stay blocked (STATUS.BUSY==0)
        write_csr(QSPI_REG_DMA_ADDR, 32'h0003_0000);
        write_csr(QSPI_REG_DMA_LEN,  32'd16);
        write_csr(QSPI_REG_CMD_LEN,  32'd16);
        write_csr(QSPI_REG_DMA_CFG,  32'h0000_0030);
        write_csr(QSPI_REG_CMD_CFG,  32'h0000_2040);
        write_csr(QSPI_REG_CMD_OP,   32'h0000_0003);
        write_csr(QSPI_REG_CTRL,     32'h0000_0303);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        read_csr(QSPI_REG_STATUS, rdata);
        if (rdata[0] !== 1'b0)
          `uvm_error("DMA_XIP_GATE", "DMA started while CTRL.XIP_EN=1")

        // Disable XIP_EN=0 and execute normal RX DMA
        write_csr(QSPI_REG_CTRL, 32'h0000_0001);
        fill_flash_range(32'h0013_0100, 16, 8'hD8);
        start_dma(.dir(1), .mem_addr(32'h0003_0000), .len(16), .opcode(8'h03), .flash_addr(32'h0013_0100));
        wait_dma_done(dma_success);
        dma_count++;
      end

      // -----------------------------------------------------------------------
      // TC_DMA_SEC_01 (dma_29): Unmapped AXI Address DECERR & Recovery
      // -----------------------------------------------------------------------
      "dma_29", "TC_DMA_SEC_01": begin
        p_sequencer.mem_svc.set_axi_resp(2'b11, 2'b00);
        start_dma(.dir(1), .mem_addr(32'hFFFF_0000), .len(16), .opcode(8'h03), .flash_addr(32'h0014_0000));
        wait_dma_done(dma_success, .expect_err(1), .timeout_cycles(10000));
        p_sequencer.mem_svc.reset_axi_knobs();
        request_reset();
        run_recovery_transfer(32'h0004_0000, 32'h0014_0100);
      end

      // -----------------------------------------------------------------------
      // TC_DMA_PERF_01 (dma_30): 256B Quad Read Throughput Measurement
      // -----------------------------------------------------------------------
      "dma_30", "TC_DMA_PERF_01": begin
        int unsigned elapsed_cycles;
        elapsed_cycles = 0;
        fill_flash_range(32'h0015_0000, 256, 8'hF0);
        start_dma(.dir(1), .mem_addr(32'h0005_0000), .len(256), .clk_div(0),
                  .data_lanes(4), .opcode(8'h6B), .dummy_cycles(8), .flash_addr(32'h0015_0000));
        fork
          wait_dma_done(dma_success);
          begin
            while (!dma_success && elapsed_cycles < 100000) begin
              @(posedge p_sequencer.cfg.clk_vif.clk);
              elapsed_cycles++;
            end
          end
        join
        `uvm_info("DMA_PERF", $sformatf(
          "256B Quad Read DMA completed in %0d clk cycles (%.2f cycles/byte)",
          elapsed_cycles, real'(elapsed_cycles) / 256.0), UVM_LOW)
        dma_count++;
      end

      default: begin
        `uvm_fatal("DMA_CASE_UNKNOWN", $sformatf("Unknown +QSPI_DMA_CASE=%s", selection))
      end
    endcase

    `uvm_info("DMA_VSEQ", $sformatf("=== Completed Scenario %s, issued %0d DMA transfers ===",
              selection, dma_count), UVM_LOW)
  endtask
endclass : qspi_dma_contract_vseq

`endif // QSPI_DMA_CONTRACT_VSEQ_SV
