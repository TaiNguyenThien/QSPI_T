class qspi_pio_base_vseq extends qspi_base_vseq;
  `uvm_object_utils(qspi_pio_base_vseq)

  function new(string name = "qspi_pio_base_vseq");
    super.new(name);
    check_read_data_known = 1'b1;
  endfunction

  virtual task pre_body();
    super.pre_body();
    if (p_sequencer.ral_model == null)
      `uvm_fatal("QSPI_PIO_BIND", "PIO sequence requires active ral_model in virtual sequencer")
  endtask

  task wait_idle();
    logic [31:0] status;
    bit done;
    done = 0;
    fork
      begin : bounded_idle
        fork
          begin
            do begin
              read_csr(QSPI_REG_STATUS, status);
              if (reset_aborted) break;
              @(posedge p_sequencer.cfg.clk_vif.clk);
            end while (status[0] !== 1'b0);
            done = 1;
          end
          repeat (p_sequencer.cfg.transaction_timeout_cycles)
            @(posedge p_sequencer.cfg.clk_vif.clk);
        join_any
        disable fork;
      end
    join
    if (!done) `uvm_fatal("QSPI_PIO_IDLE_TIMEOUT", "STATUS.BUSY did not clear within the clock budget")
  endtask

  // Intentionally invalid addresses use raw access: the passive CSR checker
  // owns PSLVERR expectations, unlike normal configuration helpers.
  task raw_access(bit write_direction, bit [11:0] address,
                  bit [31:0] data = 0, bit [3:0] strb = 4'hf,
                  bit [2:0] protection = 0);
    if (write_direction) begin
      write_seq_t s;
      s      = write_seq_t::type_id::create("pio_raw_write");
      s.addr = address;
      s.data = data;
      s.strb = strb;
      s.prot = protection;
      s.start(p_sequencer.apb_seqr, this);
    end else begin
      read_seq_t s;
      s      = read_seq_t::type_id::create("pio_raw_read");
      s.addr = address;
      s.prot = protection;
      s.start(p_sequencer.apb_seqr, this);
    end
  endtask
endclass
