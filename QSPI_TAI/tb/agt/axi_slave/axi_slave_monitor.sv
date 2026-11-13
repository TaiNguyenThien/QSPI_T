class axi_slave_monitor extends uvm_monitor;

    `uvm_component_utils(axi_slave_monitor)

    virtual axi_if axi_vif;
    virtual clk_rst_irq_if clk_vif;

    // Analysis port
    uvm_analysis_port #(axi_slave_transaction) item_collected_port;

    // Current transactions
    bit write_active;
    bit read_active;

    function new(string name = "axi_slave_monitor", uvm_component parent = null);
        super.new(name, parent);
        item_collected_port = new("item_collected_port", this);
    endfunction

    function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        if (!uvm_config_db#(virtual axi_if)::get(this, "", "axi_vif", axi_vif))
            `uvm_fatal("AXI_MON", "Cannot get axi_vif")

        if (!uvm_config_db#(virtual clk_rst_irq_if)::get(this, "", "clk_vif", clk_vif))
            `uvm_fatal("AXI_MON", "Cannot get clk_vif")
    endfunction

    task run_phase(uvm_phase phase);
        forever begin
            write_active = 0;
            read_active  = 0;

            wait (clk_vif.rst_n === 1'b1);

            fork
                begin : mon_write_thread
                    forever begin
                        wait (clk_vif.rst_n === 1'b1 && (axi_vif.m_awvalid === 1'b1 || axi_vif.m_wvalid === 1'b1));
                        if (read_active)
                            `uvm_error("AXI_MON", "Read and write transactions overlap")
                        write_active = 1'b1;
                        collect_write_transaction();
                        write_active = 1'b0;
                    end
                end
                begin : mon_read_thread
                    forever begin
                        wait (clk_vif.rst_n === 1'b1 && axi_vif.m_arvalid === 1'b1);
                        if (write_active)
                            `uvm_error("AXI_MON", "Read and write transactions overlap")
                        read_active = 1'b1;
                        collect_read_transaction();
                        read_active = 1'b0;
                    end
                end
                begin : mon_rst_watcher
                    wait (clk_vif.rst_n === 1'b0);
                end
            join_any
            disable fork;
        end
    endtask

    // WRITE TRANSACTION
    task collect_write_transaction();
        axi_slave_transaction tr;

        tr = axi_slave_transaction::type_id::create("write_tr");
        tr.is_write        = 1'b1;
        tr.wlast_seen      = 1'b0;
        tr.rlast_seen      = 1'b0;
        tr.error_beat_pos  = -1;
        tr.bresp_burst_pos = 0;

        tr.data  = new[0];
        tr.wstrb = new[0];
        tr.rresp = new[0];

        // Capture AW and W independently
        fork
            capture_aw(tr);
            capture_w(tr);
        join

        if (clk_vif.rst_n !== 1'b1) return;

        // Check expected number of write beats
        if (tr.data.size() != (int'(tr.len) + 1)) begin
            `uvm_error("AXI_MON", $sformatf("Write beat count mismatch: AWLEN=%0d, W beats=%0d", tr.len, tr.data.size()))
        end

        // Capture B response
        capture_b(tr);
        if (clk_vif.rst_n !== 1'b1) return;

        `uvm_info("AXI_MON", $sformatf("WRITE: ADDR=0x%08h LEN=%0d SIZE=%0d BURST=%0b BRESP=%0b",
                  tr.addr, tr.len, tr.size, tr.burst, tr.bresp), UVM_MEDIUM)

        item_collected_port.write(tr);
    endtask

    // Capture AW channel
    task capture_aw(axi_slave_transaction tr);
        int unsigned delay_count = 0;

        forever begin
            @(posedge clk_vif.clk);
            if (clk_vif.rst_n !== 1'b1) return;

            if (axi_vif.m_awvalid && axi_vif.m_awready) begin
                tr.addr          = axi_vif.m_awaddr;
                tr.len           = axi_vif.m_awlen;
                tr.size          = axi_vif.m_awsize;
                tr.burst         = axi_vif.m_awburst;
                tr.awready_delay = delay_count;
                break;
            end else if (axi_vif.m_awvalid && !axi_vif.m_awready) begin
                delay_count++;
            end
        end
    endtask

    // Capture W channel
    task capture_w(axi_slave_transaction tr);
        int unsigned delay_count = 0;
        int unsigned beat_count  = 0;
        bit first_beat           = 1'b1;
        bit got_last             = 1'b0;

        while (!got_last && beat_count < 256) begin
            @(posedge clk_vif.clk);
            if (clk_vif.rst_n !== 1'b1) return;

            if (axi_vif.m_wvalid && axi_vif.m_wready) begin
                tr.data = new[beat_count + 1](tr.data);
                tr.data[beat_count] = axi_vif.m_wdata;

                tr.wstrb = new[beat_count + 1](tr.wstrb);
                tr.wstrb[beat_count] = axi_vif.m_wstrb;

                if (axi_vif.m_wlast)
                    got_last = 1'b1;

                beat_count++;

                if (first_beat) begin
                    tr.wready_delay = delay_count;
                    first_beat = 1'b0;
                end
            end else if (first_beat && axi_vif.m_wvalid && !axi_vif.m_wready) begin
                delay_count++;
            end
        end

        if (!got_last) begin
            `uvm_error("AXI_MON", "WLAST was not detected within 256 beats")
            tr.wlast_seen = 1'b0;
        end else begin
            tr.wlast_seen = (beat_count == (int'(tr.len) + 1));
            if (!tr.wlast_seen)
                `uvm_error("AXI_MON", $sformatf("WLAST position mismatch: AWLEN=%0d, W beats=%0d", tr.len, beat_count))
        end
    endtask

    // Capture B channel
    task capture_b(axi_slave_transaction tr);
        int unsigned delay_count = 0;

        forever begin
            @(posedge clk_vif.clk);
            if (clk_vif.rst_n !== 1'b1) return;
            if (axi_vif.m_bvalid) break;
            delay_count++;
        end

        tr.bvalid_delay = delay_count;

        while (!(axi_vif.m_bvalid && axi_vif.m_bready)) begin
            @(posedge clk_vif.clk);
            if (clk_vif.rst_n !== 1'b1) return;
        end

        tr.bresp = axi_vif.m_bresp;

        if (tr.bresp == 2'b10 || tr.bresp == 2'b11) begin
            `uvm_info("AXI_MON", $sformatf("Write response error: BRESP=%0b", tr.bresp), UVM_MEDIUM)
        end
    endtask

    // READ TRANSACTION
    task collect_read_transaction();
        axi_slave_transaction tr;

        tr = axi_slave_transaction::type_id::create("read_tr");
        tr.is_write        = 1'b0;
        tr.wlast_seen      = 1'b0;
        tr.rlast_seen      = 1'b0;
        tr.error_beat_pos  = -1;
        tr.bresp_burst_pos = 0;

        tr.data  = new[0];
        tr.wstrb = new[0];
        tr.rresp = new[0];

        capture_ar(tr);
        if (clk_vif.rst_n !== 1'b1) return;

        capture_r(tr);
        if (clk_vif.rst_n !== 1'b1) return;

        `uvm_info("AXI_MON", $sformatf("READ: ADDR=0x%08h LEN=%0d SIZE=%0d BURST=%0b BEATS_CAPTURED=%0d",
                  tr.addr, tr.len, tr.size, tr.burst, tr.data.size()), UVM_MEDIUM)

        item_collected_port.write(tr);
    endtask

    // Capture AR channel
    task capture_ar(axi_slave_transaction tr);
        int unsigned delay_count = 0;

        forever begin
            @(posedge clk_vif.clk);
            if (clk_vif.rst_n !== 1'b1) return;

            if (axi_vif.m_arvalid && axi_vif.m_arready) begin
                tr.addr          = axi_vif.m_araddr;
                tr.len           = axi_vif.m_arlen;
                tr.size          = axi_vif.m_arsize;
                tr.burst         = axi_vif.m_arburst;
                tr.arready_delay = delay_count;
                break;
            end else if (axi_vif.m_arvalid && !axi_vif.m_arready) begin
                delay_count++;
            end
        end
    endtask

    // Capture R channel (supports early master abort on SLVERR/DECERR per Spec 5.4)
    task capture_r(axi_slave_transaction tr);
        int unsigned delay_count = 0;
        int unsigned num_beats   = int'(tr.len) + 1;
        bit first_valid          = 1'b1;
        bit saw_rresp_err        = 1'b0;
        bit [1:0] current_rresp;
        bit current_rlast;

        for (int beat = 0; beat < num_beats; beat++) begin
            int unsigned err_abort_wait = 0;

            // Wait for RVALID
            forever begin
                @(posedge clk_vif.clk);
                if (clk_vif.rst_n !== 1'b1) return;

                if (axi_vif.m_rvalid) begin
                    if (first_valid) begin
                        tr.rvalid_delay = delay_count;
                        first_valid = 1'b0;
                    end
                    break;
                end
                if (first_valid)
                    delay_count++;
            end

            // Wait for R handshake (or early master abort after an RRESP error beat)
            while (!(axi_vif.m_rvalid && axi_vif.m_rready)) begin
                @(posedge clk_vif.clk);
                if (clk_vif.rst_n !== 1'b1) return;
                if (saw_rresp_err) begin
                    err_abort_wait++;
                    if (err_abort_wait >= 16 || !axi_vif.m_rvalid) begin
                        `uvm_info("AXI_MON", $sformatf(
                            "Master aborted remaining R beats after RRESP error at beat %0d/%0d",
                            beat - 1, num_beats), UVM_LOW)
                        return;
                    end
                end
            end

            // Capture RDATA & RRESP
            tr.data = new[beat + 1](tr.data);
            tr.data[beat] = axi_vif.m_rdata;

            tr.rresp = new[beat + 1](tr.rresp);
            tr.rresp[beat] = axi_vif.m_rresp;

            current_rresp = axi_vif.m_rresp;
            current_rlast = axi_vif.m_rlast;

            if (beat == num_beats - 1) begin
                if (current_rlast)
                    tr.rlast_seen = 1'b1;
                else begin
                    tr.rlast_seen = 1'b0;
                    `uvm_error("AXI_MON", "RLAST missing on final read beat")
                end
            end else begin
                if (current_rlast) begin
                    tr.rlast_seen = 1'b0;
                    `uvm_error("AXI_MON", "RLAST asserted before final read beat")
                end
            end

            // Record first error response position
            if (current_rresp == 2'b10 || current_rresp == 2'b11) begin
                saw_rresp_err = 1'b1;
                if (tr.error_beat_pos == -1) begin
                    if (beat == 0)
                        tr.error_beat_pos = 0;
                    else if (beat == num_beats - 1)
                        tr.error_beat_pos = 2;
                    else
                        tr.error_beat_pos = 1;
                end
            end
        end
    endtask

endclass
