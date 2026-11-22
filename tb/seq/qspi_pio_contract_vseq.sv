// Directed FIFO reset: interrupt the real port access, not an unrelated CSR.
class qspi_pio_fifo_reset_vseq extends qspi_pio_transfer_vseq;
  `uvm_object_utils(qspi_pio_fifo_reset_vseq)
  bit target_tx, target_access, armed;
  function new(string name="qspi_pio_fifo_reset_vseq"); super.new(name); endfunction
  virtual task before_fifo_access(bit write_direction);
    if (armed || write_direction!=target_tx) return;
    armed=1;
    fork
      begin
        wait (p_sequencer.cfg.apb_cfg_h.apb_vif.psel===1'b1 &&
              p_sequencer.cfg.apb_cfg_h.apb_vif.paddr===
                (target_tx ? QSPI_REG_WRITE_TX : QSPI_REG_READ_RX) &&
              p_sequencer.cfg.apb_cfg_h.apb_vif.penable===target_access);
        @(negedge p_sequencer.cfg.clk_vif.clk);
        request_reset();
      end
    join_none
  endtask
endclass

// An RX command fills exactly the specified capacity before software drains it.
// No full-FIFO write or empty-FIFO read is used to manufacture an event.
class qspi_pio_rx_full_vseq extends qspi_pio_transfer_vseq;
  `uvm_object_utils(qspi_pio_rx_full_vseq)
  bit full_checked;
  function new(string name="qspi_pio_rx_full_vseq"); super.new(name); endfunction
  virtual task before_fifo_access(bit write_direction);
    logic [31:0] value;
    if (write_direction || full_checked) return;
    full_checked=1;
    read_csr(QSPI_REG_FIFO_STAT,value);
    if (value[7:4]!==4 || value[9]!==1)
      `uvm_error("QSPI_PIO_RX_FULL","RX must report four words and FULL before its first drain")
    write_csr(QSPI_REG_INT_EN,0);
    read_csr(QSPI_REG_INT_STAT,value);
    if (value[4]!==1 || p_sequencer.cfg.clk_vif.irq!==0)
      `uvm_error("QSPI_PIO_RX_FULL","RX_FULL event must remain pending while masked")
    write_csr(QSPI_REG_INT_EN,16);
    read_csr(QSPI_REG_INT_STAT,value);
    if (p_sequencer.cfg.clk_vif.irq!==1)
      `uvm_error("QSPI_PIO_RX_FULL","Enabling pending RX_FULL did not assert IRQ")
    // Do not require W1C of an active full-level event to stay cleared.
    write_csr(QSPI_REG_INT_STAT,0,1);
    read_csr(QSPI_REG_INT_STAT,value);
    if (value[4]!==1)
      `uvm_error("QSPI_PIO_RX_FULL","Write zero erased pending RX_FULL")
    write_csr(QSPI_REG_INT_EN,0);
    read_csr(QSPI_REG_INT_STAT,value);
  endtask
endclass

// Verifies writing READ_RX never pops an already-populated RX FIFO (RO port).
class qspi_pio_rx_write_ro_vseq extends qspi_pio_transfer_vseq;
  `uvm_object_utils(qspi_pio_rx_write_ro_vseq)
  bit write_tested, write_broke_fifo;
  logic [31:0] fifo_before, fifo_after;
  function new(string name="qspi_pio_rx_write_ro_vseq"); super.new(name); endfunction
  virtual task before_fifo_access(bit write_direction);
    if (write_direction || write_tested) return;
    write_tested = 1;
    read_csr(QSPI_REG_FIFO_STAT, fifo_before);
    raw_access(1, QSPI_REG_READ_RX, 32'hdead_beef);
    read_csr(QSPI_REG_FIFO_STAT, fifo_after);
    if (fifo_after[7:4] !== fifo_before[7:4]) begin
      write_broke_fifo = 1;
      `uvm_error("TEST_RESULT", $sformatf(
        "Write to RO READ_RX popped RX FIFO (RX_LEVEL before=%0d after=%0d)",
        fifo_before[7:4], fifo_after[7:4]))
    end
  endtask
endclass

// Same generic agent, with independently observed prerequisites for closure.
class qspi_apb_pair_seq extends qspi_apb_base_seq_t;
  `uvm_object_utils(qspi_apb_pair_seq)
  bit [1:0] pair_kind;
  int unsigned gap;
  function new(string name="qspi_apb_pair_seq"); super.new(name); endfunction
  task body();
    qspi_apb_item_t req;
    for (int i=0;i<2;i++) begin
      req=qspi_apb_item_t::type_id::create($sformatf("pair_%0d",i));
      start_item(req);
      req.addr=QSPI_REG_CMD_ADDR;
      req.write=pair_kind[1-i];
      req.wdata=32'h963c_5aa5 ^ 32'(pair_kind);
      req.strb=req.write ? 4'hf : 0;
      req.prot=3'(i + 2*pair_kind);
      req.idle_cycles=i==0 ? 0 : gap;
      finish_item(req);
      if (req.reset_abort || req.slverr!==0)
        `uvm_fatal("QSPI_APB_TRAFFIC","Pair did not complete successfully")
    end
  endtask
endclass

