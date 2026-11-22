// Project specialization of the reusable APB UVC. Agents never import this.
package qspi_types_pkg;
  timeunit 1ns;
  timeprecision 1ps;
  import apb_agent_pkg::*;
  localparam int unsigned QSPI_APB_ADDR_WIDTH = 12;
  localparam int unsigned QSPI_APB_DATA_WIDTH = 32;
  localparam int unsigned QSPI_APB_STRB_WIDTH = QSPI_APB_DATA_WIDTH / 8;

  typedef apb_trans #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) qspi_apb_item_t;
  typedef apb_cfg #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) qspi_apb_cfg_t;
  typedef apb_agent #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) qspi_apb_agent_t;
  typedef apb_base_seq #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) qspi_apb_base_seq_t;
  typedef virtual apb_if #(QSPI_APB_ADDR_WIDTH, QSPI_APB_DATA_WIDTH) qspi_apb_vif_t;

  // Canonical operating modes used across passive checkers and full-chip sequences
  typedef enum bit [1:0] {
    QSPI_MODE_PIO  = 2'b00,
    QSPI_MODE_DMA  = 2'b01,
    QSPI_MODE_XIP  = 2'b10,
    QSPI_MODE_IDLE = 2'b11
  } qspi_mode_e;

  // ---------------------------------------------------------------------------
  // Pure 4-State Encoding Converters (reject X/Z and reserved 2'b11)
  // ---------------------------------------------------------------------------
  function automatic bit qspi_is_legal_lane_enc(logic [1:0] enc);
    return (!$isunknown(enc) && (enc != 2'b11));
  endfunction

  // Returns 0 on X/Z or reserved 2'b11 so callers detect invalid encodings cleanly
  function automatic int unsigned qspi_enc_to_lanes(logic [1:0] enc);
    if ($isunknown(enc))
      return 0;
    case (enc)
      2'b00:   return 1;
      2'b01:   return 2;
      2'b10:   return 4;
      default: return 0;
    endcase
  endfunction

  // Returns 2'b11 (reserved) on invalid integer lane count
  function automatic bit [1:0] qspi_lanes_to_enc(int unsigned lanes);
    case (lanes)
      1:       return 2'b00;
      2:       return 2'b01;
      4:       return 2'b10;
      default: return 2'b11;
    endcase
  endfunction

  function automatic bit qspi_is_legal_addr_enc(logic [1:0] enc);
    return (!$isunknown(enc) && (enc != 2'b11));
  endfunction

  // Returns -1 on X/Z or reserved 2'b11 because 0 is a valid 0-byte address mode
  function automatic int qspi_enc_to_addr_bytes(logic [1:0] enc);
    if ($isunknown(enc))
      return -1;
    case (enc)
      2'b00:   return 0;
      2'b01:   return 3;
      2'b10:   return 4;
      default: return -1;
    endcase
  endfunction

  // Returns 2'b11 (reserved) on invalid byte count
  function automatic bit [1:0] qspi_addr_bytes_to_enc(int bytes);
    case (bytes)
      0:       return 2'b00;
      3:       return 2'b01;
      4:       return 2'b10;
      default: return 2'b11;
    endcase
  endfunction

  // Normative QUAD_EN gating: when QUAD_EN=0, 4-lane (2'b10) falls back to 1-lane
  // uniformly across Command, Address, Mode, and Data phases.
  function automatic int unsigned qspi_eff_lanes(logic [1:0] enc, logic quad_en);
    if (!qspi_is_legal_lane_enc(enc) || $isunknown(quad_en))
      return 0;
    if (enc == 2'b10 && !quad_en)
      return 1;
    return qspi_enc_to_lanes(enc);
  endfunction

  function automatic bit [1:0] qspi_eff_lane_enc(logic [1:0] enc, logic quad_en);
    int unsigned lanes;
    lanes = qspi_eff_lanes(enc, quad_en);
    return qspi_lanes_to_enc(lanes);
  endfunction

  // ---------------------------------------------------------------------------
  // Standard Little-Endian 32-bit Word Packing (AMBA APB4 / AXI4 / AXI4-Lite)
  // First byte on wire (b0) maps to bits [7:0]; b3 maps to bits [31:24].
  // ---------------------------------------------------------------------------
  function automatic logic [31:0] qspi_pack_word_le(
    logic [7:0] b0, logic [7:0] b1, logic [7:0] b2, logic [7:0] b3
  );
    return {b3, b2, b1, b0};
  endfunction

  // Project-level QSPI XIP transaction timeout budget (in ACLK cycles).
  function automatic longint unsigned qspi_compute_xip_budget(
    int unsigned     clk_div,
    int unsigned     n_spi_frame_sclk,
    bit              is_error_path,
    longint unsigned master_stall_cycles = 0,
    longint unsigned overhead_sclk       = 16,
    longint unsigned margin_aclk         = 1000
  );
    longint unsigned divider_ratio;
    longint unsigned sclk_total;
    divider_ratio = (64'd1 << clk_div);
    sclk_total    = longint'(n_spi_frame_sclk) + overhead_sclk + (is_error_path ? 64'd2000 : 64'd0);
    return (sclk_total * divider_ratio) + master_stall_cycles + margin_aclk;
  endfunction
endpackage : qspi_types_pkg
