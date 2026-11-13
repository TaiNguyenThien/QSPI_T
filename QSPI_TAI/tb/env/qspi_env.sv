class qspi_env extends uvm_env;
  `uvm_component_utils(qspi_env)

  virtual qspi_if qspi_vif;
  virtual apb_if  apb_vif;
  virtual clk_rst_irq_if clk_vif;

  qspi_cfg cfg;

  qspi_agent          qspi_agt;
  apb_agent           apb_agt;
  qspi_sb             sb;
  qspi_reg_block         regmodel;
  qspi_reg2apb_adapter   apb_adapter;

  uvm_reg_predictor #(apb_transaction) apb_predictor;


  function new(string name="qspi_env", uvm_component parent);
    super.new(name,parent);
  endfunction: new

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    `uvm_info("build_phase","Entered...",UVM_NONE)
    if(!uvm_config_db#(virtual apb_if)::get(this,"","apb_vif",apb_vif))
      `uvm_fatal(get_type_name(),$sformatf("Failed to get apb_vif from uvm_config_db"))

    if(!uvm_config_db#(virtual qspi_if)::get(this,"","qspi_vif",qspi_vif))
      `uvm_fatal(get_type_name(),"Failed to get qspi_vif")

    if(!uvm_config_db#(virtual clk_rst_irq_if)::get(this,"","clk_vif",clk_vif))
      `uvm_fatal(get_type_name(),"Failed to get clk_vif")

    if(!uvm_config_db#(qspi_cfg)::get(this,"","cfg",cfg))
      `uvm_fatal(get_type_name(),"Failed to get cfg")

    qspi_agt     = qspi_agent::type_id::create("qspi_agt", this);
    apb_agt      = apb_agent::type_id::create("apb_agt", this);
    sb           = qspi_sb::type_id::create("sb", this);

    uvm_config_db#(virtual apb_if)::set(this,"apb_agt","apb_if",apb_vif);
    uvm_config_db#(virtual qspi_if)::set(this,"qspi_agt","qspi_if",qspi_vif);
    uvm_config_db#(virtual clk_rst_irq_if)::set(this,"apb_agt","clk_if",clk_vif);
    uvm_config_db#(qspi_cfg)::set(this,"qspi_agt","cfg",cfg);


    apb_adapter  = qspi_reg2apb_adapter::type_id::create("apb_adapter");
    regmodel     = qspi_reg_block::type_id::create("regmodel",this);
    regmodel.build();

    apb_predictor = uvm_reg_predictor#(apb_transaction)::type_id::create("apb_predictor",this);

    `uvm_info("build_phase","Exiting...",UVM_NONE)
  endfunction: build_phase

  virtual function void connect_phase ( uvm_phase phase);
    super.connect_phase(phase);
    `uvm_info("connect_phase","Entered...",UVM_NONE)
    // Ket noi adapter voi ahb_sequencer
    if(regmodel.get_parent() == null)
     regmodel.apb_map.set_sequencer(apb_agt.sequencer, apb_adapter);
    // Predictor connection
     apb_predictor.map = regmodel.apb_map;
     apb_predictor.adapter = apb_adapter;
     apb_agt.monitor.item_observed_port.connect(apb_predictor.bus_in);

    /* Connect to sb */
    apb_agt.monitor.item_observed_port.connect(sb.item_collected_export_apb);
    qspi_agt.monitor.ref_port.connect(sb.item_collected_export_qspi);
    qspi_agt.flash_slave.flash_port.connect(sb.item_collected_export_flash);

    `uvm_info("connect_phase","Exiting...",UVM_NONE)
  endfunction: connect_phase

endclass