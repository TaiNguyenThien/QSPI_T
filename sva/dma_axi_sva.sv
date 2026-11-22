// =============================================================================
// Project: VNCHIP QSPI Controller Functional Verification
// File   : dma_axi_sva.sv
// Role   : SystemVerilog Assertions for AXI4 Master DMA Interface
// Spec   : VNCHIP_QSPI_Controller_Specification_Rev1.1 & Spec Clarifications 1-5
// =============================================================================

`ifndef DMA_AXI_SVA_SV
`define DMA_AXI_SVA_SV

`timescale 1ns/1ps

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
    !$isunknown({awvalid, awready, wvalid, wready, bvalid, bready, arvalid, arready, rvalid, rready})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "AXI control signals contain X/Z");

  // 2. Write Address Channel Fixed Attributes (INCR=2'b01 only per Spec 5.6.4, AWSIZE=3'b010 (4B), 4B-aligned)
  sva_aw_fixed_attr: assert property (
    awvalid |-> (awburst == 2'b01) && (awsize == 3'b010) && (awaddr[1:0] == 2'b00) &&
                !$isunknown({awaddr, awlen, awsize, awburst})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("Illegal AW attributes: awaddr=0x%08h awburst=%0b awsize=%0b", awaddr, awburst, awsize));

  // 3. Read Address Channel Fixed Attributes (INCR=2'b01 only per Spec 5.6.4, ARSIZE=3'b010 (4B), 4B-aligned)
  sva_ar_fixed_attr: assert property (
    arvalid |-> (arburst == 2'b01) && (arsize == 3'b010) && (araddr[1:0] == 2'b00) &&
                !$isunknown({araddr, arlen, arsize, arburst})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("Illegal AR attributes: araddr=0x%08h arburst=%0b arsize=%0b", araddr, arburst, arsize));

  // 4. Half-Duplex Exclusivity: AWVALID and ARVALID must not be asserted simultaneously
  sva_axi_half_duplex: assert property (
    !(awvalid && arvalid)
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    "Half-duplex violation: AWVALID and ARVALID asserted simultaneously");

  // 5. Write Strobe Legality per Spec Clarification 5.1 & 5.5:
  //    Non-last beats must have WSTRB=4'b1111; last beat must be in {4'b1111, 4'b0111, 4'b0011, 4'b0001}
  sva_w_valid_strb: assert property (
    wvalid |-> (!$isunknown({wstrb, wlast})) &&
               (wlast ? (wstrb inside {4'b1111, 4'b0111, 4'b0011, 4'b0001}) : (wstrb == 4'b1111))
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("Illegal WSTRB=%04b with WLAST=%0b", wstrb, wlast));

  // WDATA must not contain X/Z on active strobe byte lanes during W handshake
  sva_wdata_no_xz: assert property (
    (wvalid && wready) |->
      (!wstrb[0] || !$isunknown(wdata[7:0])) &&
      (!wstrb[1] || !$isunknown(wdata[15:8])) &&
      (!wstrb[2] || !$isunknown(wdata[23:16])) &&
      (!wstrb[3] || !$isunknown(wdata[31:24]))
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "WDATA contains X/Z on an active WSTRB byte lane");

  // 6. Handshake Stability per ARM AXI4 Spec A3.2.1:
  //    Once VALID is asserted, it MUST remain 1 and payload MUST remain stable until READY is asserted
  sva_aw_stable: assert property (
    (awvalid && !awready) |=> awvalid && $stable({awaddr, awlen, awsize, awburst})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "AW channel unstable before AWREADY");

  sva_w_stable: assert property (
    (wvalid && !wready) |=> wvalid && $stable({wdata, wstrb, wlast})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "W channel unstable before WREADY");

  sva_ar_stable: assert property (
    (arvalid && !arready) |=> arvalid && $stable({araddr, arlen, arsize, arburst})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "AR channel unstable before ARREADY");

  sva_b_stable: assert property (
    (bvalid && !bready) |=> bvalid && $stable(bresp)
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "B channel unstable before BREADY");

  sva_r_stable: assert property (
    (rvalid && !rready) |=> rvalid && $stable({rdata, rresp, rlast})
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "R channel unstable before RREADY");

  sva_b_known: assert property (
    bvalid |-> !$isunknown(bresp)
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "BRESP contains X/Z when BVALID=1");

  sva_r_known: assert property (
    rvalid |-> (!$isunknown({rresp, rlast}) && ((rresp != 2'b00) || !$isunknown(rdata)))
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "R channel payload/control contains X/Z when RVALID=1");

  // Reset quiescence (AMBA AXI4 §A3.1.2: VALID outputs must be low during and exiting reset)
  sva_reset_valid_low: assert property (
    @(posedge clk) disable iff (1'b0)
    (!rst_n || $rose(rst_n)) |-> (!awvalid && !wvalid && !bvalid && !arvalid && !rvalid)
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "AXI VALID signal asserted during/exiting reset");

  // 7. AXI4 4KB Boundary Crossing Prohibition
  sva_axi_no_4kb_cross_aw: assert property (
    awvalid |-> (awaddr[31:12] == aw_end_addr[31:12])
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("AW burst crosses 4KB boundary: awaddr=0x%08h awlen=%0d end=0x%08h", awaddr, awlen, aw_end_addr));

  sva_axi_no_4kb_cross_ar: assert property (
    arvalid |-> (araddr[31:12] == ar_end_addr[31:12])
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("AR burst crosses 4KB boundary: araddr=0x%08h arlen=%0d end=0x%08h", araddr, arlen, ar_end_addr));

  // 8. AXI4 Request-Response Conservation & Beat-Count Lifecycle
  wire aw_hs = (awvalid === 1'b1) && (awready === 1'b1);
  wire w_hs  = (wvalid  === 1'b1) && (wready  === 1'b1);
  wire b_hs  = (bvalid  === 1'b1) && (bready  === 1'b1);
  wire ar_hs = (arvalid === 1'b1) && (arready === 1'b1);
  wire r_hs  = (rvalid  === 1'b1) && (rready  === 1'b1);

  int unsigned outstanding_w;
  int unsigned outstanding_r;
  int unsigned r_beat_cnt;
  logic [7:0]  active_arlen;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      outstanding_w <= 0;
      outstanding_r <= 0;
      r_beat_cnt    <= 0;
      active_arlen  <= 8'd0;
    end else begin
      case ({aw_hs, b_hs})
        2'b10:   outstanding_w <= outstanding_w + 1;
        2'b01:   if (outstanding_w != 0) outstanding_w <= outstanding_w - 1;
        2'b11:   outstanding_w <= (outstanding_w == 0) ? 1 : outstanding_w;
        default: outstanding_w <= outstanding_w;
      endcase
      case ({ar_hs, (r_hs && rlast === 1'b1)})
        2'b10:   outstanding_r <= outstanding_r + 1;
        2'b01:   if (outstanding_r != 0) outstanding_r <= outstanding_r - 1;
        2'b11:   outstanding_r <= (outstanding_r == 0) ? 1 : outstanding_r;
        default: outstanding_r <= outstanding_r;
      endcase
      if (ar_hs) begin
        active_arlen <= arlen;
        r_beat_cnt   <= 0;
      end else if (r_hs) begin
        if (rlast === 1'b1)
          r_beat_cnt <= 0;
        else
          r_beat_cnt <= r_beat_cnt + 1;
      end
    end
  end

  // Responses must correspond to accepted requests (permitting simultaneous same-cycle handshake)
  sva_b_has_aw: assert property (
    bvalid |-> (outstanding_w > 0 || aw_hs)
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "BVALID asserted without an outstanding AW request");

  sva_r_has_ar: assert property (
    rvalid |-> (outstanding_r > 0 || ar_hs)
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA", "RVALID asserted without an outstanding AR request");

  // Single-outstanding DMA burst restriction per VNCHIP Spec 5.6.4
  sva_single_outstanding_w: assert property (
    outstanding_w <= 1
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("DMA write outstanding count %0d exceeded single-outstanding limit", outstanding_w));

  sva_single_outstanding_r: assert property (
    outstanding_r <= 1
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("DMA read outstanding count %0d exceeded single-outstanding limit", outstanding_r));

  // RLAST must align with accepted ARLEN when an AR burst is active
  sva_rlast_matches_arlen: assert property (
    (r_hs && outstanding_r > 0 && !ar_hs) |-> (rlast === (r_beat_cnt == int'(active_arlen)))
  ) else uvm_pkg::uvm_report_error("DMA_AXI_SVA",
    $sformatf("RLAST=%0b mismatch at read beat %0d (expected ARLEN=%0d)", rlast, r_beat_cnt, active_arlen));

  // Functional cover properties for AXI4 DMA handshakes and backpressure
  c_dma_aw_stall: cover property (awvalid && !awready);
  c_dma_w_stall:  cover property (wvalid  && !wready);
  c_dma_ar_stall: cover property (arvalid && !arready);
  c_dma_r_stall:  cover property (rvalid  && !rready);
  c_dma_b_err:    cover property (b_hs && bresp != 2'b00);
  c_dma_r_err:    cover property (r_hs && rresp != 2'b00);

endmodule : dma_axi_sva

`endif // DMA_AXI_SVA_SV
