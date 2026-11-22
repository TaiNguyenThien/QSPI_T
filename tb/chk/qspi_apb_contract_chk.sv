// Agent contract checks use independent driver results and monitor observations.
// Counters remain enabled with +QSPI_NO_COV and survive DUT reset.
class qspi_apb_contract_chk extends uvm_component;
  `uvm_component_utils(qspi_apb_contract_chk)
  typedef qspi_apb_item_t item_t;
  qspi_env_cfg cfg;
  uvm_analysis_imp #(item_t,qspi_apb_contract_chk) monitor_imp;
  uvm_analysis_imp_driver_result #(item_t,qspi_apb_contract_chk) driver_imp;
  item_t drivers[$], monitors[$];
  int unsigned matched=0, mismatches=0, never_started=0, reset_aborts=0;
  int unsigned traffic[3][4], wait_reads=0, wait_writes=0, reads=0, writes=0;
  int unsigned fifo_aborts[2][2]; // TX/RX, SETUP/ACCESS
  int unsigned aborts[2][2], strobes[16], protections[8][2], errors[2];
  bit previous_valid, previous_write;

  function new(string name,uvm_component parent);
    super.new(name,parent);
    monitor_imp=new("monitor_imp",this);
    driver_imp=new("driver_imp",this);
    foreach (traffic[g,k]) traffic[g][k]=0;
    foreach (fifo_aborts[p,a]) fifo_aborts[p][a]=0;
    foreach (aborts[a,d]) aborts[a][d]=0;
    foreach (strobes[s]) strobes[s]=0;
    foreach (protections[p,d]) protections[p][d]=0;
    foreach (errors[d]) errors[d]=0;
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg == null || cfg.clk_vif == null || cfg.apb_cfg_h == null)
      `uvm_fatal("QSPI_APB_CONTRACT_CFG", "Missing qspi_env_cfg / clk_vif / apb_cfg_h")
  endfunction

  function void reconcile();
    item_t d,m;
    while (drivers.size()!=0 && monitors.size()!=0) begin
      d=drivers.pop_front(); m=monitors.pop_front();
      matched++;
      if (d.addr!==m.addr || d.write!==m.write || d.strb!==m.strb ||
          d.prot!==m.prot || d.reset_abort!=m.reset_abort ||
          (d.write && d.wdata!==m.wdata) ||
          (d.reset_abort && d.abort_in_access!=m.abort_in_access) ||
          (!d.reset_abort && (d.slverr!==m.slverr || d.wait_cycles!=m.wait_cycles ||
             d.completed_at!=m.completed_at || (!d.write && d.rdata!==m.rdata)))) begin
        mismatches++;
        `uvm_error("QSPI_APB_AGENT_CONTRACT",$sformatf(
          "Driver/monitor disagree: driver=%s monitor=%s",d.convert2string(),m.convert2string()))
      end
    end
  endfunction

  function void write_driver_result(item_t t);
    if (cfg != null && !cfg.enable_apb_contract) return;
    if (t==null) `uvm_fatal("QSPI_APB_AGENT_CONTRACT","Null driver result")
    if (!t.setup_started) begin
      never_started++;
      if (!t.reset_abort)
        `uvm_error("QSPI_APB_AGENT_CONTRACT","An unstarted item was completed instead of reset-aborted")
      return; // A request retired before SETUP has no bus observation.
    end
    drivers.push_back(t);
    reconcile();
  endfunction

  function void write(item_t t);
    if (cfg == null)
      `uvm_fatal("QSPI_APB_CONTRACT_CFG", "Null cfg in qspi_apb_contract_chk")
    if (!cfg.enable_apb_contract) return;
    if (t==null) `uvm_fatal("QSPI_APB_AGENT_CONTRACT","Null monitor observation")
    if (cfg.apb_cfg_h.is_active==UVM_ACTIVE) monitors.push_back(t);
    if ($isunknown({t.write,t.addr,t.strb,t.prot}) || (!t.reset_abort && $isunknown(t.slverr))) begin
      mismatches++;
      `uvm_error("QSPI_APB_AGENT_CONTRACT","Unknown monitor request/response controls")
      reconcile(); return;
    end
    if (!t.reset_abort) begin
      if (t.write) begin
        for (int lane=0; lane<4; lane++) begin
          if (t.strb[lane] === 1'b1 && $isunknown(t.wdata[8*lane +: 8])) begin
            mismatches++;
            `uvm_error("QSPI_APB_AGENT_CONTRACT","Unknown enabled APB write byte")
            break;
          end
        end
      end else if ($isunknown(t.rdata)) begin
        mismatches++;
        `uvm_error("QSPI_APB_AGENT_CONTRACT","Unknown APB read data on completed transfer")
      end
    end
    if (t.reset_abort) begin
      reset_aborts++;
      aborts[t.abort_in_access][t.write]++;
      if (t.addr==QSPI_REG_WRITE_TX) fifo_aborts[0][t.abort_in_access]++;
      if (t.addr==QSPI_REG_READ_RX) fifo_aborts[1][t.abort_in_access]++;
      previous_valid=0;
    end else begin
      protections[t.prot][t.write]++;
      if (t.write) strobes[t.strb]++;
      if (t.slverr===1) errors[t.write]++;
      if (previous_valid && t.observed_idle_cycles<3)
        traffic[t.observed_idle_cycles][{previous_write,t.write}]++;
      previous_write=t.write; previous_valid=1;
      if (t.write) begin writes++; if (t.wait_cycles!=0) wait_writes++; end
      else begin reads++; if (t.wait_cycles!=0) wait_reads++; end
    end
    reconcile();
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg == null || cfg.clk_vif == null)
      `uvm_fatal("QSPI_APB_CONTRACT_CFG", "Null cfg/clk_vif in run_phase")
    if (!cfg.enable_apb_contract) return;
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      previous_valid=0;
      uvm_wait_for_nba_region();
      #1ps;
      reconcile();
    end
  endtask

  function void check_phase(uvm_phase phase);
    string selection;
    super.check_phase(phase);
    if (cfg != null && !cfg.enable_apb_contract) return;
    reconcile();
    selection="";
    void'($value$plusargs("QSPI_PIO_CASE=%s",selection));
    if (selection=="apb")
      foreach (traffic[g,k])
        if (traffic[g][k]==0)
          `uvm_error("QSPI_APB_TRAFFIC_MISSING",$sformatf("No observed APB pair gap=%0d kind=%0d",g,k))
    if (selection=="fifo_reset")
      foreach (fifo_aborts[p,a])
        if (fifo_aborts[p][a]!=1)
          `uvm_error("QSPI_APB_FIFO_ABORT",$sformatf("Expected one FIFO abort port=%0d access=%0d got=%0d",p,a,fifo_aborts[p][a]))
    if (drivers.size()!=0 || monitors.size()!=0)
      `uvm_error("QSPI_APB_AGENT_CONTRACT",$sformatf(
        "Unmatched driver=%0d monitor=%0d",drivers.size(),monitors.size()))
  endfunction

  function void report_phase(uvm_phase phase);
    if (cfg != null && !cfg.enable_apb_contract) return;
    if (mismatches != 0)
      `uvm_error("QSPI_APB_CONTRACT", $sformatf("Contract mismatches detected: %0d", mismatches))
    else
      `uvm_info("QSPI_APB_CONTRACT", $sformatf(
        "matched=%0d mismatches=%0d unstarted=%0d read=%0d write=%0d waited_read=%0d waited_write=%0d",
        matched,mismatches,never_started,reads,writes,wait_reads,wait_writes), UVM_HIGH)
    foreach (traffic[g,k])
      if (traffic[g][k] != 0)
        `uvm_info("QSPI_APB_TRAFFIC_OBS", $sformatf("gap=%0d pair=%0d count=%0d",g,k,traffic[g][k]), UVM_HIGH)
    foreach (aborts[a,d])
      if (aborts[a][d] != 0)
        `uvm_info("QSPI_APB_ABORT_OBS", $sformatf("access=%0d write=%0d count=%0d",a,d,aborts[a][d]), UVM_HIGH)
  endfunction
endclass
