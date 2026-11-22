// Passive coverage only. Published items are never modified.
class qspi_reg_cov extends uvm_subscriber #(qspi_apb_item_t);
  `uvm_component_utils(qspi_reg_cov)
  typedef qspi_apb_item_t apb_item_t;
  qspi_env_cfg cfg;
  qspi_csr_shadow csr;
  bit lut_enabled;
  bit [1:0] lut_index;
  bit [31:0] control_shadow,cs_control_shadow,cmd_length;
  int unsigned access_count=0,trigger_count=0;
  covergroup csr_cg with function sample(apb_item_t t);
    option.per_instance = 1;
    cp_register: coverpoint t.addr {
      bins csr[] = {QSPI_REG_ID,QSPI_REG_CTRL,QSPI_REG_STATUS,QSPI_REG_INT_EN,QSPI_REG_INT_STAT,QSPI_REG_CLK_DIV,
                    QSPI_REG_CS_CTRL,QSPI_REG_XIP_CFG,QSPI_REG_XIP_CMD,QSPI_REG_CMD_CFG,QSPI_REG_CMD_OP,QSPI_REG_CMD_ADDR,
                    QSPI_REG_CMD_LEN,QSPI_REG_CMD_DUMMY,QSPI_REG_DMA_CFG,QSPI_REG_DMA_ADDR,QSPI_REG_DMA_LEN,QSPI_REG_WRITE_TX,
                    QSPI_REG_READ_RX,QSPI_REG_FIFO_STAT,QSPI_REG_ERR_STAT,QSPI_REG_LUT_CTRL,QSPI_REG_LUT_CFG,QSPI_REG_LUT_OP,QSPI_REG_LUT_DUMMY};
      bins unsupported = default;
      // Covers all 25 mapped QSPI CSRs (0x00..0x60) plus unmapped/misaligned decodes.
    }
    cp_write: coverpoint t.write;
    cp_strobe: coverpoint t.strb iff (t.write) { bins masks[] = {[0:15]}; }
    cp_error: coverpoint t.slverr;
    cp_alignment: coverpoint t.addr[1:0];
    cp_address_class: coverpoint (t.addr[1:0]!=0 ? 1 : t.addr>QSPI_REG_LUT_DUMMY ? 2 : 0) {
      bins mapped={0}; bins misaligned={1}; bins unsupported={2};
    }
    accesses: cross cp_register, cp_write {
      ignore_bins write_to_ro = binsof(cp_register) intersect {
        QSPI_REG_STATUS, QSPI_REG_FIFO_STAT, QSPI_REG_ERR_STAT
      } && binsof(cp_write) intersect {1};
      ignore_bins read_from_wo = binsof(cp_register) intersect {
        QSPI_REG_WRITE_TX
      } && binsof(cp_write) intersect {0};
    }
    error_decode: cross cp_address_class,cp_error {
      ignore_bins incorrect_address_error = (binsof(cp_address_class) intersect {1,2}) &&
        (binsof(cp_error) intersect {0});
      // No uniform PSLVERR rule is specified for every access direction at
      // mapped FIFO/RO/WO ports; do not require a fabricated mapped-error bin.
      ignore_bins unspecified_mapped_error = (binsof(cp_address_class) intersect {0}) &&
        (binsof(cp_error) intersect {1});
    }
    byte_writes: cross cp_register, cp_strobe {
      ignore_bins read_only_regs = binsof(cp_register) intersect {
        QSPI_REG_ID, QSPI_REG_STATUS, QSPI_REG_FIFO_STAT, QSPI_REG_ERR_STAT, QSPI_REG_READ_RX
      };
    }
  endgroup
  covergroup lut_cg with function sample(bit enabled, bit [1:0] index,
                                        int action, bit [3:0] strobe);
    option.per_instance = 1;
    cp_enable: coverpoint enabled;
    cp_index: coverpoint index { bins entries[] = {[0:3]}; }
    cp_action: coverpoint action { bins execute = {0}; bins cfg = {1}; bins op = {2}; bins dummy = {3}; bins select_entry={4}; }
    cp_strobe: coverpoint strobe iff (action != 0) { bins masks[] = {[0:15]}; }
    selection: cross cp_enable, cp_index, cp_action;
    programming: cross cp_index, cp_action, cp_strobe {
      ignore_bins execution = binsof(cp_action) intersect {0};
    }
  endgroup
  covergroup cs_cg with function sample(bit [3:0] control);
    option.per_instance=1;
    cp_auto: coverpoint control[0];
    cp_level: coverpoint control[1];
    cp_delay: coverpoint control[3:2] { bins setting[]={[0:3]}; }
    controls: cross cp_auto,cp_level,cp_delay;
  endgroup
  covergroup cmd_cg with function sample(bit [31:0] length);
    option.per_instance=1;
    cp_length: coverpoint length {
      bins none={0}; bins partial[]={[1:3]}; bins word={4};
      bins below_fifo={[5:15]}; bins fifo={16}; bins beyond_fifo={[17:31]};
      bins stream={[32:$]};
    }
    cp_remainder: coverpoint (length%4) { bins bytes[]={[0:3]}; }
  endgroup

  function new(string name="qspi_reg_cov",uvm_component parent=null);
    super.new(name,parent);
    csr=new("csr");
    csr_cg=new();
    lut_cg=new();
    cs_cg=new();
    cmd_cg=new();
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg==null && !uvm_config_db#(qspi_env_cfg)::get(this,"","cfg",cfg))
      `uvm_fatal("QSPI_REG_COV","Missing qspi_env_cfg")
    if (cfg.clk_vif==null)
      `uvm_fatal("QSPI_REG_COV","Missing clk_vif in qspi_env_cfg")
  endfunction

  function bit has_unknown_enabled_wdata(apb_item_t t);
    for (int i=0;i<4;i++) if (t.strb[i] && $isunknown(t.wdata[8*i +: 8])) return 1'b1;
    return 1'b0;
  endfunction

  virtual function void write(qspi_apb_item_t t);
    if (t==null || cfg==null || cfg.clk_vif==null || t.reset_abort || cfg.clk_vif.rst_n!==1'b1 ||
        $isunknown({t.addr,t.write,t.strb,t.prot,t.slverr})) return;
    csr_cg.sample(t); access_count++;
    if (!t.write || t.slverr!==1'b0 || has_unknown_enabled_wdata(t)) return;
    void'(csr.apply_apb_write(t));
    control_shadow=csr.ctrl; cs_control_shadow=csr.cs_ctrl; cmd_length=csr.cmd_len;
    lut_enabled=csr.lut_ctrl[0]; lut_index=csr.lut_ctrl[3:2];
    case (t.addr)
      QSPI_REG_CMD_LEN: ;
      QSPI_REG_CS_CTRL: begin
        cs_cg.sample(cs_control_shadow[3:0]);
      end
      QSPI_REG_LUT_CTRL: begin
        lut_cg.sample(lut_enabled,lut_index,4,t.strb);
      end
      QSPI_REG_LUT_CFG: lut_cg.sample(lut_enabled,lut_index,1,t.strb);
      QSPI_REG_LUT_OP: lut_cg.sample(lut_enabled,lut_index,2,t.strb);
      QSPI_REG_LUT_DUMMY: lut_cg.sample(lut_enabled,lut_index,3,t.strb);
      QSPI_REG_CTRL: begin
        bit pre_ctrl_en;
        bit eff_ctrl_en;
        pre_ctrl_en = control_shadow[0];
        eff_ctrl_en = t.strb[0] ? t.wdata[0] : pre_ctrl_en;
        if (t.strb[1] && t.wdata[8] && eff_ctrl_en && !control_shadow[1] && !t.wdata[9]) begin
          lut_cg.sample(lut_enabled,lut_index,0,'0);
          cmd_cg.sample(cmd_length);
          trigger_count++;
        end
      end
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    if (cfg==null || cfg.clk_vif==null) return;
    forever begin
      @(negedge cfg.clk_vif.rst_n);
      csr.reset();
      lut_enabled=0; lut_index=0; control_shadow=0;
      cs_control_shadow=0; cmd_length=0;
    end
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    `uvm_info("QSPI_REG_COV",$sformatf("accesses=%0d PIO-triggers=%0d CSR=%.2f LUT=%.2f CS=%.2f length=%.2f percent",
      access_count,trigger_count,csr_cg.get_inst_coverage(),lut_cg.get_inst_coverage(),
      cs_cg.get_inst_coverage(),cmd_cg.get_inst_coverage()),UVM_HIGH)
  endfunction
endclass : qspi_reg_cov
