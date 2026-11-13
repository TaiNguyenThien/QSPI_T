// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : dma_axi_sva.sv
// Role   : SystemVerilog Assertions for AXI4 Master DMA Interface
// Spec   : VNCHIP_QSPI_Controller_Specification_Rev1.1 & Spec Clarifications 1-5
// =============================================================================

`ifndef DMA_AXI_SVA_SV
`define DMA_AXI_SVA_SV

module dma_axi_sva (
  input logic        clk,
  input logic        rst_n,

  // AXI4 Write Address Channel
  input logic [31:0] awaddr,
  input logic [7:0]  awlen,
  input logic [2:0]  awsize,
  input logic [1:0]  awburst,
  input logic        awvalid,
  input logic        awready,

  // AXI4 Write Data Channel
  input logic [31:0] wdata,
  input logic [3:0]  wstrb,
  input logic        wlast,
  input logic        wvalid,
  input logic        wready,

  // AXI4 Write Response Channel
  input logic [1:0]  bresp,
  input logic        bvalid,
  input logic        bready,

  // AXI4 Read Address Channel
  input logic [31:0] araddr,
  input logic [7:0]  arlen,
  input logic [2:0]  arsize,
  input logic [1:0]  arburst,
  input logic        arvalid,
  input logic        arready,

  // AXI4 Read Data Channel
  input logic [31:0] rdata,
  input logic [1:0]  rresp,
  input logic        rlast,
  input logic        rvalid,
  input logic        rready
);

  default clocking cb @(posedge clk);
  endclocking

  default disable iff (!rst_n);

  // Intermediate end-address wires for 4KB boundary checks (Xcelium-safe part-select)
  wire [31:0] aw_end_addr = awaddr + ((32'(awlen) + 32'd1) << awsize) - 32'd1;
  wire [31:0] ar_end_addr = araddr + ((32'(arlen) + 32'd1) << arsize) - 32'd1;

  // 1. Control signals must never be X/Z out of reset
  sva_no_xz_ctrl: assert property (
    !$isunknown({awvalid, wvalid, bready, arvalid, rready})
  ) else $error("[DMA_AXI_SVA] AXI Master control signals contain X/Z");

  // 2. Write Address Channel Fixed Attributes (INCR=2'b01 or FIXED=2'b00, AWSIZE=3'b010 (4B), 4B-aligned)
  sva_aw_fixed_attr: assert property (
    awvalid |-> (awburst inside {2'b00, 2'b01}) && (awsize == 3'b010) && (awaddr[1:0] == 2'b00) &&
                !$isunknown({awaddr, awlen, awsize, awburst})
  ) else $error("[DMA_AXI_SVA] Illegal AW attributes: awaddr=0x%08h awburst=%0b awsize=%0b", awaddr, awburst, awsize);

  // 3. Read Address Channel Fixed Attributes (INCR=2'b01 or FIXED=2'b00, ARSIZE=3'b010 (4B), 4B-aligned)
  sva_ar_fixed_attr: assert property (
    arvalid |-> (arburst inside {2'b00, 2'b01}) && (arsize == 3'b010) && (araddr[1:0] == 2'b00) &&
                !$isunknown({araddr, arlen, arsize, arburst})
  ) else $error("[DMA_AXI_SVA] Illegal AR attributes: araddr=0x%08h arburst=%0b arsize=%0b", araddr, arburst, arsize);

  // 4. Half-Duplex Exclusivity: AWVALID and ARVALID must not be asserted simultaneously
  sva_axi_half_duplex: assert property (
    !(awvalid && arvalid)
  ) else $error("[DMA_AXI_SVA] Half-duplex violation: AWVALID and ARVALID asserted simultaneously");

  // 5. Write Strobe Legality per Spec Clarification 5.1 & 5.5:
  //    Non-last beats must have WSTRB=4'b1111; last beat must be in {4'b1111, 4'b0111, 4'b0011, 4'b0001}
  sva_w_valid_strb: assert property (
    wvalid |-> (!$isunknown({wstrb, wlast})) &&
               (wlast ? (wstrb inside {4'b1111, 4'b0111, 4'b0011, 4'b0001}) : (wstrb == 4'b1111))
  ) else $error("[DMA_AXI_SVA] Illegal WSTRB=%04b with WLAST=%0b", wstrb, wlast);

  // 6. Handshake Stability per ARM AXI4 Spec A3.2.1:
  //    Once VALID is asserted, it MUST remain 1 and payload MUST remain stable until READY is asserted
  sva_aw_stable: assert property (
    (awvalid && !awready) |=> awvalid && $stable({awaddr, awlen, awsize, awburst})
  ) else $error("[DMA_AXI_SVA] AW channel unstable before AWREADY");

  sva_w_stable: assert property (
    (wvalid && !wready) |=> wvalid && $stable({wdata, wstrb, wlast})
  ) else $error("[DMA_AXI_SVA] W channel unstable before WREADY");

  sva_ar_stable: assert property (
    (arvalid && !arready) |=> arvalid && $stable({araddr, arlen, arsize, arburst})
  ) else $error("[DMA_AXI_SVA] AR channel unstable before ARREADY");

  // 7. AXI4 4KB Boundary Crossing Prohibition
  sva_axi_no_4kb_cross_aw: assert property (
    awvalid |-> (awaddr[31:12] == aw_end_addr[31:12])
  ) else $error("[DMA_AXI_SVA] AW burst crosses 4KB boundary: awaddr=0x%08h awlen=%0d end=0x%08h", awaddr, awlen, aw_end_addr);

  sva_axi_no_4kb_cross_ar: assert property (
    arvalid |-> (araddr[31:12] == ar_end_addr[31:12])
  ) else $error("[DMA_AXI_SVA] AR burst crosses 4KB boundary: araddr=0x%08h arlen=%0d end=0x%08h", araddr, arlen, ar_end_addr);

endmodule : dma_axi_sva

`endif // DMA_AXI_SVA_SV
