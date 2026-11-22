`ifndef QSPI_DMA_CRV_ITEM_SV
`define QSPI_DMA_CRV_ITEM_SV

// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : qspi_dma_crv_item.sv
// Role   : Reusable CRV Stimulus & Configuration Object for DMA Sequences
// =============================================================================

class qspi_dma_crv_item extends uvm_object;
  `uvm_object_utils(qspi_dma_crv_item)

  rand bit          dir;           // 0: TX (RAM->Flash), 1: RX (Flash->RAM)
  rand bit          incr_addr;     // 1: INCR, 0: FIXED
  rand bit [31:0]   mem_addr;      // 4B-aligned AXI RAM address
  rand bit [31:0]   flash_addr;    // Flash byte address
  rand int unsigned len;           // Transfer byte length (> 0)
  rand bit [1:0]    cmd_lanes;     // 0:1-lane, 1:2-lane, 2:4-lane
  rand bit [1:0]    addr_lanes;
  rand bit [1:0]    data_lanes;
  rand bit [1:0]    addr_bytes_enc;// 1:3B, 2:4B
  rand bit [7:0]    opcode;
  rand bit [3:0]    dummy_cycles;
  rand bit [2:0]    clk_div;
  rand bit [1:0]    spi_mode;
  rand bit [1:0]    cs_delay;
  rand bit          lut_en;
  rand bit [1:0]    lut_idx;
  rand int unsigned aw_delay;
  rand int unsigned w_delay;
  rand int unsigned ar_delay;
  rand int unsigned b_delay;
  rand int unsigned r_delay;

  // Legal hardware & Spec Clarifications 5.2/5.5 bounds (always active)
  constraint c_legal_bounds {
    mem_addr[1:0]  == 2'b00;
    mem_addr       inside {[32'h0000_1000 : 32'h003F_E000]};
    flash_addr     inside {[32'h0001_0000 : 32'h007F_E000]};
    len            inside {[1 : 4100]};
    cmd_lanes      != 2'b11;
    addr_lanes     != 2'b11;
    data_lanes     != 2'b11;
    addr_bytes_enc inside {2'b01, 2'b10};

    // Valid Flash memory opcode pairing by direction & data lanes
    if (dir == 1'b1) {
      if (data_lanes == 2'b00) {
        opcode inside {8'h03, 8'h0B};
        cmd_lanes  == 2'b00;
        addr_lanes == 2'b00;
        if (opcode == 8'h03) dummy_cycles == 4'd0;
        else                 dummy_cycles inside {[4'd1:4'd8]};
      } else if (data_lanes == 2'b01) {
        opcode     == 8'h3B;
        cmd_lanes  == 2'b00;
        addr_lanes inside {2'b00, 2'b01};
        dummy_cycles inside {[4'd4:4'd8]};
      } else {
        opcode     inside {8'h6B, 8'hEB};
        cmd_lanes  == 2'b00;
        addr_lanes inside {2'b00, 2'b10};
        dummy_cycles inside {[4'd6:4'd8]};
      }
    } else {
      dummy_cycles == 4'd0;
      cmd_lanes    == 2'b00;
      addr_lanes   == 2'b00;
      if (data_lanes == 2'b10) opcode == 8'h32;
      else {
        data_lanes == 2'b00;
        opcode     == 8'h02;
      }
    }

    aw_delay <= 16;
    w_delay  <= 16;
    ar_delay <= 16;
    b_delay  <= 16;
    r_delay  <= 16;
  }

  // Toggleable policy constraints
  constraint c_policy_fast_stress {
    len        inside {[1 : 64]};
    incr_addr  == 1'b1;
    clk_div    inside {[3'd0 : 3'd2]};
    addr_bytes_enc == 2'b01;
    aw_delay   <= 3;
    w_delay    <= 3;
    ar_delay   <= 3;
    b_delay    <= 3;
    r_delay    <= 3;
  }

  constraint c_policy_zero_axi_delay {
    aw_delay == 0;
    w_delay  == 0;
    ar_delay == 0;
    b_delay  == 0;
    r_delay  == 0;
  }

  function new(string name = "qspi_dma_crv_item");
    super.new(name);
  endfunction

  virtual function bit validate();
    if (len == 0 || mem_addr[1:0] != 2'b00) return 1'b0;
    if (cmd_lanes == 2'b11 || addr_lanes == 2'b11 || data_lanes == 2'b11) return 1'b0;
    if (!(addr_bytes_enc inside {2'b01, 2'b10})) return 1'b0;
    return 1'b1;
  endfunction

  virtual function void do_copy(uvm_object rhs);
    qspi_dma_crv_item other;
    if (!$cast(other, rhs)) begin
      `uvm_fatal("DMA_CRV_COPY", "Incompatible object passed to qspi_dma_crv_item::do_copy")
      return;
    end
    super.do_copy(rhs);
    dir            = other.dir;
    incr_addr      = other.incr_addr;
    mem_addr       = other.mem_addr;
    flash_addr     = other.flash_addr;
    len            = other.len;
    cmd_lanes      = other.cmd_lanes;
    addr_lanes     = other.addr_lanes;
    data_lanes     = other.data_lanes;
    addr_bytes_enc = other.addr_bytes_enc;
    opcode         = other.opcode;
    dummy_cycles   = other.dummy_cycles;
    clk_div        = other.clk_div;
    spi_mode       = other.spi_mode;
    cs_delay       = other.cs_delay;
    lut_en         = other.lut_en;
    lut_idx        = other.lut_idx;
    aw_delay       = other.aw_delay;
    w_delay        = other.w_delay;
    ar_delay       = other.ar_delay;
    b_delay        = other.b_delay;
    r_delay        = other.r_delay;
  endfunction

  virtual function bit do_compare(uvm_object rhs, uvm_comparer comparer);
    qspi_dma_crv_item other;
    if (!$cast(other, rhs)) return 1'b0;
    return super.do_compare(rhs, comparer) &&
           (dir == other.dir) && (incr_addr == other.incr_addr) &&
           (mem_addr == other.mem_addr) && (flash_addr == other.flash_addr) &&
           (len == other.len) && (cmd_lanes == other.cmd_lanes) &&
           (addr_lanes == other.addr_lanes) && (data_lanes == other.data_lanes) &&
           (addr_bytes_enc == other.addr_bytes_enc) && (opcode == other.opcode) &&
           (dummy_cycles == other.dummy_cycles) && (clk_div == other.clk_div) &&
           (spi_mode == other.spi_mode) && (cs_delay == other.cs_delay) &&
           (lut_en == other.lut_en) && (lut_idx == other.lut_idx) &&
           (aw_delay == other.aw_delay) && (w_delay == other.w_delay) &&
           (ar_delay == other.ar_delay) && (b_delay == other.b_delay) &&
           (r_delay == other.r_delay);
  endfunction

  virtual function string convert2string();
    return $sformatf(
      "dir=%s incr=%0b ram=0x%08h flash=0x%08h len=%0d op=0x%02h lanes=%0d-%0d-%0d ab=%0d dum=%0d div=%0d mode=%0d lut=%0b[%0d] dly=(%0d,%0d,%0d,%0d,%0d)",
      (dir ? "RX" : "TX"), incr_addr, mem_addr, flash_addr, len, opcode,
      qspi_enc_to_lanes(cmd_lanes), qspi_enc_to_lanes(addr_lanes), qspi_enc_to_lanes(data_lanes),
      qspi_enc_to_addr_bytes(addr_bytes_enc), dummy_cycles, clk_div, spi_mode,
      lut_en, lut_idx, aw_delay, w_delay, ar_delay, b_delay, r_delay);
  endfunction

endclass : qspi_dma_crv_item

`endif // QSPI_DMA_CRV_ITEM_SV
