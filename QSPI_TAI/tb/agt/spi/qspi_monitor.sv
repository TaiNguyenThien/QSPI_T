`ifndef QSPI_MONITOR_SV
`define QSPI_MONITOR_SV

class qspi_monitor extends uvm_monitor;
  `uvm_component_utils(qspi_monitor)

  string my_name;
  virtual qspi_if qspi_vif;
  virtual clk_rst_irq_if clk_rst_irq_vif;
  qspi_cfg cfg;

  // Analysis port to send observed actual transaction to Scoreboard and Coverage
  uvm_analysis_port #(qspi_transaction) ref_port;

  function new(string name = "qspi_monitor", uvm_component parent = null);
    super.new(name, parent);
    my_name = name;
    ref_port = new("ref_port", this);
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

  virtual task run_phase(uvm_phase phase);
    super.run_phase(phase);
    forever begin
      @(negedge qspi_vif.qspi_cs_n);
      monitoring();
    end
  endtask

  task sample_edge(bit is_first_edge = 0);
    bit sample_on_posedge;
    sample_on_posedge = (cfg.cpol == cfg.cpha);
    if (is_first_edge && (sample_on_posedge ? (qspi_vif.qspi_sclk === 1'b1) : (qspi_vif.qspi_sclk === 1'b0))) begin
      #1ps;
    end else begin
      if (sample_on_posedge)
        @(posedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
      else
        @(negedge qspi_vif.qspi_sclk or posedge qspi_vif.qspi_cs_n);
      #1ps;
    end
  endtask

  task monitoring();
    qspi_transaction tr;
    tr = qspi_transaction::type_id::create("tr");
    tr.data = new[0];

    // Capture Opcode phase
    capture_opcode(tr, cfg.cmd_lanes);
    if (qspi_vif.qspi_cs_n) begin
      ref_port.write(tr);
      return;
    end

    // Capture Address phase
    if (cfg.addr_bytes != 0) begin
      capture_address(tr, cfg.addr_lanes);
      if (qspi_vif.qspi_cs_n) begin
        ref_port.write(tr);
        return;
      end
    end

    // Capture optional Mode bits phase
    if (cfg.mode_en) begin
      capture_mode(tr, cfg.data_lanes);
      if (qspi_vif.qspi_cs_n) begin
        ref_port.write(tr);
        return;
      end
    end

    // Skip Dummy cycles
    if (cfg.dummy_cycles != 0 || cfg.extra_dummy != 0) begin
      skip_dummy_cycles();
      if (qspi_vif.qspi_cs_n) begin
        ref_port.write(tr);
        return;
      end
    end

    // Capture Data phase
    tr.dir = cfg.dir;
    capture_data(tr, cfg.data_lanes, cfg.dir);

    // Broadcast monitored transaction
    ref_port.write(tr);
  endtask

  task capture_opcode(qspi_transaction tr, bit [1:0] lanes);
    tr.opcode = 8'h00;
    case (lanes)
      2'd0: begin
        for (int i = 7; i >= 0; i--) begin
          sample_edge(i == 7);
          if (qspi_vif.qspi_cs_n) return;
          tr.opcode[i] = qspi_vif.qspi_io0;
        end
      end
      2'd1: begin
        for (int i = 7; i >= 0; i -= 2) begin
          sample_edge(i == 7);
          if (qspi_vif.qspi_cs_n) return;
          tr.opcode[i]   = qspi_vif.qspi_io1;
          tr.opcode[i-1] = qspi_vif.qspi_io0;
        end
      end
      2'd2: begin
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

  task skip_dummy_cycles();
    int total_dummy;
    total_dummy = int'(cfg.dummy_cycles) + int'(cfg.extra_dummy);
    repeat (total_dummy) begin
      sample_edge();
      if (qspi_vif.qspi_cs_n) return;
    end
  endtask

  task capture_mode(qspi_transaction tr, bit [1:0] lanes);
    tr.mode_bits = 8'h00;
    case (lanes)
      2'd0: begin
        for (int i = 7; i >= 0; i--) begin
          sample_edge();
          if (qspi_vif.qspi_cs_n) return;
          tr.mode_bits[i] = qspi_vif.qspi_io0;
        end
      end
      2'd1: begin
        for (int i = 7; i >= 0; i -= 2) begin
          sample_edge();
          if (qspi_vif.qspi_cs_n) return;
          tr.mode_bits[i]   = qspi_vif.qspi_io1;
          tr.mode_bits[i-1] = qspi_vif.qspi_io0;
        end
      end
      2'd2: begin
        for (int i = 7; i >= 0; i -= 4) begin
          sample_edge();
          if (qspi_vif.qspi_cs_n) return;
          tr.mode_bits[i]   = qspi_vif.qspi_io3;
          tr.mode_bits[i-1] = qspi_vif.qspi_io2;
          tr.mode_bits[i-2] = qspi_vif.qspi_io1;
          tr.mode_bits[i-3] = qspi_vif.qspi_io0;
        end
      end
      default: begin
        for (int i = 7; i >= 0; i -= 4) begin
          sample_edge();
          if (qspi_vif.qspi_cs_n) return;
          tr.mode_bits[i]   = qspi_vif.qspi_io3;
          tr.mode_bits[i-1] = qspi_vif.qspi_io2;
          tr.mode_bits[i-2] = qspi_vif.qspi_io1;
          tr.mode_bits[i-3] = qspi_vif.qspi_io0;
        end
      end
    endcase
  endtask

  task capture_data(qspi_transaction tr, bit [1:0] lanes, bit is_rx);
    bit [7:0] byte_data;
    int count = 0;
    while (!qspi_vif.qspi_cs_n) begin
      byte_data = 8'h00;
      case (lanes)
        2'd0: begin // Single lane: Master TX on IO0, Slave TX on IO1
          for (int i = 7; i >= 0; i--) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i] = is_rx ? qspi_vif.qspi_io1 : qspi_vif.qspi_io0;
          end
        end
        2'd1: begin // Dual lane on IO1, IO0
          for (int i = 7; i >= 0; i -= 2) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i]   = qspi_vif.qspi_io1;
            byte_data[i-1] = qspi_vif.qspi_io0;
          end
        end
        2'd2: begin // Quad lane on IO3..IO0
          for (int i = 7; i >= 0; i -= 4) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i]   = qspi_vif.qspi_io3;
            byte_data[i-1] = qspi_vif.qspi_io2;
            byte_data[i-2] = qspi_vif.qspi_io1;
            byte_data[i-3] = qspi_vif.qspi_io0;
          end
        end
        default: begin
          for (int i = 7; i >= 0; i--) begin
            sample_edge();
            if (qspi_vif.qspi_cs_n) return;
            byte_data[i] = is_rx ? qspi_vif.qspi_io1 : qspi_vif.qspi_io0;
          end
        end
      endcase
      tr.data = new[count + 1](tr.data);
      tr.data[count] = byte_data;
      count++;
    end
  endtask
endclass : qspi_monitor

`endif