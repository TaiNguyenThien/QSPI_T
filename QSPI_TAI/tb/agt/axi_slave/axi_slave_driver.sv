class axi_slave_driver extends uvm_driver #(axi_slave_transaction);

    `uvm_component_utils(axi_slave_driver)

    virtual axi_if axi_vif;
    virtual clk_rst_irq_if clk_vif;

    // Byte-addressable memory
    bit [7:0] mem[longint unsigned];

    // Configuration / Knobs for testing delays & errors
    bit [1:0]        default_bresp       = 2'b00; // 2'b00: OKAY, 2'b10: SLVERR, 2'b11: DECERR
    bit [1:0]        default_rresp       = 2'b00;
    int unsigned     awready_delay_knob  = 0;     // Number of cycles to hold AWREADY low
    int unsigned     wready_delay_knob   = 0;     // Number of cycles to hold WREADY low
    int unsigned     arready_delay_knob  = 0;     // Number of cycles to hold ARREADY low
    int unsigned     bvalid_delay_knob   = 0;     // Delay before asserting BVALID
    int unsigned     rvalid_delay_knob   = 0;     // Delay before asserting RVALID
    int              inject_error_beat   = -1;    // -1: all beats use default, >=0: inject error on this beat

    // Write address information
    bit [31:0] awaddr;
    bit [7:0]  awlen;
    bit [2:0]  awsize;
    bit [1:0]  awburst;

    // Write data
    bit [31:0] wdata_queue[$];
    bit [3:0]  wstrb_queue[$];
    bit        wlast_queue[$];

    function new(string name = "axi_slave_driver", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", axi_vif)) begin
            if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_if", axi_vif))
                `uvm_fatal("AXI_DRV", "Cannot get axi_vif")
        end

        if (!uvm_config_db#(virtual clk_rst_irq_if)::get(this, "", "clk_vif", clk_vif))
            `uvm_fatal("AXI_DRV", "Cannot get clk_vif")
    endfunction

    task run_phase(uvm_phase phase);
        reset_signals();

        forever begin
            wait (clk_vif.rst_n === 1'b1);

            fork
                begin : request_thread
                    @(negedge clk_vif.clk);

                    wait (axi_vif.m_awvalid === 1'b1 || axi_vif.m_wvalid === 1'b1 || axi_vif.m_arvalid === 1'b1);

                    if (axi_vif.m_arvalid && (axi_vif.m_awvalid || axi_vif.m_wvalid)) begin
                        `uvm_error("AXI_DRV", "Read and write requests overlap")
                        if (axi_vif.m_arvalid)
                            read_handler();
                    end else if (axi_vif.m_awvalid || axi_vif.m_wvalid) begin
                        write_handler();
                    end else if (axi_vif.m_arvalid) begin
                        read_handler();
                    end
                end
                begin : reset_watcher
                    wait (clk_vif.rst_n === 1'b0);
                end
            join_any
            disable fork;
            reset_signals();
        end
    endtask

    // Reset AXI slave outputs
    task reset_signals();
        axi_vif.m_awready = 1'b0;
        axi_vif.m_wready  = 1'b0;
        axi_vif.m_bvalid  = 1'b0;
        axi_vif.m_bresp   = 2'b00;

        axi_vif.m_arready = 1'b0;
        axi_vif.m_rvalid  = 1'b0;
        axi_vif.m_rdata   = 32'h0;
        axi_vif.m_rresp   = 2'b00;
        axi_vif.m_rlast   = 1'b0;
    endtask

    // WRITE HANDLER
    task write_handler();
        int unsigned num_beats;

        wdata_queue.delete();
        wstrb_queue.delete();
        wlast_queue.delete();

        fork
            capture_aw();
            capture_w();
        join

        num_beats = awlen + 1;

        if (awburst != 2'b01)
            `uvm_error("AXI_WRITE", $sformatf("Unsupported AWBURST = %b", awburst))

        if (awsize != 3'b010)
            `uvm_error("AXI_WRITE", $sformatf("Unsupported AWSIZE = %b", awsize))

        if (wdata_queue.size() != num_beats)
            `uvm_error("AXI_WRITE", $sformatf("Expected %0d beats, received %0d beats", num_beats, wdata_queue.size()))

        for (int beat = 0; beat < wdata_queue.size(); beat++) begin
            for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
                if (wstrb_queue[beat][byte_idx]) begin
                    mem[longint'(awaddr) + beat * 4 + byte_idx] = wdata_queue[beat][byte_idx*8 +: 8];
                end
            end

            if (beat == num_beats - 1) begin
                if (!wlast_queue[beat])
                    `uvm_error("AXI_WRITE", "WLAST missing on final beat")
            end else begin
                if (wlast_queue[beat])
                    `uvm_error("AXI_WRITE", "WLAST asserted before final beat")
            end
        end

        `uvm_info("AXI_WRITE", $sformatf("Write completed: ADDR=0x%08h, BEATS=%0d", awaddr, num_beats), UVM_HIGH)

        send_bresp();
    endtask

    // Capture AW channel
    task capture_aw();
        if (awready_delay_knob > 0)
            repeat (awready_delay_knob) @(posedge clk_vif.clk);

        @(negedge clk_vif.clk);
        axi_vif.m_awready = 1'b1;

        do begin
            @(posedge clk_vif.clk);
        end while (!(axi_vif.m_awvalid && axi_vif.m_awready));

        awaddr  = axi_vif.m_awaddr;
        awlen   = axi_vif.m_awlen;
        awsize  = axi_vif.m_awsize;
        awburst = axi_vif.m_awburst;

        @(negedge clk_vif.clk);
        axi_vif.m_awready = 1'b0;
    endtask

    // Capture W channel
    task capture_w();
        bit got_wlast = 1'b0;

        while (!got_wlast) begin
            if (wready_delay_knob > 0)
                repeat (wready_delay_knob) @(posedge clk_vif.clk);

            @(negedge clk_vif.clk);
            axi_vif.m_wready = 1'b1;

            do begin
                @(posedge clk_vif.clk);
                if (clk_vif.rst_n !== 1'b1) return;
            end while (!(axi_vif.m_wvalid && axi_vif.m_wready));

            wdata_queue.push_back(axi_vif.m_wdata);
            wstrb_queue.push_back(axi_vif.m_wstrb);
            wlast_queue.push_back(axi_vif.m_wlast);
            got_wlast = axi_vif.m_wlast;

            @(negedge clk_vif.clk);
            axi_vif.m_wready = 1'b0;
        end
    endtask

    // Send B channel response
    task send_bresp();
        if (bvalid_delay_knob > 0)
            repeat (bvalid_delay_knob) @(posedge clk_vif.clk);

        @(negedge clk_vif.clk);
        axi_vif.m_bresp  = default_bresp;
        axi_vif.m_bvalid = 1'b1;

        do begin
            @(posedge clk_vif.clk);
        end while (!(axi_vif.m_bvalid && axi_vif.m_bready));

        @(negedge clk_vif.clk);
        axi_vif.m_bvalid = 1'b0;
        axi_vif.m_bresp  = 2'b00;
    endtask

    // READ HANDLER
    task read_handler();
        bit [31:0] araddr;
        bit [7:0]  arlen;
        bit [2:0]  arsize;
        bit [1:0]  arburst;
        bit [31:0] read_data;
        bit        saw_rresp_err = 1'b0;

        if (arready_delay_knob > 0)
            repeat (arready_delay_knob) @(posedge clk_vif.clk);

        @(negedge clk_vif.clk);
        axi_vif.m_arready = 1'b1;

        do begin
            @(posedge clk_vif.clk);
        end while (!(axi_vif.m_arvalid && axi_vif.m_arready));

        araddr  = axi_vif.m_araddr;
        arlen   = axi_vif.m_arlen;
        arsize  = axi_vif.m_arsize;
        arburst = axi_vif.m_arburst;

        @(negedge clk_vif.clk);
        axi_vif.m_arready = 1'b0;

        if (arburst != 2'b01)
            `uvm_error("AXI_READ", $sformatf("Unsupported ARBURST = %b", arburst))

        if (arsize != 3'b010)
            `uvm_error("AXI_READ", $sformatf("Unsupported ARSIZE = %b", arsize))

        for (int beat = 0; beat <= arlen; beat++) begin
            int unsigned err_abort_wait = 0;
            bit          aborted_by_master = 1'b0;

            read_data = 32'h0;
            for (int byte_idx = 0; byte_idx < 4; byte_idx++) begin
                if (mem.exists(longint'(araddr) + beat * 4 + byte_idx))
                    read_data[byte_idx*8 +: 8] = mem[longint'(araddr) + beat * 4 + byte_idx];
                else
                    read_data[byte_idx*8 +: 8] = 8'h00;
            end

            if (rvalid_delay_knob > 0)
                repeat (rvalid_delay_knob) @(posedge clk_vif.clk);

            @(negedge clk_vif.clk);
            axi_vif.m_rdata  = read_data;
            if (inject_error_beat >= 0)
                axi_vif.m_rresp  = (beat == inject_error_beat) ? default_rresp : 2'b00;
            else
                axi_vif.m_rresp  = default_rresp;
            axi_vif.m_rlast  = (beat == arlen);
            axi_vif.m_rvalid = 1'b1;

            do begin
                @(posedge clk_vif.clk);
                if (clk_vif.rst_n !== 1'b1) return;
                if (!(axi_vif.m_rvalid && axi_vif.m_rready) && saw_rresp_err) begin
                    err_abort_wait++;
                    if (err_abort_wait >= 18) begin
                        aborted_by_master = 1'b1;
                        break;
                    end
                end
            end while (!(axi_vif.m_rvalid && axi_vif.m_rready));

            if (aborted_by_master)
                break;

            if (axi_vif.m_rresp == 2'b10 || axi_vif.m_rresp == 2'b11)
                saw_rresp_err = 1'b1;

            @(negedge clk_vif.clk);
            axi_vif.m_rvalid = 1'b0;
            axi_vif.m_rlast  = 1'b0;
        end

        @(negedge clk_vif.clk);
        axi_vif.m_rvalid = 1'b0;
        axi_vif.m_rlast  = 1'b0;
        axi_vif.m_rdata  = 32'h0;
        axi_vif.m_rresp  = 2'b00;

        `uvm_info("AXI_READ", $sformatf("Read completed: ADDR=0x%08h, BEATS=%0d", araddr, arlen + 1), UVM_HIGH)
    endtask

    task write_mem(bit [31:0] addr, bit [7:0] data);
        mem[longint'(addr)] = data;
    endtask

    function bit [7:0] read_mem(bit [31:0] addr);
        if (mem.exists(longint'(addr)))
            return mem[longint'(addr)];
        else
            return 8'h00;
    endfunction

    function void clear_mem();
        mem.delete();
    endfunction

endclass
