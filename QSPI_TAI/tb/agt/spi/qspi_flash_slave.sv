`ifndef QSPI_FLASH_SLAVE_SV
`define QSPI_FLASH_SLAVE_SV

class qspi_flash_slave extends uvm_component;
  `uvm_component_utils(qspi_flash_slave)

  string my_name;
  virtual qspi_if qspi_vif;
  virtual clk_rst_irq_if clk_rst_irq_vif;
  qspi_cfg cfg;

  // Analysis port broadcasting expected data during DMA Write (DIR=1: Flash -> RAM)
  uvm_analysis_port #(qspi_transaction) exp_ap;

  // Emulated flash memory space & status registers
  bit [7:0] flash_mem[int unsigned];
  bit wel;                                  // Write Enable Latch
  bit wip;                                  // Write In Progress
  bit [7:0] status_reg;
  bit [7:0] id[3] = '{8'hc2, 8'h20, 8'h17}; // Default JEDEC ID

  function new(string name = "qspi_flash_slave", uvm_component parent = null);
    super.new(name, parent);
    my_name = name;
    exp_ap = new("exp_ap", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (!uvm_config_db #(virtual qspi_if)::get(this, "", "qspi_vif", qspi_vif))
      `uvm_error(my_name, "Failed to retrieve virtual interface: qspi_vif")
    if (!uvm_config_db #(virtual clk_rst_irq_if)::get(this, "", "clk_rst_irq_vif", clk_rst_irq_vif))
      `uvm_error(my_name, "Failed to retrieve virtual interface: clk_rst_irq_vif")
    if (!uvm_config_db #(qspi_cfg)::get(this, "", "cfg", cfg))
      `uvm_error(my_name, "Failed to retrieve configuration: qspi_cfg")
  endfunction

  function void set_mem_byte(int unsigned address, bit [7:0] data_byte);
    flash_mem[address] = data_byte;
  endfunction

  function bit [7:0] get_mem_byte(int unsigned address);
    if (flash_mem.exists(address))
      return flash_mem[address];
    return 8'hFF;
  endfunction

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    release_io();
    forever begin
      // Wait for chip-select assertion (active-low)
      @(negedge qspi_vif.qspi_cs_n);
      fork
        begin
          process_trans();
        end
        begin
          @(posedge qspi_vif.qspi_cs_n);
        end
      join_any
      disable fork;
      release_io();
    end
  endtask

  // Sampling edge determined by CPOL and CPHA configurations
  task sample_edge(bit is_first_edge = 0);
    bit sample_on_posedge;
    sample_on_posedge = (cfg.cpol == cfg.cpha);
    if (is_first_edge && (sample_on_posedge ? (qspi_vif.qspi_sclk === 1'b1) : (qspi_vif.qspi_sclk === 1'b0))) begin
      #1ps;
    end else begin
      if (sample_on_posedge)
        @(posedge qspi_vif.qspi_sclk);
      else
        @(negedge qspi_vif.qspi_sclk);
      #1ps;
    end
  endtask

  // Driving edge determined by CPOL and CPHA configurations
  task drive_edge();
    if (cfg.cpol == cfg.cpha)
      @(negedge qspi_vif.qspi_sclk);
    else
      @(posedge qspi_vif.qspi_sclk);
  endtask

  // Release all bidirectional IO lines to high-impedance
  task release_io();
    qspi_vif.flash_drive_en   = 4'b0000;
    qspi_vif.flash_drive_data = 4'b0000;
  endtask

  // Main transaction processing loop
  task process_trans();
    qspi_transaction tr;
    tr = qspi_transaction::type_id::create("tr");

    release_io();
    capture_opcode(tr, cfg.cmd_lanes);
    if (qspi_vif.qspi_cs_n) return;

    case (tr.opcode)
      8'h06: wel = 1'b1; // WREN
      8'h04: wel = 1'b0; // WRDI

      8'h05: begin // RDSR (Read Status Register)
        status_reg[0] = wip;
        status_reg[1] = wel;
        while (!qspi_vif.qspi_cs_n) begin
          drive_byte_single(status_reg);
        end
      end

      8'h9F: begin // RDID (Read Identification)
        int id_idx = 0;
        while (!qspi_vif.qspi_cs_n) begin
          drive_byte_single(id[id_idx % 3]);
          id_idx++;
        end
      end

      8'h20, 8'hD8: begin // Sector/Block Erase
        capture_address(tr, 2'd0);
      end

      8'hC7: begin // Chip Erase
        flash_mem.delete();
      end

      // Write / Program operations (Master TX: RAM -> Flash)
      8'h02: begin // Page Program (1-1-1)
        capture_address(tr, 2'd0);
        capture_write_data(tr, 2'd0);
      end

      8'h32: begin // Quad Page Program (1-1-4)
        capture_address(tr, 2'd0);
        capture_write_data(tr, 2'd2);
      end

      // Read operations (Master RX: Flash -> RAM)
      8'h03: begin // Normal Read (1-1-1)
        capture_address(tr, 2'd0);
        drive_read_data(tr, 2'd0);
      end

      8'h0B: begin // Fast Read (1-1-1)
        capture_address(tr, 2'd0);
        skip_dummy_cycles();
        drive_read_data(tr, 2'd0);
      end

      8'h3B: begin // Dual Read (1-1-2)
        capture_address(tr, 2'd0);
        skip_dummy_cycles();
        drive_read_data(tr, 2'd1);
      end

      8'h6B: begin // Quad Read (1-1-4)
        capture_address(tr, 2'd0);
        skip_dummy_cycles();
        drive_read_data(tr, 2'd2);
      end

      8'hEB: begin // Quad I/O Read (1-4-4)
        capture_address(tr, 2'd2);
        if (cfg.mode_en) capture_mode(tr);
        skip_dummy_cycles();
        drive_read_data(tr, 2'd2);
      end

      default: begin
        if (cfg.dir) begin
          if (cfg.addr_bytes != 0) capture_address(tr, cfg.addr_lanes);
          if (cfg.dummy_cycles != 0 || cfg.extra_dummy != 0) skip_dummy_cycles();
          drive_read_data(tr, cfg.data_lanes);
        end else begin
          if (cfg.addr_bytes != 0) capture_address(tr, cfg.addr_lanes);
          capture_write_data(tr, cfg.data_lanes);
        end
      end
    endcase
  endtask

  // Capture Opcode phase on configured lanes (MSB-first)
  task capture_opcode(qspi_transaction tr, bit [1:0] lanes);
    tr.opcode = 8'h00;
    case (lanes)
      2'd0: begin // Single lane on IO0
        for (int i = 7; i >= 0; i--) begin
          sample_edge(i == 7);
          if (qspi_vif.qspi_cs_n) return;
          tr.opcode[i] = qspi_vif.qspi_io0;
        end
      end
      2'd1: begin // Dual lane on IO1, IO0
        for (int i = 7; i >= 0; i -= 2) begin
          sample_edge(i == 7);
          if (qspi_vif.qspi_cs_n) return;
          tr.opcode[i]   = qspi_vif.qspi_io1;
          tr.opcode[i-1] = qspi_vif.qspi_io0;
        end
      end
      2'd2: begin // Quad lane on IO3..IO0
        for (int i = 7; i >= 0; i -= 4) begin
          sample_edge(i == 7);
          if (qspi_vif.qspi_cs_n) return;
          tr.opcode[i]   = qspi_vif.qspi_io3;
          tr.opcode[i-1] = qspi_vif.qspi_io2;
          tr.opcode[i-2] = qspi_vif.qspi_io1;
          tr.opcode[i-3] = qspi_vif.qspi_io0;
        end
      end
      default: begin
        for (int i = 7; i >= 0; i--) begin
          sample_edge(i == 7);
          if (qspi_vif.qspi_cs_n) return;
          tr.opcode[i] = qspi_vif.qspi_io0;
        end
      end
    endcase
  endtask

  // Capture Address phase
  task capture_address(qspi_transaction tr, bit [1:0] lanes);
    bit [7:0] byte_addr;
    int num_bytes;

    case (cfg.addr_bytes)
      2'b00: num_bytes = 0;
      2'b01: num_bytes = 3;
      2'b10: num_bytes = 4;
      default: num_bytes = 3;
    endcase

    tr.addr = 32'h0;
    for (int count = 0; count < num_bytes; count++) begin
      byte_addr = 8'h00;
      case (lanes)
        2'd0: begin
          for (int i = 7; i >= 0; i--) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_addr[i] = qspi_vif.qspi_io0;
          end
        end
        2'd1: begin
          for (int i = 7; i >= 0; i -= 2) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_addr[i]   = qspi_vif.qspi_io1;
            byte_addr[i-1] = qspi_vif.qspi_io0;
          end
        end
        2'd2: begin
          for (int i = 7; i >= 0; i -= 4) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_addr[i]   = qspi_vif.qspi_io3;
            byte_addr[i-1] = qspi_vif.qspi_io2;
            byte_addr[i-2] = qspi_vif.qspi_io1;
            byte_addr[i-3] = qspi_vif.qspi_io0;
          end
        end
        default: begin
          for (int i = 7; i >= 0; i--) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_addr[i] = qspi_vif.qspi_io0;
          end
        end
      endcase
      tr.addr = {tr.addr[23:0], byte_addr};
    end
    if (num_bytes == 3) tr.addr = tr.addr & 32'h00FF_FFFF;
    else if (num_bytes == 0) tr.addr = 32'h0;
  endtask

  // Skip programmed dummy clock cycles
  task skip_dummy_cycles();
    int total_dummy;
    total_dummy = int'(cfg.dummy_cycles) + int'(cfg.extra_dummy);
    repeat (total_dummy) begin
      sample_edge();
      if (qspi_vif.qspi_cs_n) return;
    end
  endtask

  // Capture optional Mode bits phase
  task capture_mode(qspi_transaction tr);
    tr.mode_bits = 8'h00;
    for (int i = 7; i >= 0; i -= 4) begin
      sample_edge();
      if (qspi_vif.qspi_cs_n) return;
      tr.mode_bits[i]   = qspi_vif.qspi_io3;
      tr.mode_bits[i-1] = qspi_vif.qspi_io2;
      tr.mode_bits[i-2] = qspi_vif.qspi_io1;
      tr.mode_bits[i-3] = qspi_vif.qspi_io0;
    end
  endtask

  // Capture incoming write payload and update memory
  task capture_write_data(qspi_transaction tr, bit [1:0] lanes);
    bit [7:0] byte_data;
    int offset = 0;
    while (!qspi_vif.qspi_cs_n) begin
      byte_data = 8'h00;
      case (lanes)
        2'd0: begin
          for (int i = 7; i >= 0; i--) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i] = qspi_vif.qspi_io0;
          end
        end
        2'd1: begin
          for (int i = 7; i >= 0; i -= 2) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i]   = qspi_vif.qspi_io1;
            byte_data[i-1] = qspi_vif.qspi_io0;
          end
        end
        2'd2: begin
          for (int i = 7; i >= 0; i -= 4) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i]   = qspi_vif.qspi_io3;
            byte_data[i-1] = qspi_vif.qspi_io2;
            byte_data[i-2] = qspi_vif.qspi_io1;
            byte_data[i-3] = qspi_vif.qspi_io0;
          end
        end
      endcase
      flash_mem[tr.addr + offset] = byte_data;
      offset++;
    end
  endtask

  // Drive read data back to master and broadcast expected transaction to Scoreboard
  task drive_read_data(qspi_transaction tr, bit [1:0] lanes);
    int offset = 0;
    bit [7:0] curr_byte;
    qspi_transaction exp_tr;

    exp_tr = qspi_transaction::type_id::create("exp_tr");
    exp_tr.opcode    = tr.opcode;
    exp_tr.addr      = tr.addr;
    exp_tr.dir       = 1'b1;
    exp_tr.lane_mode = tr.lane_mode;
    exp_tr.data      = new[0];

    while (!qspi_vif.qspi_cs_n) begin
      // Retrieve byte from memory model, or generate random byte if uninitialized
      if (flash_mem.exists(tr.addr + offset))
        curr_byte = flash_mem[tr.addr + offset];
      else
        curr_byte = $urandom_range(8'h00, 8'hFF);

      // Append to expected data array
      exp_tr.data = new[offset + 1](exp_tr.data);
      exp_tr.data[offset] = curr_byte;

      // Drive out to physical lines (MSB-first on each byte)
      case (lanes)
        2'd0: drive_byte_single(curr_byte);
        2'd1: drive_byte_dual(curr_byte);
        2'd2: drive_byte_quad(curr_byte);
        default: drive_byte_single(curr_byte);
      endcase
      offset++;
    end

    // Broadcast expected packet to Scoreboard for DMA Write checking
    if (exp_tr.data.size() > 0) begin
      exp_ap.write(exp_tr);
    end
  endtask

  task drive_byte_single(input bit [7:0] data_byte);
    for (int i = 7; i >= 0; i--) begin
      drive_edge();
      if (qspi_vif.qspi_cs_n) return;
      qspi_vif.flash_drive_en   = 4'b0010;
      qspi_vif.flash_drive_data = {2'b00, data_byte[i], 1'b0};
    end
  endtask

  task drive_byte_dual(input bit [7:0] data_byte);
    for (int i = 7; i >= 0; i -= 2) begin
      drive_edge();
      if (qspi_vif.qspi_cs_n) return;
      qspi_vif.flash_drive_en   = 4'b0011;
      qspi_vif.flash_drive_data = {2'b00, data_byte[i], data_byte[i-1]};
    end
  endtask

  task drive_byte_quad(input bit [7:0] data_byte);
    for (int i = 7; i >= 0; i -= 4) begin
      drive_edge();
      if (qspi_vif.qspi_cs_n) return;
      qspi_vif.flash_drive_en   = 4'b1111;
      qspi_vif.flash_drive_data = {data_byte[i], data_byte[i-1], data_byte[i-2], data_byte[i-3]};
    end
  endtask
endclass : qspi_flash_slave

`endif