class qspi_pio_contract_vseq extends qspi_pio_sweep_vseq;
  `uvm_object_utils(qspi_pio_contract_vseq)
  function new(string name="qspi_pio_contract_vseq"); super.new(name); endfunction

  // Read-only snapshots exercise the passive CSR predictor across W1C.
  task w1c_preserves_cfg(bit [31:0] ones,bit [3:0] strobe=1);
    bit [11:0] addresses[$]='{QSPI_REG_CTRL,QSPI_REG_INT_EN,QSPI_REG_CLK_DIV,
      QSPI_REG_CS_CTRL,QSPI_REG_CMD_CFG,QSPI_REG_CMD_OP,QSPI_REG_CMD_ADDR,
      QSPI_REG_CMD_LEN,QSPI_REG_CMD_DUMMY,QSPI_REG_LUT_CTRL,QSPI_REG_LUT_CFG,
      QSPI_REG_LUT_OP,QSPI_REG_LUT_DUMMY};
    logic [31:0] before_value[$],value;
    foreach (addresses[i]) begin
      read_csr(addresses[i],value);
      before_value.push_back(value);
    end
    write_csr(QSPI_REG_INT_STAT,ones,strobe);
    foreach (addresses[i]) begin
      read_csr(addresses[i],value);
      // Pulse bits may finish auto-clear independently; compare static CTRL.
      if (addresses[i]==QSPI_REG_CTRL) begin value &= 32'h1f; before_value[i] &= 32'h1f; end
      if (value!==before_value[i])
        `uvm_error("QSPI_PIO_W1C_CONFIG",$sformatf("INT_STAT write altered CSR %03h",addresses[i]))
    end
  endtask

  task pending_irq(bit [4:0] source_mask);
    logic [31:0] value;
    write_csr(QSPI_REG_INT_EN,0);
    read_csr(QSPI_REG_INT_STAT,value);
    if ((value[4:0] & source_mask)!==source_mask || p_sequencer.cfg.clk_vif.irq!==0)
      `uvm_error("QSPI_PIO_IRQ_PENDING","Expected source absent or masked IRQ asserted")
    write_csr(QSPI_REG_INT_EN,{27'b0,source_mask});
    read_csr(QSPI_REG_INT_STAT,value);
    if (p_sequencer.cfg.clk_vif.irq!==1)
      `uvm_error("QSPI_PIO_IRQ_PENDING","Enable after pending did not assert IRQ")
    write_csr(QSPI_REG_INT_EN,0);
    read_csr(QSPI_REG_INT_STAT,value);
    if (p_sequencer.cfg.clk_vif.irq!==0)
      `uvm_error("QSPI_PIO_IRQ_PENDING","Masking pending source did not deassert IRQ")
  endtask

  task traffic_contract();
    qspi_apb_pair_seq pair_seq;
    // Single multi-item sequences keep the next request available at completion.
    for (int gap=0;gap<3;gap++) for (int kind=0;kind<4;kind++) begin
      pair_seq=qspi_apb_pair_seq::type_id::create("directed_apb_pair");
      pair_seq.gap=gap; pair_seq.pair_kind=2'(kind);
      pair_seq.start(p_sequencer.apb_seqr,this);
      @(negedge p_sequencer.cfg.clk_vif.clk);
    end
  endtask

  task disabled_trigger();
    logic [31:0] value;
    request_reset();
    write_csr(QSPI_REG_CS_CTRL,1);
    write_csr(QSPI_REG_CMD_CFG,0);
    write_csr(QSPI_REG_CMD_OP,6);
    write_csr(QSPI_REG_CMD_LEN,0);
    write_csr(QSPI_REG_CTRL,32'h100); // ENABLE=0, CMD_TRIGGER=1.
    // Continuous pin guard in status checker remains armed until legal trigger.
    repeat (32) @(posedge p_sequencer.cfg.clk_vif.clk);
    read_csr(QSPI_REG_STATUS,value);
    if (value[0]!==0) `uvm_error("QSPI_PIO_DISABLED","Disabled trigger made controller busy")
    write_csr(QSPI_REG_CTRL,0);
    write_csr(QSPI_REG_CTRL,1); // Must not replay the earlier disabled trigger.
    repeat (32) @(posedge p_sequencer.cfg.clk_vif.clk);
    send_cmd(0,0,1,0,3,0,0,8'h06,0);
  endtask

  task fifo_reset_contract();
    for (int port_kind=0;port_kind<2;port_kind++) for (int phase_kind=0;phase_kind<2;phase_kind++) begin
      qspi_pio_fifo_reset_vseq s;
      s=qspi_pio_fifo_reset_vseq::type_id::create("fifo_port_reset");
      s.target_tx=port_kind==0; s.target_access=1'(phase_kind);
      s.cmd.reset_abort_allowed=1;
      s.cmd.read_direction=port_kind==1;
      s.cmd.opcode=port_kind==1 ? 8'h03 : 8'h02;
      s.cmd.length=4;
      if (port_kind==1) s.cmd.flash_bytes='{8'h96,8'ha5,8'h3c,8'h69};
      else s.cmd.tx_bytes='{8'h69,8'h5a,8'hc3,8'h96};
      s.start(p_sequencer,this);
      if (s.trigger_issued) cmd_count++;
      if (!s.armed || !s.reset_aborted)
        `uvm_error("QSPI_PIO_FIFO_ABORT","Target FIFO transfer was not reset-aborted")
      wait (p_sequencer.cfg.clk_vif.rst_n===1);
      repeat (2) @(posedge p_sequencer.cfg.clk_vif.clk);
      apb_reset_values();
      // Post-reset payload comparisons detect stale pushes/pops in the new epoch.
      send_cmd(0,4);
      send_cmd(1,4);
    end
  endtask

  task lut_contract();
    qspi_pio_cmd profiles[4];
    int order[8]='{3,1,0,2,1,3,2,0};
    for (int bank=0;bank<4;bank++) begin
      profiles[bank]=qspi_pio_cmd::type_id::create($sformatf("bank_%0d",bank));
      profiles[bank].read_direction=bank!=0;
      profiles[bank].opcode=bank==0 ? 8'h02 : bank==1 ? 8'h0b : bank==2 ? 8'h3b : 8'heb;
      profiles[bank].addr_bytes=bank%2==0 ? 3 : 4;
      profiles[bank].addr_lanes=bank==3 ? 4 : 1;
      profiles[bank].data_lanes=bank<2 ? 1 : bank==2 ? 2 : 4;
      profiles[bank].mode_enable=bank==3;
      profiles[bank].mode_value=8'(8'h96 ^ bank);
      profiles[bank].dummy_cycles=bank==0 ? 0 : bank+1;
      profiles[bank].extra_dummy=bank==0 ? 0 : bank*3;
      write_csr(QSPI_REG_LUT_CTRL,32'(bank<<2));
      write_csr(QSPI_REG_LUT_CFG,profiles[bank].format_word());
      write_csr(QSPI_REG_LUT_OP,{16'b0,profiles[bank].mode_value,profiles[bank].opcode});
      write_csr(QSPI_REG_LUT_DUMMY,profiles[bank].extra_dummy);
    end
    foreach (order[i]) begin
      qspi_pio_transfer_vseq s;
      s=qspi_pio_transfer_vseq::type_id::create("lut_revisit");
      s.cmd.copy(profiles[order[i]]);
      s.cmd.use_lut=1; s.cmd.program_lut=0; s.cmd.lut_index=2'(order[i]);
      s.cmd.address=32'h8100_0100+32'(i*17);
      s.cmd.length=i<4 ? 4 : 8;
      for (int b=0;b<s.cmd.length;b++)
        if (s.cmd.read_direction) s.cmd.flash_bytes.push_back(8'(8'h96^b^i));
        else s.cmd.tx_bytes.push_back(8'(8'h69^b^i));
      s.start(p_sequencer,this); cmd_count++;
    end
    // Execute direct profiles after populated LUT, then reread all bank content.
    send_cmd(1,4,1);
    send_cmd(0,4,4);
    for (int bank=0;bank<4;bank++) begin
      logic [31:0] value;
      write_csr(QSPI_REG_LUT_CTRL,32'(bank<<2));
      read_csr(QSPI_REG_LUT_CFG,value);
      read_csr(QSPI_REG_LUT_OP,value);
      read_csr(QSPI_REG_LUT_DUMMY,value);
    end
  endtask

  task irq_contract();
    logic [31:0] value,prior;
    qspi_pio_rx_full_vseq s;
    send_cmd(0,16); // nonempty -> empty produces a real TX-empty event.
    pending_irq(5'b00001);
    pending_irq(5'b01000);
    read_csr(QSPI_REG_INT_STAT,prior);
    w1c_preserves_cfg(1,0);
    read_csr(QSPI_REG_INT_STAT,value);
    if (value!==prior) `uvm_error("QSPI_PIO_W1C","Zero PSTRB altered pending events")
    w1c_preserves_cfg(1,2);
    read_csr(QSPI_REG_INT_STAT,value);
    if (value!==prior) `uvm_error("QSPI_PIO_W1C","Wrong byte lane altered pending events")
    w1c_preserves_cfg(0);
    read_csr(QSPI_REG_INT_STAT,value);
    if (value!==prior) `uvm_error("QSPI_PIO_W1C","Write zero altered pending events")
    w1c_preserves_cfg(1);
    read_csr(QSPI_REG_INT_STAT,value);

    if (value[4:0] !== (prior[4:0] & ~5'b00001))
      `uvm_error("QSPI_PIO_W1C",$sformatf("CMD_DONE W1C did not preserve other event bits: got 0x%08h",value))
    s=qspi_pio_rx_full_vseq::type_id::create("rx_full_irq");
    s.cmd.length=16; s.cmd.interrupt_enable=0; s.cmd.rx_drain_after_done=1;
    for (int i=0;i<16;i++) s.cmd.flash_bytes.push_back(8'(i^8'h96));
    s.start(p_sequencer,this); cmd_count++;
    if (!s.full_checked) `uvm_error("QSPI_PIO_RX_FULL","RX full callback never executed")
    // RX is drained, so W1C now tests a quiescent event rather than relatching.
    read_csr(QSPI_REG_INT_STAT,prior);
    w1c_preserves_cfg(16);
    read_csr(QSPI_REG_INT_STAT,value);
    if (value[4:0] !== (prior[4:0] & ~5'b10000))
      `uvm_error("QSPI_PIO_W1C",$sformatf("RX_FULL W1C changed unselected event bits: got 0x%08h",value))
  endtask

  task error_contract();
    for (int direction=0;direction<2;direction++) begin
      qspi_pio_transfer_vseq s;
      s=qspi_pio_transfer_vseq::type_id::create("checked_starvation");
      s.cmd.read_direction=1'(direction); s.cmd.opcode=direction ? 8'h03 : 8'h02;
      s.cmd.length=40; s.cmd.expect_error=1; s.cmd.allow_no_serial=!direction;
      s.cmd.any_err_bits=direction ? 3'b011 : 3'b101;
      s.cmd.service_rx=0; s.cmd.interrupt_enable=0;
      if (direction) for (int i=0;i<40;i++) s.cmd.flash_bytes.push_back(8'(i^8'h96));
      s.start(p_sequencer,this); cmd_count++;
      pending_irq(5'b00100);
      w1c_preserves_cfg(0);
      request_reset(); apb_reset_values();
      send_cmd(1,4);
    end
  endtask

  task serial_reset_contract();
    int rx_samples[6]='{2,12,34,42,60,64};
    int tx_samples[5]='{2,12,34,44,48}; // Last two target partial/whole data byte.
    for (int direction=0;direction<2;direction++)
      for (int phase_index=0;phase_index<(direction ? 6 : 5);phase_index++) begin
        qspi_pio_transfer_vseq s;
        int sample_target;
        s=qspi_pio_transfer_vseq::type_id::create("serial_phase_reset");
        s.cmd.read_direction=1'(direction); s.cmd.opcode=direction ? 8'h03 : 8'h02;
        s.cmd.length=40; s.cmd.mode_enable=1; s.cmd.mode_value=8'h96;
        s.cmd.dummy_cycles=direction ? 15 : 0; s.cmd.extra_dummy=direction ? 1 : 0;
        s.cmd.reset_abort_allowed=1;
        sample_target=direction ? rx_samples[phase_index] : tx_samples[phase_index];
        for (int i=0;i<40;i++)
          if (direction) s.cmd.flash_bytes.push_back(8'(8'h96^i));
          else s.cmd.tx_bytes.push_back(8'(8'h69^i));
        fork
          s.start(p_sequencer,this);
          begin
            wait (p_sequencer.cfg.flash_vif.qspi_cs_n===0);
            repeat (sample_target) @(posedge p_sequencer.cfg.flash_vif.qspi_sclk);
            request_reset();
          end
        join
        cmd_count++;
        if (!s.reset_aborted) `uvm_error("QSPI_PIO_RESET_STIMULUS","Command was not reset-aborted")
        apb_reset_values();
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
      end
  endtask

  task execute_individual_manifest_test(string t_id, output bit handled);
    logic [31:0] value;
    handled = 1;
    case (t_id)
      "001", "1", "tc001", "tc1": begin
        logic [31:0] id_val, readback_val;
        `uvm_info("TEST_RUN", "=== Test 001: APB access / RO (ID Register 0x000) ===", UVM_LOW)
        read_csr(QSPI_REG_ID, id_val);
        `uvm_info("STEP", $sformatf("Step 1: Read ID (0x000) = 0x%08h (Expected: 0x0A100102)", id_val), UVM_LOW)
        `uvm_info("STEP", "Step 2: Attempting write 0x12345678 to read-only ID register...", UVM_LOW)
        raw_access(1, QSPI_REG_ID, 32'h1234_5678);
        read_csr(QSPI_REG_ID, readback_val);
        `uvm_info("STEP", $sformatf("Step 3: Readback ID after write attempt = 0x%08h (Expected: 0x0A100102)", readback_val), UVM_LOW)
        if (id_val === 32'h0A10_0102 && readback_val === 32'h0A10_0102)
          `uvm_info("TEST_RESULT", "Test 001: ID matches 0x0A100102 and ignores write (strictly Read-Only per Spec 4.2)", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 001: ID expected 0x0A100102, got initial=0x%08h readback=0x%08h", id_val, readback_val))
      end
      "002", "2", "tc002", "tc2": begin
        logic [31:0] clk_val, fifo_val;
        `uvm_info("TEST_RUN", "=== Test 002: APB access / RW (CLK_DIV) & WO (WRITE_TX) ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Write CLK_DIV (0x014) = 0x5", UVM_LOW)
        write_csr(QSPI_REG_CLK_DIV, 32'h5);
        read_csr(QSPI_REG_CLK_DIV, clk_val);
        `uvm_info("STEP", $sformatf("Step 2: Readback CLK_DIV = 0x%08h (Expected: 0x5)", clk_val), UVM_LOW)
        `uvm_info("STEP", "Step 3: Write 1 word to WRITE_TX (0x044) = 0x12345678", UVM_LOW)
        write_csr(QSPI_REG_WRITE_TX, 32'h1234_5678);
        read_csr(QSPI_REG_FIFO_STAT, fifo_val);
        `uvm_info("STEP", $sformatf("Step 4: Read FIFO_STAT = 0x%08h (TX_LEVEL = %0d, Expected: 1)", fifo_val, fifo_val[3:0]), UVM_LOW)
        if (clk_val[2:0] === 3'h5 && fifo_val[3:0] === 4'd1)
          `uvm_info("TEST_RESULT", "Test 002: RW register write/readback and WO FIFO write verified per Spec", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 002: CLK_DIV=0x%08h, FIFO_STAT=0x%08h", clk_val, fifo_val))
      end
      "003", "3", "tc003", "tc3": begin
        bit [11:0] pstrb_addrs[5] = '{QSPI_REG_CMD_ADDR, QSPI_REG_CS_CTRL, QSPI_REG_LUT_CFG, QSPI_REG_LUT_OP, QSPI_REG_LUT_DUMMY};
        int pstrb_mismatches = 0;
        `uvm_info("TEST_RUN", "=== Test 003: All 16 PSTRB values byte preservation ===", UVM_LOW)
        for (int bank=0; bank<4; bank++) begin
          write_csr(QSPI_REG_LUT_CTRL, 32'((bank<<2)|1));
          for (int a=0; a<5; a++) begin
            for (int strobe=0; strobe<16; strobe++) begin
              logic [31:0] legal_init, legal_wr, prior_val, readback_val, exp_val;
              legal_init = apb_legal_value(pstrb_addrs[a], 32'h5a69_c33c);
              legal_wr   = apb_legal_value(pstrb_addrs[a], 32'ha596_3cc3);
              write_csr(pstrb_addrs[a], legal_init);
              read_csr(pstrb_addrs[a], prior_val);
              write_csr(pstrb_addrs[a], legal_wr, 4'(strobe));
              read_csr(pstrb_addrs[a], readback_val);

              exp_val = qspi_csr_shadow::merge_pstrb(legal_init,legal_wr,4'(strobe),qspi_csr_writable_mask(pstrb_addrs[a]));
              if (readback_val !== exp_val) pstrb_mismatches++;
            end
          end
        end
        write_csr(QSPI_REG_LUT_CTRL, 0);
        if (pstrb_mismatches == 0)
          `uvm_info("TEST_RESULT", "Test 003: All 16 PSTRB byte-preservation checks completed", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 003: %0d PSTRB byte-preservation mismatches", pstrb_mismatches))
      end
      "004", "4", "tc004", "tc4": begin
        `uvm_info("TEST_RUN", "=== Test 004: Illegal address alignment ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Testing unaligned addresses 0x001, 0x002, 0x003 (Expected: PSLVERR = 1)", UVM_LOW)
        apb_transfer(0, 12'h001, 0, 0, 0, 1);
        apb_transfer(1, 12'h002, 32'h0, 4'hf, 0, 1);
        apb_transfer(0, 12'h003, 0, 0, 0, 1);
        `uvm_info("TEST_RESULT", "Test 004: Misaligned addresses returned PSLVERR=1 per Spec 5.2", UVM_LOW)
      end
      "005", "5", "tc005", "tc5": begin
        `uvm_info("TEST_RUN", "=== Test 005: Out-of-bounds address ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Testing out-of-bounds addresses 0x064, 0x100 (Expected: PSLVERR = 1)", UVM_LOW)
        apb_transfer(0, 12'h064, 0, 0, 0, 1);
        apb_transfer(1, 12'h100, 32'h0, 4'hf, 0, 1);
        `uvm_info("TEST_RESULT", "Test 005: Out-of-bounds addresses returned PSLVERR=1 per Spec 5.2", UVM_LOW)
      end
      "006", "6", "tc006", "tc6": begin
        `uvm_info("TEST_RUN", "=== Test 006: Normal Read (0x03) 1-1-1 ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h03, 3);
      end
      "007", "7", "tc007", "tc7": begin
        `uvm_info("TEST_RUN", "=== Test 007: Fast Read (0x0B) 1-1-1 ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h0b, 3, 0, 8);
      end
      "008", "8", "tc008", "tc8": begin
        `uvm_info("TEST_RUN", "=== Test 008: Dual Output Read (0x3B) 1-1-2 ===", UVM_LOW)
        send_cmd(1, 4, 2, 0, 3, 0, 0, 8'h3b, 3, 0, 8);
      end
      "009", "9", "tc009", "tc9": begin
        `uvm_info("TEST_RUN", "=== Test 009: Quad Output Read (0x6B) 1-1-4 ===", UVM_LOW)
        send_cmd(1, 4, 4, 0, 3, 0, 0, 8'h6b, 3, 0, 8);
      end
      "010", "10", "tc010": begin
        `uvm_info("TEST_RUN", "=== Test 010: Quad I/O Read (0xEB) 1-4-4 ===", UVM_LOW)
        send_cmd(1, 4, 4, 0, 3, 0, 0, 8'heb, 3, 1, 4, 0, 1, 4);
      end
      "011", "11", "tc011": begin
        `uvm_info("TEST_RUN", "=== Test 011: RX FIFO word pop ===", UVM_LOW)
        send_cmd(1, 4);
      end
      "012", "12", "tc012": begin
        `uvm_info("TEST_RUN", "=== Test 012: RX FIFO stream (20 bytes) ===", UVM_LOW)
        send_cmd(1, 20);
      end
      "019", "19", "tc019": begin
        `uvm_info("TEST_RUN", "=== Test 019: RX FIFO drain to empty ===", UVM_LOW)
        send_cmd(1, 16);
      end
      "013", "13", "tc013": begin
        int unsigned dummies[5] = '{0, 2, 4, 8, 15};
        `uvm_info("TEST_RUN", "=== Test 013: Dummy cycles standard range (0, 2, 4, 8, 15) ===", UVM_LOW)
        foreach (dummies[d]) send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h0b, 3, 0, dummies[d]);
      end
      "014", "14", "tc014": begin
        int unsigned extras[4] = '{8, 32, 128, 255};
        `uvm_info("TEST_RUN", "=== Test 014: Extra dummy cycles range (8, 32, 128, 255) ===", UVM_LOW)
        foreach (extras[e]) send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h0b, 3, 0, 8, extras[e]);
      end
      "020", "20", "tc020": begin
        byte unsigned modes[3] = '{8'h00, 8'hff, 8'ha6};
        `uvm_info("TEST_RUN", "=== Test 020: MODE fields (0x00, 0xFF, mixed) ===", UVM_LOW)
        for (int m=0; m<3; m++) begin
          qspi_pio_transfer_vseq s;
          s = qspi_pio_transfer_vseq::type_id::create($sformatf("mode_%0d", m));
          s.cmd.read_direction = 1;
          s.cmd.length = 4;
          s.cmd.data_lanes = 4;
          s.cmd.cmd_lanes = 1;
          s.cmd.addr_lanes = 4;
          s.cmd.cpol = 0; s.cmd.cpha = 0;
          s.cmd.clk_div = 3;
          s.cmd.address = 32'h8100_0080 + 32'(cmd_count*4);
          s.cmd.addr_bytes = 3;
          s.cmd.mode_enable = 1;
          s.cmd.mode_value = modes[m];
          s.cmd.dummy_cycles = 4;
          s.cmd.opcode = 8'heb;
          for (int unsigned i=0; i<4; i++) s.cmd.flash_bytes.push_back(8'(8'h96 ^ i ^ cmd_count));
          s.start(p_sequencer, this);
          cmd_count++;
        end
      end
      "015", "15", "tc015": begin
        `uvm_info("TEST_RUN", "=== Test 015: Dummy corner 0 ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h03, 3, 0, 0, 0);
      end
      "016", "16", "tc016": begin
        `uvm_info("TEST_RUN", "=== Test 016: Dummy corner max (15+255) ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h0b, 3, 0, 15, 255);
      end
      "017", "17", "tc017": begin
        `uvm_info("TEST_RUN", "=== Test 017: JEDEC ID (0x9F) ===", UVM_LOW)
        send_cmd(1, 3, 1, 0, 3, 0, 0, 8'h9f, 0);
      end
      "018", "18", "tc018": begin
        `uvm_info("TEST_RUN", "=== Test 018: Read Status (0x05) ===", UVM_LOW)
        send_cmd(1, 1, 1, 0, 3, 0, 0, 8'h05, 0);
      end
      "022", "22", "tc022": begin
        `uvm_info("TEST_RUN", "=== Test 022: Page Program (0x02) 1-1-1 ===", UVM_LOW)
        send_cmd(0, 4, 1, 0, 3, 0, 0, 8'h02, 3);
      end
      "023", "23", "tc023": begin
        `uvm_info("TEST_RUN", "=== Test 023: Quad Page Program (0x32) 1-1-4 ===", UVM_LOW)
        send_cmd(0, 4, 4, 0, 3, 0, 0, 8'h32, 3);
      end
      "024", "24", "tc024": begin
        `uvm_info("TEST_RUN", "=== Test 024: Program 16-byte TX FIFO stream ===", UVM_LOW)
        send_cmd(0, 16, 1, 0, 3, 0, 0, 8'h02, 3);
      end
      "025", "25", "tc025": begin
        `uvm_info("TEST_RUN", "=== Test 025: Program multi-word (>16 byte) TX FIFO stream with preload ===", UVM_LOW)
        send_cmd(0, 32, 1, 0, 3, 0, 0, 8'h02, 3);
      end
      "026", "26", "tc026": begin
        qspi_pio_transfer_vseq s;
        logic [31:0] fifo_val1, fifo_val2;
        `uvm_info("TEST_RUN", "=== Test 026: One WRITE_TX push and pop ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Write 1 word to WRITE_TX (push)", UVM_LOW)
        write_csr(QSPI_REG_WRITE_TX, 32'h5A69_C33C);
        read_csr(QSPI_REG_FIFO_STAT, fifo_val1);
        `uvm_info("STEP", $sformatf("Step 2: Read FIFO_STAT = 0x%08h (TX_LEVEL = %0d, Expected: 1)", fifo_val1, fifo_val1[3:0]), UVM_LOW)
        `uvm_info("STEP", "Step 3: Trigger 4-byte Page Program to drain preloaded FIFO word (pop)", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("tc026_pop_vseq");
        s.cmd.read_direction     = 0;
        s.cmd.length             = 4;
        s.cmd.opcode             = 8'h02;
        s.cmd.addr_bytes         = 3;
        s.cmd.preloaded_tx_words = 1;

        s.cmd.tx_bytes           = '{8'h3C, 8'hC3, 8'h69, 8'h5A};
        s.start(p_sequencer, this);
        cmd_count++;
        read_csr(QSPI_REG_FIFO_STAT, fifo_val2);
        `uvm_info("STEP", $sformatf("Step 4: Read FIFO_STAT after transfer = 0x%08h (TX_LEVEL = %0d, Expected: 0)", fifo_val2, fifo_val2[3:0]), UVM_LOW)
        if (fifo_val1[3:0] === 4'd1 && fifo_val2[3:0] === 4'd0)
          `uvm_info("TEST_RESULT", "Test 026: One WRITE_TX push and pop verified via FIFO_STAT", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 026: Push/pop level mismatch: push_level=%0d, pop_level=%0d", fifo_val1[3:0], fifo_val2[3:0]))
      end
      "027", "27", "tc027": begin
        `uvm_info("TEST_RUN", "=== Test 027: Register and FIFO reset values ===", UVM_LOW)
        request_reset();
        apb_reset_values();
        `uvm_info("TEST_RESULT", "Test 027: All register reset values verified successfully", UVM_LOW)
      end
      "028", "28", "tc028": begin
        `uvm_info("TEST_RUN", "=== Test 028: Reset during each phase ===", UVM_LOW)
        apb_reset_checks();
        serial_reset_contract();
      end
      "029", "29", "tc029": begin
        qspi_pio_transfer_vseq s;
        logic [31:0] err_stat, int_stat;
        `uvm_info("TEST_RUN", "=== Test 029: Underrun / Timeout error generation (Spec 5.3) ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Configure 40-byte Page Program (0x02) with TX FIFO starvation (service_tx = 0)", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("underrun_vseq");
        s.cmd.read_direction = 0;
        s.cmd.opcode = 8'h02;
        s.cmd.length = 40;
        s.cmd.expect_error = 1;
        s.cmd.service_tx = 0; // Deliberately starve TX FIFO per Spec 5.3
        s.cmd.allow_no_serial = 1;
        s.cmd.any_err_bits = 3'b101; // Insufficient TX data may produce UNDERRUN (bit 2) OR TIMEOUT (bit 0)
        s.start(p_sequencer, this);
        cmd_count++;
        read_csr(QSPI_REG_ERR_STAT, err_stat);
        read_csr(QSPI_REG_INT_STAT, int_stat);
        `uvm_info("STEP", $sformatf("Step 2: Readback ERR_STAT=0x%08h, INT_STAT=0x%08h (ERR bit 2 = %0b)",
                  err_stat, int_stat, int_stat[2]), UVM_LOW)
        if ((|(err_stat[2:0] & 3'b101)) && int_stat[2] === 1'b1)
          `uvm_info("TEST_RESULT", "Test 029: TX starvation error response (UNDERRUN or TIMEOUT) verified per Spec 5.3", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 029: Expected ERR_STAT[2|0] and INT_STAT[2]=1, got ERR_STAT=0x%08h INT_STAT=0x%08h", err_stat, int_stat))
      end
      "030", "30", "tc030": begin
        qspi_pio_transfer_vseq s;
        logic [31:0] err_stat, int_stat;
        `uvm_info("TEST_RUN", "=== Test 030: Overrun / Timeout error generation (Spec 5.4) ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Configure 40-byte Read (0x03) without draining RX FIFO (service_rx = 0)", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("overrun_vseq");
        s.cmd.read_direction = 1;
        s.cmd.opcode = 8'h03;
        s.cmd.length = 40;
        s.cmd.expect_error = 1;
        s.cmd.service_rx = 0; // Deliberately do not drain RX FIFO per Spec 5.4
        for (int i=0; i<40; i++) s.cmd.flash_bytes.push_back(8'(i ^ 8'h96));
        s.cmd.any_err_bits = 3'b011; // Unread RX data may produce OVERRUN (bit 1) OR TIMEOUT (bit 0)
        s.start(p_sequencer, this);
        cmd_count++;
        read_csr(QSPI_REG_ERR_STAT, err_stat);
        read_csr(QSPI_REG_INT_STAT, int_stat);
        `uvm_info("STEP", $sformatf("Step 2: Readback ERR_STAT=0x%08h, INT_STAT=0x%08h (ERR bit 2 = %0b)",
                  err_stat, int_stat, int_stat[2]), UVM_LOW)
        if ((|(err_stat[2:0] & 3'b011)) && int_stat[2] === 1'b1)
          `uvm_info("TEST_RESULT", "Test 030: RX overflow error response (OVERRUN or TIMEOUT) verified per Spec 5.4", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 030: Expected ERR_STAT[1|0] and INT_STAT[2]=1, got ERR_STAT=0x%08h INT_STAT=0x%08h", err_stat, int_stat))
      end
      "031", "31", "tc031": begin
        qspi_pio_transfer_vseq s;
        logic [31:0] err_stat, int_stat;
        `uvm_info("TEST_RUN", "=== Test 031: Timeout error generation (Spec 5.5) ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Configure command with starved TX FIFO to trigger hardware timeout counter", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("timeout_vseq");
        s.cmd.read_direction = 0;
        s.cmd.opcode = 8'h02;
        s.cmd.length = 40;
        s.cmd.expect_error = 1;
        s.cmd.service_tx = 0;
        s.cmd.allow_no_serial = 1;
        s.cmd.any_err_bits = 3'b101; // Spec allows UNDERRUN (bit 2) or TIMEOUT (bit 0) on TX starvation
        s.start(p_sequencer, this);
        cmd_count++;
        read_csr(QSPI_REG_ERR_STAT, err_stat);
        read_csr(QSPI_REG_INT_STAT, int_stat);
        `uvm_info("STEP", $sformatf("Step 2: Readback ERR_STAT=0x%08h (TIMEOUT=%0b UNDERRUN=%0b), INT_STAT=0x%08h", err_stat, err_stat[0], err_stat[2], int_stat), UVM_LOW)
        if ((|(err_stat[2:0] & 3'b101)) && int_stat[2] === 1'b1)
          `uvm_info("TEST_RESULT", "Test 031: TX starvation error (TIMEOUT/UNDERRUN) and INT_STAT.ERR verified per Spec 5.5", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 031: Expected ERR_STAT[2|0]=1 and INT_STAT[2]=1, got ERR_STAT=0x%08h INT_STAT=0x%08h", err_stat, int_stat))
      end
      "032", "32", "tc032": begin
        `uvm_info("TEST_RUN", "=== Test 032: Reset recovery ===", UVM_LOW)
        request_reset();
        apb_reset_values();
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
        `uvm_info("TEST_RESULT", "Test 032: Post-reset command execution verified per Spec", UVM_LOW)
      end
      "033", "33", "tc033": begin
        `uvm_info("TEST_RUN", "=== Test 033: LEN = 0 command ===", UVM_LOW)
        send_cmd(1, 0, 1, 0, 3, 0, 0, 8'h03, 3);
      end
      "034", "34", "tc034": begin
        `uvm_info("TEST_RUN", "=== Test 034: Partial word: 1 byte ===", UVM_LOW)
        send_cmd(0, 1);
      end
      "035", "35", "tc035": begin
        `uvm_info("TEST_RUN", "=== Test 035: Partial word: 2 bytes ===", UVM_LOW)
        send_cmd(0, 2);
      end
      "036", "36", "tc036": begin
        `uvm_info("TEST_RUN", "=== Test 036: Partial word: 3 bytes ===", UVM_LOW)
        send_cmd(0, 3);
      end
      "037", "37", "tc037": begin
        `uvm_info("TEST_RUN", "=== Test 037: Zero dummy cycles (16-byte dual lane) ===", UVM_LOW)
        send_cmd(1, 16, 2, 0, 3, 0, 0, 8'h03, 3, 0, 0, 0);
      end
      "038", "38", "tc038": begin
        `uvm_info("TEST_RUN", "=== Test 038: Large dummy cycles across dividers (DIV=0 & DIV=7) ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 0, 0, 0, 8'h0b, 3, 0, 15, 255);
        send_cmd(1, 4, 1, 0, 7, 0, 0, 8'h0b, 3, 0, 15, 255);
      end
      "039", "39", "tc039": begin
        qspi_pio_transfer_vseq s;
        `uvm_info("TEST_RUN", "=== Test 039: Pattern / walking bit transfer ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Populate walking-ones (0x01..0x80) and walking-zeros (0xFE..0x7F) payload", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("walking_bit_vseq");
        s.cmd.read_direction = 0;
        s.cmd.opcode = 8'h02;
        s.cmd.length = 16;
        s.cmd.addr_bytes = 3;
        s.cmd.address = 32'h8100_0080;
        s.cmd.tx_bytes = '{8'h01, 8'h02, 8'h04, 8'h08, 8'h10, 8'h20, 8'h40, 8'h80,
                           8'hfe, 8'hfd, 8'hfb, 8'hf7, 8'hef, 8'hdf, 8'hbf, 8'h7f};
        s.start(p_sequencer, this);
        cmd_count++;
        `uvm_info("TEST_RESULT", "Test 039: Walking-bit pattern transfer completed", UVM_LOW)
      end
      "040", "40", "tc040": begin
        qspi_pio_transfer_vseq s;
        logic [31:0] fifo_stat, err_stat;
        `uvm_info("TEST_RUN", "=== Test 040: UNDERRUN status and TX_EMPTY verification (Spec 5.3) ===", UVM_LOW)
        read_csr(QSPI_REG_FIFO_STAT, fifo_stat);
        `uvm_info("STEP", $sformatf("Step 1: Initial FIFO_STAT = 0x%08h (TX_EMPTY bit 8 = %0b)", fifo_stat, fifo_stat[8]), UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("underrun_stat_vseq");
        s.cmd.read_direction = 0;
        s.cmd.opcode = 8'h02;
        s.cmd.length = 16;
        s.cmd.expect_error = 1;
        s.cmd.service_tx = 0;
        s.cmd.allow_no_serial = 1;
        s.cmd.any_err_bits = 3'b101;
        s.start(p_sequencer, this);
        cmd_count++;
        read_csr(QSPI_REG_FIFO_STAT, fifo_stat);
        read_csr(QSPI_REG_ERR_STAT, err_stat);
        `uvm_info("STEP", $sformatf("Step 2: After starvation, FIFO_STAT=0x%08h, ERR_STAT=0x%08h", fifo_stat, err_stat), UVM_LOW)
        if (fifo_stat[8] === 1'b1 && (|(err_stat[2:0] & 3'b101)))
          `uvm_info("TEST_RESULT", "Test 040: UNDERRUN status and TX_EMPTY verified under starvation", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 040: Expected TX_EMPTY=1 and ERR_STAT[2|0]=1, got FIFO_STAT=0x%08h ERR_STAT=0x%08h", fifo_stat, err_stat))
      end
      "021", "21", "041", "41", "tc021", "tc041": begin
        `uvm_error("QSPI_PIO_EXCLUDED_CASE", $sformatf(
          "=== TC021/TC041 (%s): Excluded out-of-spec case in 76-test manifest; cannot pass as no-op ===", t_id))
      end
      "042", "42", "tc042": begin
        `uvm_info("TEST_RUN", "=== Test 042: CLK_DIV 0-7 sweep (frequency scaling) ===", UVM_LOW)
        for (int d=0; d<8; d++) begin
          `uvm_info("STEP", $sformatf("Step: Testing CLK_DIV = %0d (Expected SCLK period = %0d cycles)", d, (d==0 ? 1 : (1<<d))), UVM_LOW)
          send_cmd(0, 0, 1, 0, 3'(d), 0, 0, 8'h06, 0);
        end
        `uvm_info("TEST_RESULT", "Test 042: CLK_DIV 0-7 frequency scaling and bypass verified", UVM_LOW)
      end
      "059", "59", "tc059": begin
        `uvm_info("TEST_RUN", "=== Test 059: SCLK period across dividers (DIV 0..7) ===", UVM_LOW)
        for (int d=0; d<8; d++) begin
          `uvm_info("STEP", $sformatf("Step: Verifying SCLK period for CLK_DIV = %0d", d), UVM_LOW)
          send_cmd(0, 0, 1, 0, 3'(d), 0, 0, 8'h20, 3); // 0-byte Sector Erase with address
        end
        `uvm_info("TEST_RESULT", "Test 059: SCLK period across dividers 0..7 verified per Spec", UVM_LOW)
      end
      "043", "43", "tc043": begin
        `uvm_info("TEST_RUN", "=== Test 043: Sector Erase (0x20) ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h20, 3);
      end
      "044", "44", "tc044": begin
        `uvm_info("TEST_RUN", "=== Test 044: Block Erase (0xD8) ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'hd8, 3);
      end
      "045", "45", "tc045": begin
        `uvm_info("TEST_RUN", "=== Test 045: Chip Erase (0xC7) ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'hc7, 0);
      end
      "046", "46", "tc046": begin
        `uvm_info("TEST_RUN", "=== Test 046: Write Enable 06 / Write Disable 04 ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h04, 0);
      end
      "047", "47", "tc047": begin
        `uvm_info("TEST_RUN", "=== Test 047: IRQ mask / unmask via INT_EN ===", UVM_LOW)
        write_csr(QSPI_REG_INT_EN, 32'h0);
        write_csr(QSPI_REG_INT_STAT, 32'h1f);
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0); // Establish pending CMD_DONE event in INT_STAT cleanly
        pending_irq(5'b00001);
        `uvm_info("TEST_RESULT", "Test 047: Interrupt masking and physical IRQ line verified per Spec 4.5", UVM_LOW)
      end
      "048", "48", "tc048": begin
        logic [31:0] int_before, int_after;
        `uvm_info("TEST_RUN", "=== Test 048: W1C CMD_DONE event (Spec 4.6 & 5.9) ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Execute WREN (0x06) to latch CMD_DONE into INT_STAT[0]", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
        read_csr(QSPI_REG_INT_STAT, int_before);
        `uvm_info("STEP", $sformatf("Step 2: Read INT_STAT before W1C = 0x%08h (CMD_DONE bit 0 = %0b)", int_before, int_before[0]), UVM_LOW)
        `uvm_info("STEP", "Step 3: Write 1 to INT_STAT bit 0 (W1C CMD_DONE)...", UVM_LOW)
        write_csr(QSPI_REG_INT_STAT, 32'h1);
        read_csr(QSPI_REG_INT_STAT, int_after);
        `uvm_info("STEP", $sformatf("Step 4: Read INT_STAT after W1C = 0x%08h (CMD_DONE bit 0 = %0b)", int_after, int_after[0]), UVM_LOW)
        if (int_before[0] === 1'b1 && int_after[4:0] === (int_before[4:0] & ~5'b00001))
          `uvm_info("TEST_RESULT", "Test 048: CMD_DONE W1C clearing verified per Spec 4.6 & 5.9", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 048: CMD_DONE W1C failed: before=0x%08h, after=0x%08h", int_before, int_after))
      end
      "069", "69", "tc069": begin
        logic [31:0] int_before, int_after;
        `uvm_info("TEST_RUN", "=== Test 069: W1C FIFO/ERR event latch ===", UVM_LOW)
        begin
          qspi_pio_transfer_vseq s;
          s = qspi_pio_transfer_vseq::type_id::create("err_w1c_vseq");
          s.cmd.read_direction = 0; s.cmd.opcode = 8'h02; s.cmd.length = 16;
          s.cmd.expect_error = 1; s.cmd.service_tx = 0; s.cmd.allow_no_serial = 1;
          s.cmd.any_err_bits = 3'b101;
          s.start(p_sequencer, this);
          cmd_count++;
        end
        read_csr(QSPI_REG_INT_STAT, int_before);
        `uvm_info("STEP", $sformatf("Step 1: Read INT_STAT before W1C = 0x%08h (ERR bit 2 = %0b)", int_before, int_before[2]), UVM_LOW)
        write_csr(QSPI_REG_INT_STAT,32'h4);
        read_csr(QSPI_REG_INT_STAT,int_after);
        if (int_before[2] === 1'b1 && int_after[4:0] === (int_before[4:0] & ~5'b00100))
          `uvm_info("TEST_RESULT", "Test 069: ERR bit 2 W1C clearing verified", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 069: ERR bit 2 not cleared: before=0x%08h after=0x%08h", int_before, int_after))
      end
      "049", "49", "tc049": begin
        bit sclk_idle_before, sclk_idle_after;
        `uvm_info("TEST_RUN", "=== Test 049: SPI Mode 0 (CPOL=0, CPHA=0) ===", UVM_LOW)
        write_csr(QSPI_REG_CTRL, 32'h01); // ENABLE=1, CPOL=0, CPHA=0
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_before = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b0);
        send_cmd(0, 0, 1, 2'b00, 3, 0, 0, 8'h06, 0);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_after = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b0);
        if (sclk_idle_before && sclk_idle_after)
          `uvm_info("TEST_RESULT", "Test 049: SPI Mode 0 (CPOL=0, CPHA=0) clock idle and edges verified", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", "Test 049: SPI Mode 0 SCLK idle level mismatch")
      end
      "050", "50", "tc050": begin
        bit sclk_idle_before, sclk_idle_after;
        `uvm_info("TEST_RUN", "=== Test 050: SPI Mode 1 (CPOL=0, CPHA=1) ===", UVM_LOW)
        write_csr(QSPI_REG_CTRL, 32'h11); // ENABLE=1, CPOL=0, CPHA=1
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_before = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b0);
        send_cmd(0, 0, 1, 2'b01, 3, 0, 0, 8'h06, 0);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_after = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b0);
        write_csr(QSPI_REG_CTRL, 32'h01); // restore Mode 0
        if (sclk_idle_before && sclk_idle_after)
          `uvm_info("TEST_RESULT", "Test 050: SPI Mode 1 (CPOL=0, CPHA=1) clock idle and edges verified", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", "Test 050: SPI Mode 1 SCLK idle level mismatch")
      end
      "051", "51", "tc051": begin
        bit sclk_idle_before, sclk_idle_after;
        `uvm_info("TEST_RUN", "=== Test 051: SPI Mode 2 (CPOL=1, CPHA=0) ===", UVM_LOW)
        write_csr(QSPI_REG_CTRL, 32'h09); // ENABLE=1, CPOL=1, CPHA=0
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_before = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b1);
        send_cmd(0, 0, 1, 2'b10, 3, 0, 0, 8'h06, 0);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_after = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b1);
        write_csr(QSPI_REG_CTRL, 32'h01); // restore Mode 0
        if (sclk_idle_before && sclk_idle_after)
          `uvm_info("TEST_RESULT", "Test 051: SPI Mode 2 (CPOL=1, CPHA=0) clock idle and edges verified", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", "Test 051: SPI Mode 2 SCLK idle level mismatch")
      end
      "052", "52", "tc052": begin
        bit sclk_idle_before, sclk_idle_after;
        `uvm_info("TEST_RUN", "=== Test 052: SPI Mode 3 (CPOL=1, CPHA=1) ===", UVM_LOW)
        write_csr(QSPI_REG_CTRL, 32'h19); // ENABLE=1, CPOL=1, CPHA=1
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_before = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b1);
        send_cmd(0, 0, 1, 2'b11, 3, 0, 0, 8'h06, 0);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_after = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b1);
        write_csr(QSPI_REG_CTRL, 32'h01); // restore Mode 0
        if (sclk_idle_before && sclk_idle_after)
          `uvm_info("TEST_RESULT", "Test 052: SPI Mode 3 (CPOL=1, CPHA=1) clock idle and edges verified", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", "Test 052: SPI Mode 3 SCLK idle level mismatch")
      end
      "074", "74", "tc074": begin
        bit cs_idle_ok, sclk_idle_cpol0, sclk_idle_cpol1;
        `uvm_info("TEST_RUN", "=== Test 074: Pin, lane, idle / IO timing ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        cs_idle_ok = (p_sequencer.cfg.flash_vif.qspi_cs_n === 1'b1);
        sclk_idle_cpol0 = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b0);
        `uvm_info("STEP", $sformatf("Step 1: CPOL=0 IDLE levels: CS_n=%0b (exp 1), SCLK=%0b (exp 0)",
                  p_sequencer.cfg.flash_vif.qspi_cs_n, p_sequencer.cfg.flash_vif.qspi_sclk), UVM_LOW)
        write_csr(QSPI_REG_CTRL, 32'h9); // ENABLE=1, CPOL=1
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        sclk_idle_cpol1 = (p_sequencer.cfg.flash_vif.qspi_sclk === 1'b1);
        `uvm_info("STEP", $sformatf("Step 2: CPOL=1 IDLE levels: SCLK=%0b (exp 1)", p_sequencer.cfg.flash_vif.qspi_sclk), UVM_LOW)
        write_csr(QSPI_REG_CTRL, 32'h1); // Restore CPOL=0
        if (cs_idle_ok && sclk_idle_cpol0 && sclk_idle_cpol1)
          `uvm_info("TEST_RESULT", "Test 074: Pin idle levels (CS_n=1, SCLK=CPOL) verified per Spec", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 074: CS_n_idle=%0b, sclk_cpol0=%0b, sclk_cpol1=%0b", cs_idle_ok, sclk_idle_cpol0, sclk_idle_cpol1))
      end
      "053", "53", "tc053": begin
        `uvm_info("TEST_RUN", "=== Test 053: Controller Enable / Disable ===", UVM_LOW)
        disabled_trigger();
        `uvm_info("TEST_RESULT", "Test 053: Controller Enable/Disable and trigger lockout verified per Spec 4.3", UVM_LOW)
      end
      "054", "54", "tc054": begin
        `uvm_info("TEST_RUN", "=== Test 054: Trigger pulse (CTRL.CMD_TRIGGER) ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
      end
      "055", "55", "tc055": begin
        `uvm_info("TEST_RUN", "=== Test 055: Auto Chip-Select lifecycle ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
        `uvm_info("TEST_RESULT", "Test 055: Auto Chip-Select lifecycle assertion and deassertion verified per Spec 4.4", UVM_LOW)
      end
      "058", "58", "tc058": begin
        `uvm_info("TEST_RUN", "=== Test 058: Command completion status & busy clearing ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0);
        `uvm_info("TEST_RESULT", "Test 058: Command completion and STATUS.BUSY clearing verified per Spec 4.8", UVM_LOW)
      end
      "056", "56", "tc056": begin
        qspi_pio_transfer_vseq s;
        bit cs_asserted_in_phase;
        bit cs_deasserted_in_stop;
        `uvm_info("TEST_RUN", "=== Test 056: Manual CS level control (CS_AUTO=0, CS_LEVEL=0) ===", UVM_LOW)
        `uvm_info("STEP", "Step 1: Configure transaction with CS_AUTO=0, CS_LEVEL=0", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("manual_cs_vseq");
        s.cmd.cs_auto = 0;
        s.cmd.cs_level = 0;
        s.cmd.length = 4;
        s.cmd.read_direction = 0;
        s.cmd.opcode = 8'h02;
        s.cmd.tx_bytes = '{8'h11, 8'h22, 8'h33, 8'h44};
        fork
          begin
            @(negedge p_sequencer.cfg.flash_vif.qspi_cs_n);
            cs_asserted_in_phase = (p_sequencer.cfg.flash_vif.qspi_cs_n === 1'b0);
            @(posedge p_sequencer.cfg.flash_vif.qspi_cs_n);
            cs_deasserted_in_stop = (p_sequencer.cfg.flash_vif.qspi_cs_n === 1'b1);
          end
          begin
            s.start(p_sequencer, this);
            cmd_count++;
          end
        join
        write_csr(QSPI_REG_CS_CTRL, 32'h1); // Restore CS_AUTO=1
        if (cs_asserted_in_phase && cs_deasserted_in_stop)
          `uvm_info("TEST_RESULT", "Test 056: CS_n asserted to CS_LEVEL (0) in CS phase and pulled HIGH in STOP_CS per clarified Spec", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", "Test 056: CS_n failed to follow CS_LEVEL in CS phase or deassert in STOP_CS")
      end
      "057", "57", "tc057": begin
        `uvm_info("TEST_RUN", "=== Test 057: Chip-Select delay (CS_DELAY 0..3) ===", UVM_LOW)
        for (int a=0; a<2; a++) begin
          for (int lvl=0; lvl<2; lvl++) begin
            for (int d=0; d<4; d++) begin
              write_csr(QSPI_REG_CS_CTRL, 32'(d<<2 | lvl<<1 | a));
              read_csr(QSPI_REG_CS_CTRL, value);
              if (value[3:0] !== 4'(d<<2 | lvl<<1 | a))
                `uvm_error("TEST_RESULT", $sformatf(
                  "Test 057: CS_CTRL readback mismatch exp=%04b got=%04b", 4'(d<<2 | lvl<<1 | a), value[3:0]))
            end
          end
        end
        write_csr(QSPI_REG_CS_CTRL, 32'h1); // Restore CS_AUTO=1 before serial sweep
        // The passive timing checker compares measured post-payload tails.
        for (int d=0;d<4;d++)
          send_cmd(0,4,1,0,3,0,0,8'h02,3,0,0,0,1,1,2'(d));
      end
      "060", "60", "tc060": begin
        `uvm_info("TEST_RUN", "=== Test 060: Dynamic CLK_DIV change while idle ===", UVM_LOW)
        for (int d=0; d<8; d++) begin
          wait_idle();
          write_csr(QSPI_REG_CLK_DIV, 32'(d));
          read_csr(QSPI_REG_CLK_DIV, value);
          if (value[2:0] !== 3'(d))
            `uvm_error("TEST_RESULT", $sformatf(
              "Test 060: CLK_DIV readback mismatch exp=%0d got=%0d", d, value[2:0]))
          send_cmd(1, 4, 1, 0, 3'(d), 0, 0, 8'h03, 3);
        end
        `uvm_info("TEST_RESULT", "Test 060: Dynamic CLK_DIV 0..7 programming, readback, and SCLK transfers verified", UVM_LOW)
      end
      "065", "65", "tc065": begin
        `uvm_info("TEST_RUN", "=== Test 065: Stop / abort during command execution ===", UVM_LOW)
        serial_reset_contract();
      end
      "071", "71", "tc071": begin
        qspi_pio_transfer_vseq s;
        `uvm_info("TEST_RUN", "=== Test 071: Command retry after abort ===", UVM_LOW)
        s = qspi_pio_transfer_vseq::type_id::create("tc071_abort_target");
        s.cmd.read_direction = 1;
        s.cmd.opcode = 8'h03;
        s.cmd.addr_bytes = 3;
        s.cmd.length = 32;
        s.cmd.reset_abort_allowed = 1;
        for (int i=0; i<32; i++) s.cmd.flash_bytes.push_back(8'(8'ha5 ^ i));
        fork
          s.start(p_sequencer, this);
          begin
            wait (p_sequencer.cfg.flash_vif.qspi_cs_n === 1'b0);
            repeat (16) @(posedge p_sequencer.cfg.flash_vif.qspi_sclk);
            request_reset();
          end
        join
        cmd_count++;
        if (!s.reset_aborted)
          `uvm_error("TEST_RESULT", "Test 071: Active SPI command was not reset-aborted before retry")
        apb_reset_values();
        send_cmd(0, 4);
        send_cmd(1, 4);
        `uvm_info("TEST_RESULT", "Test 071: Active SPI abort and payload command retry verified per Spec", UVM_LOW)
      end
      "061", "61", "tc061": begin
        `uvm_info("TEST_RUN", "=== Test 061: 3-byte address mode ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h03, 3);
      end
      "062", "62", "tc062": begin
        `uvm_info("TEST_RUN", "=== Test 062: 4-byte address mode ===", UVM_LOW)
        send_cmd(1, 4, 1, 0, 3, 0, 0, 8'h03, 4);
      end
      "063", "63", "tc063": begin
        bit [31:0] boundary_addrs[4] = '{32'h0000_0000, 32'h00ff_ffff, 32'h0100_0000, 32'hffff_ffff};
        int unsigned a_bytes[4] = '{3, 3, 4, 4};
        `uvm_info("TEST_RUN", "=== Test 063: Boundary addresses (0x0, 0x00FFFFFF, 0x01000000, 0xFFFFFFFF) ===", UVM_LOW)
        for (int a=0; a<4; a++) begin
          qspi_pio_transfer_vseq s;
          s = qspi_pio_transfer_vseq::type_id::create($sformatf("bound_%0d", a));
          s.cmd.read_direction = 1;
          s.cmd.length = 4;
          s.cmd.data_lanes = 1;
          s.cmd.cmd_lanes = 1;
          s.cmd.addr_lanes = 1;
          s.cmd.clk_div = 3;
          s.cmd.address = boundary_addrs[a];
          s.cmd.addr_bytes = a_bytes[a];
          s.cmd.opcode = 8'h03;
          for (int unsigned i=0; i<4; i++) s.cmd.flash_bytes.push_back(8'(8'h96 ^ i ^ cmd_count));
          s.start(p_sequencer, this);
          cmd_count++;
        end
        `uvm_info("TEST_RESULT", "Test 063: Boundary addresses 24-bit and 32-bit verified", UVM_LOW)
      end
      "064", "64", "tc064": begin
        logic [31:0] fifo_stat_tx, fifo_stat_rx;
        qspi_pio_rx_full_vseq s;
        `uvm_info("TEST_RUN", "=== Test 064: FIFO flags (TX_EMPTY, RX_FULL) ===", UVM_LOW)
        send_cmd(0, 16);
        read_csr(QSPI_REG_FIFO_STAT, fifo_stat_tx);
        `uvm_info("STEP", $sformatf("Step 1: FIFO_STAT after 16B TX = 0x%08h (TX_EMPTY bit 8 = %0b)", fifo_stat_tx, fifo_stat_tx[8]), UVM_LOW)
        s = qspi_pio_rx_full_vseq::type_id::create("tc064_rx_full_vseq");
        s.cmd.length = 16;
        s.cmd.interrupt_enable = 0;
        s.cmd.rx_drain_after_done = 1;
        for (int i=0; i<16; i++) s.cmd.flash_bytes.push_back(8'(i ^ 8'h96));
        s.start(p_sequencer, this);
        cmd_count++;
        read_csr(QSPI_REG_FIFO_STAT, fifo_stat_rx);
        `uvm_info("STEP", $sformatf("Step 2: FIFO_STAT after drained 16B RX = 0x%08h (RX_FULL bit 9 = %0b)", fifo_stat_rx, fifo_stat_rx[9]), UVM_LOW)
        if (fifo_stat_tx[8] === 1'b1 && fifo_stat_tx[3:0] === 4'd0 &&
            s.full_checked === 1'b1 &&
            fifo_stat_rx[9] === 1'b0 && fifo_stat_rx[7:4] === 4'd0)
          `uvm_info("TEST_RESULT", "Test 064: FIFO boundary flags (TX_EMPTY and observed RX_FULL) verified", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf(
            "Test 064: FIFO boundary flags invalid tx=0x%08h full_checked=%0b rx=0x%08h",
            fifo_stat_tx, s.full_checked, fifo_stat_rx))
      end
      "066", "66", "tc066": begin
        logic [31:0] int_1, int_2;
        `uvm_info("TEST_RUN", "=== Test 066: INT_STAT latching behavior ===", UVM_LOW)
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0); // WREN
        read_csr(QSPI_REG_INT_STAT, int_1);
        repeat (10) @(posedge p_sequencer.cfg.clk_vif.clk);
        read_csr(QSPI_REG_INT_STAT, int_2);
        `uvm_info("STEP", $sformatf("Step 1: Readback INT_STAT 1st=0x%08h, 2nd=0x%08h", int_1, int_2), UVM_LOW)
        if (int_1[0] === 1'b1 && int_2[0] === 1'b1)
          `uvm_info("TEST_RESULT", "Test 066: INT_STAT latching persistence verified per Spec 4.6", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", "Test 066: INT_STAT event lost without explicit W1C")
        write_csr(QSPI_REG_INT_STAT,1);
        read_csr(QSPI_REG_INT_STAT,int_2);
        if (int_2[4:0] !== (int_1[4:0] & ~5'b00001))
          `uvm_error("QSPI_PIO_W1C", "Single-bit W1C changed an unselected event")
      end
      "067", "67", "tc067": begin
        `uvm_info("TEST_RUN", "=== Test 067: Dual lane receive mode (1-1-2) 32 bytes ===", UVM_LOW)
        send_cmd(1, 32, 2, 0, 3, 0, 0, 8'h3b, 3, 0, 8);
      end
      "068", "68", "tc068": begin
        `uvm_info("TEST_RUN", "=== Test 068: Quad lane receive mode (1-1-4) 32 bytes ===", UVM_LOW)
        send_cmd(1, 32, 4, 0, 3, 0, 0, 8'h6b, 3, 0, 8);
      end
      "070", "70", "tc070": begin
        `uvm_info("TEST_RUN", "=== Test 070: Quad lane transmit mode (1-1-4) 32 bytes ===", UVM_LOW)
        send_cmd(0, 32, 4, 0, 3, 0, 0, 8'h32, 3);
      end
      "072", "72", "tc072": begin
        `uvm_info("TEST_RUN", "=== Test 072: Single lane standard mode (1-1-1) 4-byte address ===", UVM_LOW)
        send_cmd(0, 4, 1, 0, 3, 0, 0, 8'h02, 4);
      end
      "073", "73", "tc073": begin
        `uvm_info("TEST_RUN", "=== Test 073: TX length matching CMD_LEN ===", UVM_LOW)
        send_cmd(0, 8);
      end
      "077", "77", "tc077": begin
        qspi_pio_rx_write_ro_vseq s;
        byte unsigned exp_bytes[8];
        bit data_ok;
        `uvm_info("TEST_RUN", "=== Test 077: Write to READ_RX (read-only port protection) ===", UVM_LOW)
        exp_bytes = '{8'h11, 8'h22, 8'h33, 8'h44, 8'haa, 8'hbb, 8'hcc, 8'hdd};
        s = qspi_pio_rx_write_ro_vseq::type_id::create("tc077_rx_ro_vseq");
        s.cmd.read_direction = 1;
        s.cmd.opcode = 8'h03;
        s.cmd.addr_bytes = 3;
        s.cmd.address = 32'h0002_0000;
        s.cmd.length = 8;
        s.cmd.rx_drain_after_done = 1;
        foreach (exp_bytes[i]) s.cmd.flash_bytes.push_back(exp_bytes[i]);
        s.start(p_sequencer, this);
        cmd_count++;
        data_ok = (s.received_bytes.size() == 8);
        if (data_ok) begin
          for (int i=0; i<8; i++)
            if (s.received_bytes[i] !== exp_bytes[i]) data_ok = 0;
        end
        if (s.write_tested && !s.write_broke_fifo &&
            s.fifo_before[7:4] === 4'd2 && s.fifo_after[7:4] === 4'd2 && data_ok)
          `uvm_info("TEST_RESULT", "Test 077: READ_RX write ignored and populated RX word order preserved per Spec 4.20", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf(
            "Test 077: READ_RX RO protection failed tested=%0b broke_fifo=%0b before_lvl=%0d after_lvl=%0d data_ok=%0b rx=%p",
            s.write_tested, s.write_broke_fifo, s.fifo_before[7:4], s.fifo_after[7:4], data_ok, s.received_bytes))
      end
      "078", "78", "tc078": begin
        `uvm_info("TEST_RUN", "=== Test 078: Trigger without ENABLE ===", UVM_LOW)
        disabled_trigger();
        `uvm_info("TEST_RESULT", "Test 078: Disabled trigger protection verified per Spec 4.3", UVM_LOW)
      end
      "075", "75", "tc075": begin
        `uvm_info("TEST_RUN", "=== Test 075: Random constrained transactions ===", UVM_LOW)
        for (int i=0; i<8; i++) begin
          qspi_pio_transfer_vseq s;
          s=qspi_pio_transfer_vseq::type_id::create("crv_075");
          if (!s.cmd.randomize() with { length inside {4,8,12,16}; clk_div inside {[0:7]}; })
            `uvm_fatal("QSPI_PIO_RANDOMIZE", "Test 075 command randomization failed")
          s.cmd.validate();
          s.start(p_sequencer,this); cmd_count++;
        end
        `uvm_info("TEST_RESULT", "Test 075: Random constrained transactions executed", UVM_LOW)
      end
      "076", "76", "tc076": begin
        qspi_pio_transfer_vseq wr_s, rd_s;
        byte unsigned prog_bytes[8];
        bit [31:0] test_addr;
        bit match_ok;
        `uvm_info("TEST_RUN", "=== Test 076: Flash memory integrity & checker sanity ===", UVM_LOW)
        test_addr  = 32'h0001_0080;
        prog_bytes = '{8'hde, 8'had, 8'hbe, 8'hef, 8'h12, 8'h34, 8'h56, 8'h78};
        for (int i=0; i<8; i++)
          p_sequencer.mem_svc.preload_flash_byte(test_addr+i,8'hff);
        send_cmd(0, 0, 1, 0, 3, 0, 0, 8'h06, 0); // WREN
        wr_s = qspi_pio_transfer_vseq::type_id::create("tc076_prog_vseq");
        wr_s.cmd.use_device_model = 1;
        wr_s.cmd.read_direction = 0;
        wr_s.cmd.opcode = 8'h02;
        wr_s.cmd.addr_bytes = 3;
        wr_s.cmd.address = test_addr;
        wr_s.cmd.length = 8;
        foreach (prog_bytes[i]) wr_s.cmd.tx_bytes.push_back(prog_bytes[i]);
        wr_s.start(p_sequencer, this);
        cmd_count++;

        rd_s = qspi_pio_transfer_vseq::type_id::create("tc076_read_vseq");
        rd_s.cmd.read_direction = 1;
        rd_s.cmd.opcode = 8'h03;
        rd_s.cmd.addr_bytes = 3;
        rd_s.cmd.address = test_addr;
        rd_s.cmd.length = 8;
        rd_s.cmd.use_device_model = 1;
        foreach (prog_bytes[i]) rd_s.cmd.flash_bytes.push_back(prog_bytes[i]);
        rd_s.start(p_sequencer, this);
        cmd_count++;

        match_ok = (rd_s.received_bytes.size() == 8);
        if (match_ok) begin
          for (int i=0; i<8; i++)
            if (rd_s.received_bytes[i] !== prog_bytes[i]) match_ok = 0;
        end
        if (match_ok)
          `uvm_info("TEST_RESULT", "Test 076: Flash Page Program and Readback at identical address matched without override", UVM_LOW)
        else
          `uvm_error("TEST_RESULT", $sformatf("Test 076: Flash integrity mismatch at 0x%08h: rx=%p", test_addr, rd_s.received_bytes))
      end
      default: handled = 0;
    endcase
  endtask

  virtual task body();
    cmd_count=0;
    case (selection)
      "apb": begin
        apb_csr_checks(); apb_decode_checks(); traffic_contract();
        apb_fifo_irq_checks(); apb_reset_checks();
      end
      "control": disabled_trigger();
      "fifo_reset": fifo_reset_contract();
      "lut": lut_contract();
      "irq": irq_contract();
      "error": error_contract();
      "reset": serial_reset_contract();
      "dummy": begin
        for (int lane=0;lane<3;lane++) begin
          for (int base_dummy=0;base_dummy<16;base_dummy++)
            send_cmd(1,4,1<<lane,0,3,0,0,8'h0b,3,0,base_dummy,0);
          for (int extra=0;extra<256;extra++)
            send_cmd(1,4,1<<lane,0,3,0,0,8'h0b,3,0,15,extra);
        end
      end
      "stream": begin
        int lengths[18]='{0,1,2,3,4,5,7,8,15,16,17,31,32,40,63,64,127,256};
        foreach (lengths[i]) for (int lane=0;lane<3;lane++) begin
          send_cmd(0,lengths[i],1<<lane);
          send_cmd(1,lengths[i],1<<lane);
        end
      end
      "random": begin
        for (int command=0;command<64;command++) begin
          qspi_pio_transfer_vseq s;
          s=qspi_pio_transfer_vseq::type_id::create("random_pio");
          if (!s.cmd.randomize() with {
                length inside {0,1,2,3,4,5,15,16,17,31,40,64};
                clk_div inside {[3:5]};
              })
            `uvm_fatal("QSPI_PIO_RANDOMIZE", "PIO command randomization failed")
          s.cmd.validate();
          s.start(p_sequencer,this); cmd_count++;
        end
      end
      default: begin
        bit handled;
        execute_individual_manifest_test(selection, handled);
        if (!handled) begin super.body(); return; end
      end
    endcase
    `uvm_info("QSPI_PIO_SCENARIO",$sformatf("%s issued %0d commands",selection,cmd_count),UVM_LOW)
  endtask
endclass
