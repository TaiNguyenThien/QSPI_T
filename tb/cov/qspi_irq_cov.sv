// Passive coverage only. Published items are never modified.
class qspi_irq_cov extends uvm_subscriber #(qspi_apb_item_t);
  `uvm_component_utils(qspi_irq_cov)
  typedef qspi_apb_item_t apb_item_t;
  qspi_env_cfg cfg;
  qspi_csr_shadow csr;
  bit [4:0] interrupt_enable,last_interrupt_status;
  bit       last_int_stat_valid;
  bit [4:0] pending_w1c_mask,pending_w1c_before,pending_w1c_en,pending_w1c_irq,pending_w1c_irq_valid;
  int unsigned status_reads=0;

  covergroup status_cg with function sample(int kind, bit [31:0] value);
    option.per_instance = 1;
    cp_status: coverpoint value[3:0] iff (kind == 0) {
      bins idle     = {4'h0};
      bins pio_busy = {4'h1};
      bins xip      = {4'h2, 4'h3};
      bins cmd_done = {[4'h4:4'h7]};
      bins dma_done = {[4'h8:4'hf]};
    }
    cp_tx_level: coverpoint value[3:0] iff (kind == 1) { bins level[] = {[0:4]}; bins invalid = default; }
    cp_rx_level: coverpoint value[7:4] iff (kind == 1) { bins level[] = {[0:4]}; bins invalid = default; }
    cp_fifo_flags: coverpoint value[9:8] iff (kind == 1);
    cp_errors: coverpoint value[2:0] iff (kind == 2) {
      bins none      = {3'b000};
      bins timeout   = {3'b001};
      bins overrun   = {3'b010};
      bins underrun  = {3'b100};
      ignore_bins impossible_combinations = {3'b011, 3'b101, 3'b110, 3'b111};
    }
    levels: cross cp_tx_level, cp_rx_level;
  endgroup
  covergroup irq_cg with function sample(int source_id, bit enabled,
                                        bit pending, bit irq_level, bit clearing);
    option.per_instance = 1;
    cp_source: coverpoint source_id { bins events[] = {[0:4]}; }
    cp_enabled: coverpoint enabled;
    cp_pending: coverpoint pending;
    cp_irq: coverpoint irq_level;
    cp_clear: coverpoint clearing;
    masking: cross cp_source, cp_enabled, cp_pending, cp_irq {
      ignore_bins inconsistent_irq = (binsof(cp_enabled) intersect {1}) &&
        (binsof(cp_pending) intersect {1}) && (binsof(cp_irq) intersect {0});
    }
    clear_cases: cross cp_source, cp_pending, cp_clear;
  endgroup

  function new(string name="qspi_irq_cov",uvm_component parent=null);
    super.new(name,parent);
    csr=new("csr");
    status_cg=new();
    irq_cg=new();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg==null && !uvm_config_db#(qspi_env_cfg)::get(this,"","cfg",cfg))
      `uvm_fatal("QSPI_IRQ_COV","Missing qspi_env_cfg")
    if (cfg.clk_vif==null)
      `uvm_fatal("QSPI_IRQ_COV","Missing clk_vif in qspi_env_cfg")
  endfunction

  virtual function void write(qspi_apb_item_t t);
    if (t==null || cfg==null || cfg.clk_vif==null || t.reset_abort || t.slverr!==1'b0 ||
        cfg.clk_vif.rst_n!==1'b1 || $isunknown({t.addr,t.write,t.strb})) return;
    if (t.write) begin
      for (int lane=0;lane<4;lane++)
        if (t.strb[lane] === 1'b1 && $isunknown(t.wdata[8*lane +: 8])) return;
      void'(csr.apply_apb_write(t));
      interrupt_enable=csr.int_en[4:0];
      if (t.strb[0] && !$isunknown(t.wdata[7:0]) && t.addr==QSPI_REG_INT_STAT) begin
        if ((|t.wdata[4:0]) && last_int_stat_valid) begin

          for (int i=0;i<5;i++) begin
            if (!t.wdata[i]) continue;
            pending_w1c_mask[i] = 1;
            pending_w1c_before[i]=last_interrupt_status[i];
            pending_w1c_en[i]=interrupt_enable[i];
            pending_w1c_irq_valid[i]=!$isunknown(cfg.clk_vif.irq);
            pending_w1c_irq[i]=pending_w1c_irq_valid[i] ? cfg.clk_vif.irq : 1'b0;
          end
        end
        last_interrupt_status=qspi_csr_shadow::apply_w1c_mask(last_interrupt_status,t.wdata,t.strb);
        last_int_stat_valid=0;
      end
      return;
    end
    if ($isunknown(t.rdata)) return;
    case (t.addr)
      QSPI_REG_STATUS: begin status_cg.sample(0,t.rdata); status_reads++; end
      QSPI_REG_FIFO_STAT: begin status_cg.sample(1,t.rdata); status_reads++; end
      QSPI_REG_ERR_STAT: begin status_cg.sample(2,t.rdata); status_reads++; end
      QSPI_REG_INT_STAT: begin
        for (int i=0;i<5;i++) begin
          if (pending_w1c_mask[i]) begin
            if (pending_w1c_irq_valid[i] && (!pending_w1c_before[i] || t.rdata[i]==1'b0))
              irq_cg.sample(i,pending_w1c_en[i],pending_w1c_before[i],pending_w1c_irq[i],1);
            pending_w1c_mask[i]=1'b0;
          end
        end
        last_interrupt_status=t.rdata[4:0];
        last_int_stat_valid=1'b1;
        if (!$isunknown(cfg.clk_vif.irq)) for (int i=0;i<5;i++)
          irq_cg.sample(i,interrupt_enable[i],t.rdata[i],cfg.clk_vif.irq,0);
        status_reads++;
      end
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg==null || cfg.clk_vif==null) return;
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      csr.reset();
      interrupt_enable=0; last_interrupt_status=0; last_int_stat_valid=0;
      pending_w1c_mask=0; pending_w1c_before=0; pending_w1c_en=0;
      pending_w1c_irq=0; pending_w1c_irq_valid=0;
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_IRQ_COV",$sformatf("reads=%0d status=%.2f IRQ=%.2f percent",
      status_reads,status_cg.get_inst_coverage(),irq_cg.get_inst_coverage()),UVM_HIGH)
  endfunction
endclass : qspi_irq_cov
