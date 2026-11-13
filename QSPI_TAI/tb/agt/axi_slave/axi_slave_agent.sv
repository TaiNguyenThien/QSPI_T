
class axi_slave_agent extends uvm_agent;

    `uvm_component_utils(axi_slave_agent)

    virtual axi_if axi_vif;
    virtual clk_rst_irq_if clk_vif;

    axi_slave_driver    driver;
    axi_slave_monitor   monitor;
    axi_slave_sequencer sequencer;

    function new(string name="axi_slave_agent", uvm_component parent);
        super.new(name,parent);
    endfunction: new

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", axi_vif))
            `uvm_fatal("AXI_AGT","Cannot get axi_vif")

        if(!uvm_config_db#(virtual clk_rst_irq_if)::get(this,"","clk_vif",clk_vif))
            `uvm_fatal("AXI_AGT","Cannot get clk_vif")

        driver    = axi_slave_driver::type_id::create("driver", this);
        sequencer = axi_slave_sequencer::type_id::create("sequencer", this);
        monitor   = axi_slave_monitor::type_id::create("monitor", this);

        uvm_config_db#(virtual axi_if)::set(this,"driver","axi_vif",axi_vif);
        uvm_config_db#(virtual axi_if)::set(this,"driver","axi_if",axi_vif);
        uvm_config_db#(virtual axi_if)::set(this,"monitor","axi_vif",axi_vif);
        uvm_config_db#(virtual axi_if)::set(this,"monitor","axi_if",axi_vif);

        uvm_config_db#(virtual clk_rst_irq_if)::set(this,"driver","clk_vif",clk_vif);
        uvm_config_db#(virtual clk_rst_irq_if)::set(this,"monitor","clk_vif",clk_vif);

    endfunction: build_phase

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if(get_is_active() == UVM_ACTIVE) begin
            driver.seq_item_port.connect(sequencer.seq_item_export);
        end
    endfunction: connect_phase

endclass
