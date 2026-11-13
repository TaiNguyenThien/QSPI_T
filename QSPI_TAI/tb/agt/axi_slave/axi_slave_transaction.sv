class axi_slave_transaction extends uvm_sequence_item;

    // --- Address Phase ---
    rand bit [31:0] addr;       // m_awaddr hoặc m_araddr (dùng cho cg_dma_addr_boundary)
    rand bit [7:0]  len;        // m_awlen hoặc m_arlen (0..255, số beats = len + 1)
    rand bit [2:0]  size;       // m_awsize hoặc m_arsize (3'b010 = 4B per spec)
    rand bit [1:0]  burst;      // m_awburst hoặc m_arburst (2'b01 = INCR)
    rand bit        is_write;   // 1: Write (AW), 0: Read (AR)

    // --- Data Phase (Mảng theo từng beat trong burst) ---
    rand bit [31:0] data[];     // Payload data từng beat
    rand bit [3:0]  wstrb[];    // m_wstrb từng beat (BẮT BUỘC cho cg_axi_data_phase)
    bit             wlast_seen; // Xác nhận m_wlast bật đúng ở beat cuối
    bit             rlast_seen; // Xác nhận m_rlast bật đúng ở beat cuối

    // --- Response Phase ---
    rand bit [1:0] bresp;       // m_bresp (OKAY, SLVERR, DECERR cho Write)
    rand bit [1:0] rresp[];     // m_rresp từng beat cho Read
    int            error_beat_pos;  // 0: First beat, 1: Mid beat, 2: Last beat (cho cg_dma_axi_response)
    int            bresp_burst_pos; // 0: First burst, 1: Mid burst, 2: Last burst (cho Write multi-burst)

    // --- Handshake Timing (BẮT BUỘC cho cg_axi_handshake_delays) ---
    int unsigned awready_delay; // Số cycle slave kéo AWREADY low trước khi handshake
    int unsigned wready_delay;  // Số cycle slave kéo WREADY low trước khi handshake
    int unsigned arready_delay; // Số cycle slave kéo ARREADY low trước khi handshake
    int unsigned bvalid_delay;  // Số cycle từ lúc phát xong beat cuối đến khi có BVALID
    int unsigned rvalid_delay;  // Số cycle từ AR handshake đến khi có RVALID đầu tiên

    `uvm_object_utils_begin(axi_slave_transaction)
        `uvm_field_int(addr, UVM_ALL_ON)
        `uvm_field_int(len, UVM_ALL_ON)
        `uvm_field_int(size, UVM_ALL_ON)
        `uvm_field_int(burst, UVM_ALL_ON)
        `uvm_field_int(is_write, UVM_ALL_ON)
        `uvm_field_array_int(data, UVM_ALL_ON)
        `uvm_field_array_int(wstrb, UVM_ALL_ON)
        `uvm_field_int(bresp, UVM_ALL_ON)
        `uvm_field_array_int(rresp, UVM_ALL_ON)
    `uvm_object_utils_end

    function new(string name = "axi_slave_transaction");
        super.new(name);
    endfunction

endclass
