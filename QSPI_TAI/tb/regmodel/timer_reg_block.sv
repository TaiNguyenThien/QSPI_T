class qspi_reg_block extends uvm_reg_block;
  `uvm_object_utils(qspi_reg_block)
  rand clk_div      DIV;
  rand cmd_addr     CMD_ADDR;
  rand cmd_cfg      CMD_CFG;
  rand cmd_dummy    CMD_DUMMY;
  rand cmd_len      CMD_LEN;
  rand cmd_op       CMD_OP;
  rand cs_ctrl      CS_CTRL;
  rand ctrl_reg     CTRL;
  rand int_en       INT_EN;
  rand int_stat     INT_STAT;
  rand read_rx      READ_RX;
  rand write_tx     WRITE_TX;


  uvm_reg_map apb_map;

  function new(string name="qspi_reg_block");
      super.new(name,UVM_NO_COVERAGE);
  endfunction

  virtual function void build();
    DIV = clk_div::type_id::create("DIV");
    DIV.configure(this);
    DIV.build();

    CMD_ADDR = cmd_addr::type_id::create("CMD_ADDR");
    CMD_ADDR.configure(this);
    CMD_ADDR.build();

    CMD_CFG = cmd_cfg::type_id::create("CMD_CFG");
    CMD_CFG.configure(this);
    CMD_CFG.build();

    CMD_DUMMY = cmd_dummy::type_id::create("CMD_DUMMY");
    CMD_DUMMY.configure(this);
    CMD_DUMMY.build();

    CMD_LEN = cmd_len::type_id::create("CMD_LEN");
    CMD_LEN.configure(this);
    CMD_LEN.build();

    CMD_OP = cmd_op::type_id::create("CMD_OP");
    CMD_OP.configure(this);
    CMD_OP.build();

    CS_CTRL = cs_ctrl::type_id::create("CS_CTRL");
    CS_CTRL.configure(this);
    CS_CTRL.build();

    CTRL = ctrl_reg::type_id::create("CTRL");
    CTRL.configure(this);
    CTRL.build();

    INT_EN = int_en::type_id::create("INT_EN");
    INT_EN.configure(this);
    INT_EN.build();

    INT_STAT = int_stat::type_id::create("INT_STAT");
    INT_STAT.configure(this);
    INT_STAT.build();

    READ_RX = read_rx::type_id::create("READ_RX");
    READ_RX.configure(this);
    READ_RX.build();

    WRITE_TX = write_tx::type_id::create("WRITE_TX");
    WRITE_TX.configure(this);
    WRITE_TX.build();

    apb_map = create_map("apb_map",0,4,UVM_LITTLE_ENDIAN);

    apb_map.add_reg(DIV,32'h14,"RW");
    apb_map.add_reg(CMD_ADDR,32'h2c,"RW");
    apb_map.add_reg(CMD_CFG,32'h24,"RW");
    apb_map.add_reg(CMD_DUMMY,32'h34,"RW");
    apb_map.add_reg(CMD_LEN,32'h30,"RW");
    apb_map.add_reg(CMD_OP,32'h28,"RW");
    apb_map.add_reg(CS_CTRL,32'h18,"RW");
    apb_map.add_reg(CTRL,32'h04,"RW");
    apb_map.add_reg(INT_EN,32'h0c,"RW");
    apb_map.add_reg(INT_STAT,32'h10,"W1C");
    apb_map.add_reg(READ_RX,32'h48,"RO");
    apb_map.add_reg(WRITE_TX,32'h44,"WO");

    lock_model();
  endfunction
endclass