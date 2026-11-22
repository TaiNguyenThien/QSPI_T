`ifndef QSPI_FLASH_SLAVE_SV
`define QSPI_FLASH_SLAVE_SV

class qspi_flash_slave extends uvm_component;
  `uvm_component_utils(qspi_flash_slave)

  virtual qspi_if qspi_vif;
  qspi_cfg        cfg;

  // Emulated NOR Flash memory array & device status registers
  bit [7:0] flash_mem[int unsigned];
  bit       wel;                            // Write Enable Latch
  bit       wip;                            // Write In Progress
  bit [7:0] status_reg;
  bit [7:0] id[3] = '{8'hc2, 8'h20, 8'h17}; // Default JEDEC ID

  function new(string name = "qspi_flash_slave", uvm_component parent = null);
    super.new(name, parent);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db #(virtual qspi_if)::get(this, "", "qspi_vif", qspi_vif))
      `uvm_fatal("QSPI_SLV_VIF", "Failed to retrieve virtual interface: qspi_vif")
    if (!uvm_config_db #(qspi_cfg)::get(this, "", "cfg", cfg) || cfg == null)
      `uvm_fatal("QSPI_SLV_CFG", "Failed to retrieve configuration: qspi_cfg")
  endfunction

  function void reset_device_state();
    wel        = 1'b0;
    wip        = 1'b0;
    status_reg = 8'h00;
  endfunction

  function void set_mem_byte(int unsigned address, bit [7:0] data_byte);
    flash_mem[address] = data_byte;
  endfunction

  function bit [7:0] get_mem_byte(int unsigned address);
    return flash_mem.exists(address) ? flash_mem[address] : 8'hFF;
  endfunction

  function void erase_range(int unsigned raw_addr, int unsigned range_bytes);
    int unsigned keys_to_del[$];
    longint unsigned base_addr;
    longint unsigned end_addr;
    if (range_bytes == 0) return;
    base_addr = longint'(raw_addr) - (longint'(raw_addr) % longint'(range_bytes));
    end_addr  = base_addr + longint'(range_bytes);
    foreach (flash_mem[k]) begin
      longint unsigned lk = longint'(k);
      if (lk >= base_addr && lk < end_addr)
        keys_to_del.push_back(k);
    end
    foreach (keys_to_del[i])
      flash_mem.delete(keys_to_del[i]);
  endfunction

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    release_io();
    forever begin
      @(negedge qspi_vif.qspi_cs_n);
      fork
        begin
          process_trans();
          if (qspi_vif.qspi_cs_n === 1'b0)
            @(posedge qspi_vif.qspi_cs_n);
        end
        @(posedge qspi_vif.qspi_cs_n);
      join_any
      disable fork;
      release_io();
    end
  endtask

  // ---------------------------------------------------------------------------
  // Low-Level Pin Timing & Lane Primitives
  // ---------------------------------------------------------------------------
  // Active sampling edges strictly follow CS assertion: the CS_n assertion clock
  // edge itself is a launch edge (CS_n was still high pre-NBA) and never a sample edge.
  task sample_edge(qspi_cfg frame_cfg);
    bit sample_on_posedge = (frame_cfg.cpol == frame_cfg.cpha);
    if (qspi_vif.qspi_cs_n !== 1'b0) begin
      return;
    end
    if (sample_on_posedge) @(posedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
    else                   @(negedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
  endtask

  task drive_edge(qspi_cfg frame_cfg);
    if (frame_cfg.cpol == frame_cfg.cpha) @(negedge qspi_vif.qspi_sclk);
    else                                  @(posedge qspi_vif.qspi_sclk);
  endtask

  task release_io();
    qspi_vif.flash_drive_en   = 4'b0000;
    qspi_vif.flash_drive_data = 4'b0000;
  endtask

  // Sample 1 byte MSB-first from Master across 1, 2, or 4 IO lanes
  task sample_rx_byte(qspi_cfg frame_cfg, output logic [7:0] data_byte, input bit [1:0] lanes);
    int step = (lanes == 2'd2) ? 4 : (lanes == 2'd1) ? 2 : 1;
    data_byte = 8'h00;
    for (int i = 7; i >= 0; i -= step) begin
      sample_edge(frame_cfg);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
      case (lanes)
        2'd1: begin
          data_byte[i]   = qspi_vif.qspi_io1;
          data_byte[i-1] = qspi_vif.qspi_io0;
        end
        2'd2: begin
          data_byte[i]   = qspi_vif.qspi_io3;
          data_byte[i-1] = qspi_vif.qspi_io2;
          data_byte[i-2] = qspi_vif.qspi_io1;
          data_byte[i-3] = qspi_vif.qspi_io0;
        end
        default: begin
          data_byte[i]   = qspi_vif.qspi_io0;
        end
      endcase
    end
  endtask

  // Drive 1 byte MSB-first to Master across 1 (IO1/MISO), 2 (IO[1:0]), or 4 (IO[3:0]) lanes
  task drive_tx_byte(qspi_cfg frame_cfg, input bit [7:0] data_byte, input bit [1:0] lanes);
    int step = (lanes == 2'd2) ? 4 : (lanes == 2'd1) ? 2 : 1;
    for (int i = 7; i >= 0; i -= step) begin
      drive_edge(frame_cfg);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
      case (lanes)
        2'd1: begin
          qspi_vif.flash_drive_en   = 4'b0011;
          qspi_vif.flash_drive_data = {2'b00, data_byte[i], data_byte[i-1]};
        end
        2'd2: begin
          qspi_vif.flash_drive_en   = 4'b1111;
          qspi_vif.flash_drive_data = {data_byte[i], data_byte[i-1], data_byte[i-2], data_byte[i-3]};
        end
        default: begin
          qspi_vif.flash_drive_en   = 4'b0010;
          qspi_vif.flash_drive_data = {2'b00, data_byte[i], 1'b0};
        end
      endcase
    end
  endtask

  // ---------------------------------------------------------------------------
  // Protocol Phase Handlers (Mode-Agnostic: Works for PIO, DMA, LUT, and XIP)
  // ---------------------------------------------------------------------------
  task capture_address(qspi_cfg frame_cfg, qspi_transaction tr, output bit addr_ok);
    logic [7:0] byte_addr;
    int num_bytes = (frame_cfg.addr_bytes == 2'b00) ? 0 :
                    (frame_cfg.addr_bytes == 2'b10) ? 4 : 3;
    addr_ok = 1'b0;
    tr.addr = 32'h0;
    for (int count = 0; count < num_bytes; count++) begin
      sample_rx_byte(frame_cfg, byte_addr, frame_cfg.addr_lanes);
      if ($isunknown(byte_addr)) begin
        tr.addr = {tr.addr[23:0], byte_addr};
        `uvm_error("QSPI_FLASH_ADDR_XZ", $sformatf("Captured X/Z address byte 0x%02h on SPI bus", byte_addr))
        return;
      end
      if (qspi_vif.qspi_cs_n !== 1'b0) begin
        return;
      end
      tr.addr = {tr.addr[23:0], byte_addr};
    end
    if (num_bytes == 3)      tr.addr &= 32'h00FF_FFFF;
    else if (num_bytes == 0) tr.addr  = 32'h0;
    addr_ok = 1'b1;
  endtask

  task skip_dummy_cycles(qspi_cfg frame_cfg);
    int total_dummy;
    total_dummy = int'(frame_cfg.dummy_cycles) + int'(frame_cfg.extra_dummy);
    repeat (total_dummy) begin
      sample_edge(frame_cfg);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
    end
  endtask

  task capture_write_data(qspi_cfg frame_cfg, qspi_transaction tr);
    logic [7:0] byte_data;
    int offset = 0;
    if (frame_cfg.addr_bytes != 0 && $isunknown(tr.addr)) begin
      `uvm_error("QSPI_FLASH_ADDR_XZ", $sformatf("Flash write received X/Z address: %p", tr.addr))
      return;
    end
    while (qspi_vif.qspi_cs_n === 1'b0) begin
      sample_rx_byte(frame_cfg, byte_data, frame_cfg.data_lanes);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
      if (!$isunknown({tr.addr, byte_data}))
        flash_mem[tr.addr + offset] = byte_data;
      offset++;
    end
  endtask

  task drive_read_data(qspi_cfg frame_cfg, qspi_transaction tr);
    int offset = 0;
    bit [7:0] curr_byte;
    bit [31:0] resolved_addr;
    if (frame_cfg.addr_bytes != 0 && $isunknown(tr.addr)) begin
      `uvm_error("QSPI_FLASH_ADDR_XZ", $sformatf("Flash read received X/Z address: %p", tr.addr))
      return;
    end
    resolved_addr = tr.addr;

    while (qspi_vif.qspi_cs_n === 1'b0) begin
      case (frame_cfg.response_source)
        qspi_cfg::DEVICE_MODEL:
          curr_byte = get_mem_byte(resolved_addr + offset);
        qspi_cfg::OVERRIDE_BUFFER:
          curr_byte = (offset < frame_cfg.read_bytes.size())
                    ? frame_cfg.read_bytes[offset]
                    : frame_cfg.override_pad;
        default:
          curr_byte = get_mem_byte(resolved_addr + offset);
      endcase
      drive_tx_byte(frame_cfg, curr_byte, frame_cfg.data_lanes);
      offset++;
    end
  endtask

  // Unified memory framing pipeline shared across PIO, DMA, LUT, and XIP
  task execute_mem_transfer(qspi_cfg frame_cfg, qspi_transaction tr);
    bit addr_ok;
    if (frame_cfg.addr_bytes != 0) begin
      capture_address(frame_cfg, tr, addr_ok);
      if (!addr_ok || qspi_vif.qspi_cs_n !== 1'b0) return;
    end
    if (frame_cfg.mode_en) begin
      sample_rx_byte(frame_cfg, tr.mode_bits, frame_cfg.addr_lanes);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
    end
    if (frame_cfg.dummy_cycles != 0 || frame_cfg.extra_dummy != 0) begin
      skip_dummy_cycles(frame_cfg);
      if (qspi_vif.qspi_cs_n !== 1'b0) return;
    end
    if (frame_cfg.dir)
      drive_read_data(frame_cfg, tr);
    else
      capture_write_data(frame_cfg, tr);
  endtask

  task process_trans();
    qspi_cfg         frame_cfg = cfg.snapshot("slv_frame_cfg");
    qspi_transaction tr        = qspi_transaction::type_id::create("tr");
    bit              addr_ok;
    release_io();

    if (qspi_vif.qspi_cs_n !== 1'b0) return;

    sample_rx_byte(frame_cfg, tr.opcode, frame_cfg.cmd_lanes);
    if (qspi_vif.qspi_cs_n !== 1'b0) return;

    // Non-memory Flash commands use device state only when PIO stimulus did not
    // explicitly preload read_bytes for wire-level scoreboard comparison.
    case (tr.opcode)
      8'h06: if (frame_cfg.addr_bytes == 0 && !frame_cfg.dir) wel = 1'b1; // WREN
             else execute_mem_transfer(frame_cfg, tr);

      8'h04: if (frame_cfg.addr_bytes == 0 && !frame_cfg.dir) wel = 1'b0; // WRDI
             else execute_mem_transfer(frame_cfg, tr);

      8'h01: if (frame_cfg.addr_bytes == 0 && !frame_cfg.dir) begin // WRSR
               logic [7:0] sr_byte;
               sample_rx_byte(frame_cfg, sr_byte, frame_cfg.data_lanes);
               if (qspi_vif.qspi_cs_n === 1'b0 && wel && !$isunknown(sr_byte))
                 status_reg = sr_byte;
             end else begin
               execute_mem_transfer(frame_cfg, tr);
             end

      8'h05: if (frame_cfg.addr_bytes == 0 && frame_cfg.dir && frame_cfg.read_bytes.size() == 0) begin
               status_reg[0] = wip;
               status_reg[1] = wel;
               while (qspi_vif.qspi_cs_n === 1'b0)
                 drive_tx_byte(frame_cfg, status_reg, frame_cfg.data_lanes);
             end else begin
               execute_mem_transfer(frame_cfg, tr);
             end

      8'h9F: if (frame_cfg.addr_bytes == 0 && frame_cfg.dir && frame_cfg.read_bytes.size() == 0) begin
               int id_idx = 0;
               while (qspi_vif.qspi_cs_n === 1'b0) begin
                 drive_tx_byte(frame_cfg, id[id_idx % 3], frame_cfg.data_lanes);
                 id_idx++;
               end
             end else begin
               execute_mem_transfer(frame_cfg, tr);
             end

      8'h20: if (!frame_cfg.dir && frame_cfg.addr_bytes != 0) begin // Sector Erase
               capture_address(frame_cfg, tr, addr_ok);
               if (addr_ok && !$isunknown(tr.addr))
                 erase_range(tr.addr, frame_cfg.sector_erase_bytes);
             end else begin
               execute_mem_transfer(frame_cfg, tr);
             end

      8'hD8: if (!frame_cfg.dir && frame_cfg.addr_bytes != 0) begin // Block Erase
               capture_address(frame_cfg, tr, addr_ok);
               if (addr_ok && !$isunknown(tr.addr))
                 erase_range(tr.addr, frame_cfg.block_erase_bytes);
             end else begin
               execute_mem_transfer(frame_cfg, tr);
             end

      8'hC7: if (frame_cfg.addr_bytes == 0 && !frame_cfg.dir) flash_mem.delete(); // Chip Erase
             else execute_mem_transfer(frame_cfg, tr);

      default: execute_mem_transfer(frame_cfg, tr);
    endcase
  endtask

endclass : qspi_flash_slave

`endif
