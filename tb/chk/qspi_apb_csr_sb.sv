`ifndef QSPI_APB_CSR_SB_SV
`define QSPI_APB_CSR_SB_SV

// Specification-based APB CSR scoreboard for static PIO/DMA/XIP/LUT CSRs.
// Test 001 : ID is read-only, fixed value 0x0A100102.
// Test 002 : Static RW CSRs and registers access.
// Test 003 : Byte-lane enables (PSTRB) preservation.
// Test 004/005 : Misaligned/unsupported accesses assert PSLVERR.
// Test 027 : Selected configuration CSRs reset to zero.
//
// CTRL, FIFO ports and W1C event state require separate dynamic checking.
// PSTRB prediction follows the specification independently of DUT readback.
class qspi_apb_csr_sb extends uvm_scoreboard;
  `uvm_component_utils(qspi_apb_csr_sb)

  typedef qspi_apb_item_t apb_item_t;
  uvm_analysis_imp #(apb_item_t, qspi_apb_csr_sb) apb_imp;
  qspi_env_cfg cfg; // Assigned by the parent before child build.

  localparam bit [31:0] QSPI_ID_VALUE      = 32'h0A10_0102;

  localparam int unsigned NUM_MODELED_RW = 14;
  localparam int unsigned LUT_CTRL_IDX = 13;
  // Array index comes from csr_index(); it is NOT a register address.
  bit [31:0] exp_ctrl;
  bit [31:0] exp_rw[NUM_MODELED_RW];
  bit [31:0] exp_lut[4][3];
  typedef struct packed {
    bit valid;
    logic [31:0] data;
    logic [3:0] strb;
    logic [2:0] prot;
    bit [31:0] prior;
    time accepted_at;
  } write_trace_t;
  write_trace_t last_rw_write[NUM_MODELED_RW];
  write_trace_t last_lut_write[4][3];

  int unsigned id_reads=0;
  int unsigned clk_div_reads=0;
  int unsigned clk_div_writes=0;
  int unsigned other_rw_reads=0;
  int unsigned other_rw_writes=0;
  int unsigned illegal_accesses=0;
  int unsigned skipped_accesses=0;
  int unsigned reset_aborts=0;
  int unsigned reset_abort_kind[2][2]; // [SETUP/ACCESS][READ/WRITE]
  int unsigned mismatches=0;

  function new(string name = "qspi_apb_csr_sb",
               uvm_component parent = null);
    super.new(name, parent);
    apb_imp = new("apb_imp", this);
    foreach (reset_abort_kind[i,j]) reset_abort_kind[i][j]=0;
    reset_model();
  endfunction


  function void reset_model();
    exp_ctrl = 32'h0000_0000;
    for (int i = 0; i < NUM_MODELED_RW; i++) begin
      exp_rw[i] = 32'h0000_0000;
      last_rw_write[i]='0;
    end
    foreach (exp_lut[i,j]) begin
      exp_lut[i][j] = '0;
      last_lut_write[i][j]='0;
    end
  endfunction

  // Reset is monitored independently of APB transaction publication.
  task run_phase(uvm_phase phase);
    if (cfg == null || cfg.clk_vif == null)
      `uvm_fatal("QSPI_APB_CSR_CFG", "Null cfg or clk_vif in qspi_apb_csr_sb")
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      reset_model();
    end
  endtask

  // -1 identifies an address whose read/write effects are not modeled.
  function automatic int csr_index(input bit [11:0] addr);
    case (addr)
      QSPI_REG_CLK_DIV:   return 0;
      QSPI_REG_CS_CTRL:   return 1;
      QSPI_REG_CMD_CFG:   return 2;
      QSPI_REG_CMD_OP:    return 3;
      QSPI_REG_CMD_ADDR:  return 4;
      QSPI_REG_CMD_LEN:   return 5;
      QSPI_REG_CMD_DUMMY: return 6;
      QSPI_REG_INT_EN:    return 7;
      QSPI_REG_XIP_CFG:   return 8;
      QSPI_REG_XIP_CMD:   return 9;
      QSPI_REG_DMA_CFG:   return 10;
      QSPI_REG_DMA_ADDR:  return 11;
      QSPI_REG_DMA_LEN:   return 12;
      QSPI_REG_LUT_CTRL:  return LUT_CTRL_IDX;
      default:            return -1;
    endcase
  endfunction

  // Implemented writable fields from Spec sections 4.7, 4.8, 4.11-4.15.
  // Shared with qspi_flow_sb via qspi_ral_pkg::qspi_csr_writable_mask() so
  // the two independent predictors cannot drift apart from each other.
  function automatic bit [31:0] writable_mask(input bit [11:0] addr);
    return qspi_csr_writable_mask(addr);
  endfunction

  function automatic string csr_name(input bit [11:0] addr);
    case (addr)
      QSPI_REG_CLK_DIV:   return "CLK_DIV";
      QSPI_REG_CS_CTRL:   return "CS_CTRL";
      QSPI_REG_CMD_CFG:   return "CMD_CFG";
      QSPI_REG_CMD_OP:    return "CMD_OP";
      QSPI_REG_CMD_ADDR:  return "CMD_ADDR";
      QSPI_REG_CMD_LEN:   return "CMD_LEN";
      QSPI_REG_CMD_DUMMY: return "CMD_DUMMY";
      QSPI_REG_INT_EN:    return "INT_EN";
      QSPI_REG_XIP_CFG:   return "XIP_CFG";
      QSPI_REG_XIP_CMD:   return "XIP_CMD";
      QSPI_REG_DMA_CFG:   return "DMA_CFG";
      QSPI_REG_DMA_ADDR:  return "DMA_ADDR";
      QSPI_REG_DMA_LEN:   return "DMA_LEN";
      QSPI_REG_LUT_CTRL:  return "LUT_CTRL";
      QSPI_REG_LUT_CFG:   return "LUT_CFG";
      QSPI_REG_LUT_OP:    return "LUT_OP";
      QSPI_REG_LUT_DUMMY: return "LUT_DUMMY";
      default:            return "UNMODELED";
    endcase
  endfunction

  // Preserve every byte lane whose PSTRB bit is not asserted.
  function automatic bit [31:0] merge_pstrb(
      input bit [31:0] old_value,
      input logic [31:0] new_value,
      input logic [3:0]  strb
  );
    return qspi_csr_shadow::merge_pstrb(old_value, new_value, strb, 32'hFFFF_FFFF);
  endfunction

  function void report_mismatch(string msg);
    mismatches++;
    `uvm_error("QSPI_CSR_MISMATCH", msg)
  endfunction

  function write_trace_t capture_write(apb_item_t t,bit [31:0] prior);
    write_trace_t result;
    result.valid=1;
    result.data=t.wdata; result.strb=t.strb; result.prot=t.prot;
    result.prior=prior; result.accepted_at=t.completed_at;
    return result;
  endfunction

  function string write_context(write_trace_t trace_item);
    if (!trace_item.valid) return "last-write=none (reset baseline)";
    return $sformatf("prior=%08h last-write=%08h PSTRB=%04b PPROT=%03b accepted-at=%0t",
      trace_item.prior,trace_item.data,trace_item.strb,trace_item.prot,trace_item.accepted_at);
  endfunction

  // Receives ACTUAL completed/aborted transfers from the APB monitor.
  function void write(apb_item_t t);
    int csr_idx;
    int lut_field;
    int lut_idx;
    bit [31:0] exp_data;

    if (t == null) begin
      report_mismatch("Null APB monitor transaction");
      return;
    end
    if (t.reset_abort) begin
      reset_aborts++;
      if (!$isunknown(t.write)) reset_abort_kind[t.abort_in_access][t.write]++;
      return;
    end
    if (cfg.clk_vif.rst_n !== 1'b1)
      return;
    if ($isunknown({t.addr,t.write,t.strb,t.prot,t.slverr})) begin
      report_mismatch("Unknown completed APB request/response controls; CSR prediction skipped");
      return;
    end
    if (t.write)
      for (int lane=0;lane<4;lane++)
        if (t.strb[lane] && $isunknown(t.wdata[8*lane +: 8])) begin
          report_mismatch("Unknown enabled write byte; CSR prediction skipped");
          return;
        end

    // Spec 5.2: the address space is 32-bit aligned, ending at 0x060.
    if (t.addr[1:0] != 2'b00 || t.addr > QSPI_REG_LUT_DUMMY) begin
      illegal_accesses++;
      if (t.slverr !== 1'b1)
        report_mismatch($sformatf(
          "[Test 004/005] addr=%03h write=%0b expected PSLVERR=1 got=%b",
          t.addr, t.write, t.slverr));
      return;
    end

    // ID is read-only. A write must not change the next ID read.
    if (t.addr == QSPI_REG_ID) begin
      if (!t.write) begin
        id_reads++;
        if (t.slverr !== 1'b0 || t.rdata !== QSPI_ID_VALUE)
          report_mismatch($sformatf(
            "[Test 001] ID expected=%08h actual=%08h PSLVERR=%b",
            QSPI_ID_VALUE, t.rdata, t.slverr));
        else
          `uvm_info("QSPI_CSR_MATCH", $sformatf("[Test 001] ID (0x000) matched: 0x%08h", t.rdata), UVM_HIGH);
      end
      return;
    end

    // LUT_CFG/OP/DUMMY are three register windows over four selected entries.
    lut_field = -1;
    case (t.addr)
      QSPI_REG_LUT_CFG:   lut_field = 0;
      QSPI_REG_LUT_OP:    lut_field = 1;
      QSPI_REG_LUT_DUMMY: lut_field = 2;
    endcase
    if (lut_field >= 0) begin
      if (t.slverr !== 1'b0) begin
        report_mismatch($sformatf("%s unexpected PSLVERR=%b", csr_name(t.addr), t.slverr));
        return;
      end
      lut_idx = int'(exp_rw[LUT_CTRL_IDX][3:2]);
      if (t.write) begin
        last_lut_write[lut_idx][lut_field]=capture_write(t,exp_lut[lut_idx][lut_field]);
        exp_lut[lut_idx][lut_field] = merge_pstrb(
          exp_lut[lut_idx][lut_field], t.wdata, t.strb) &
          writable_mask(t.addr);
      end
      else if (t.rdata !== exp_lut[lut_idx][lut_field])
        report_mismatch($sformatf("%s[%0d] expected=%08h got=%08h; %s",
          csr_name(t.addr), lut_idx,
          exp_lut[lut_idx][lut_field], t.rdata,
          write_context(last_lut_write[lut_idx][lut_field])));
      else
        `uvm_info("QSPI_CSR_MATCH", $sformatf("%s[%0d] addr=%03h read matched: 0x%08h",
          csr_name(t.addr), lut_idx, t.addr, t.rdata), UVM_HIGH);
      return;
    end


    if (t.addr == QSPI_REG_CTRL) begin
      if (t.slverr !== 1'b0) begin
        report_mismatch($sformatf("CTRL unexpected PSLVERR=%b", t.slverr));
        return;
      end
      if (t.write) begin
        bit pre_ctrl_en;
        pre_ctrl_en = exp_ctrl[0];
        exp_ctrl = merge_pstrb(exp_ctrl, t.wdata, t.strb) & writable_mask(QSPI_REG_CTRL);
        if (t.strb[1] && t.wdata[8] && (t.strb[0] ? t.wdata[0] : pre_ctrl_en) && exp_rw[LUT_CTRL_IDX][0]) begin
          lut_idx = int'(exp_rw[LUT_CTRL_IDX][3:2]);
          exp_rw[2] = exp_lut[lut_idx][0];
          exp_rw[3] = exp_lut[lut_idx][1];
          exp_rw[6] = exp_lut[lut_idx][2];
          last_rw_write[2] = last_lut_write[lut_idx][0];
          last_rw_write[3] = last_lut_write[lut_idx][1];
          last_rw_write[6] = last_lut_write[lut_idx][2];
        end
        other_rw_writes++;
      end else begin
        skipped_accesses++;
      end
      return;
    end

    csr_idx = csr_index(t.addr);
    if (csr_idx < 0) begin
      skipped_accesses++;
      return;
    end

    if (t.slverr !== 1'b0) begin
      report_mismatch($sformatf(
        "[Test 002] %s addr=%03h unexpected PSLVERR=%b",
        csr_name(t.addr), t.addr, t.slverr));
      return;
    end

    if (t.write) begin
      // Predict specified byte-lane updates from the accepted request.
      last_rw_write[csr_idx]=capture_write(t,exp_rw[csr_idx]);
      exp_rw[csr_idx] = merge_pstrb(
        exp_rw[csr_idx], t.wdata, t.strb) & writable_mask(t.addr);
      if (t.addr == QSPI_REG_CLK_DIV) clk_div_writes++;
      else                            other_rw_writes++;
    end
    else begin
      if (t.addr == QSPI_REG_CLK_DIV) clk_div_reads++;
      else                            other_rw_reads++;

      exp_data = exp_rw[csr_idx];
      if (t.rdata !== exp_data)
        report_mismatch($sformatf(
          "[Test 003] %s addr=%03h expected=%08h actual=%08h; %s",
          csr_name(t.addr), t.addr, exp_data, t.rdata,write_context(last_rw_write[csr_idx])));
      else
        `uvm_info("QSPI_CSR_MATCH", $sformatf(
          "%s addr=%03h read matched: expected=0x%08h actual=0x%08h",
          csr_name(t.addr), t.addr, exp_data, t.rdata), UVM_HIGH);
    end
  endfunction

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (mismatches != 0)
      `uvm_error("QSPI_CSR_SUMMARY", $sformatf(
        "CSR MISMATCHES detected: %0d (ID_READ=%0d CLK_DIV_R/W=%0d/%0d RW_R/W=%0d/%0d SKIPPED=%0d INVALID=%0d ABORT=%0d)",
        mismatches, id_reads, clk_div_reads, clk_div_writes, other_rw_reads, other_rw_writes, skipped_accesses, illegal_accesses, reset_aborts))
    else
      `uvm_info("QSPI_CSR_SUMMARY", $sformatf(
        "CSR check clean: MISMATCH=0 (ID_READ=%0d CLK_DIV_R/W=%0d/%0d RW_R/W=%0d/%0d SKIPPED=%0d INVALID=%0d ABORT=%0d)",
        id_reads, clk_div_reads, clk_div_writes, other_rw_reads, other_rw_writes, skipped_accesses, illegal_accesses, reset_aborts), UVM_HIGH)
    `uvm_info("QSPI_APB_ABORT_SUMMARY",$sformatf(
      "SETUP R/W=%0d/%0d ACCESS R/W=%0d/%0d",
      reset_abort_kind[0][0],reset_abort_kind[0][1],
      reset_abort_kind[1][0],reset_abort_kind[1][1]), UVM_HIGH)
  endfunction
endclass : qspi_apb_csr_sb

`endif // QSPI_APB_CSR_SB_SV
