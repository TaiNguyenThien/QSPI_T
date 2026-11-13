`timescale 1ns/1ps

module tb_top;
  import uvm_pkg::*;
  import apb_agent_pkg::*;
  import qspi_agent_pkg::*;
  import qspi_test_pkg::*;

  clk_rst_irq_if clk_vif();

  qspi_if qspi_vif();
  apb_if  apb_vif();
  axi_if  axi_vif();

  top_module dut (
    .clk(clk_vif.clk), .rst_n(clk_vif.rst_n),
    .psel(apb_vif.psel), .penable(apb_vif.penable), .pwrite(apb_vif.pwrite),
    .paddr(apb_vif.paddr), .pwdata(apb_vif.pwdata), .pstrb(apb_vif.pstrb),
    .pprot(apb_vif.pprot), .prdata(apb_vif.prdata), .pready(apb_vif.pready),
    .pslverr(apb_vif.pslverr),
   /* .s_araddr(xip.araddr), .s_arprot(xip.arprot),
    .s_arvalid(xip.arvalid), .s_arready(xip.arready),
    .s_rdata(xip.rdata), .s_rresp(xip.rresp),
    .s_rvalid(xip.rvalid), .s_rready(xip.rready),
    */
    .qspi_sclk(qspi_vif.qspi_sclk), .qspi_cs_n(qspi_vif.qspi_cs_n),
    .qspi_io0(qspi_vif.qspi_io0), .qspi_io1(qspi_vif.qspi_io1),
    .qspi_io2(qspi_vif.qspi_io2), .qspi_io3(qspi_vif.qspi_io3),
    .m_awaddr(dma.awaddr), .m_awlen(dma.awlen),
    .m_awsize(dma.awsize), .m_awburst(dma.awburst),
    .m_awvalid(dma.awvalid), .m_awready(dma.awready),
    .m_wdata(dma.wdata), .m_wstrb(dma.wstrb), .m_wlast(dma.wlast),
    .m_wvalid(dma.wvalid), .m_wready(dma.wready),
    .m_bresp(dma.bresp), .m_bvalid(dma.bvalid), .m_bready(dma.bready),
    .m_araddr(dma.araddr), .m_arlen(dma.arlen),
    .m_arsize(dma.arsize), .m_arburst(dma.arburst),
    .m_arvalid(dma.arvalid), .m_arready(dma.arready),
    .m_rdata(dma.rdata), .m_rresp(dma.rresp), .m_rlast(dma.rlast),
    .m_rvalid(dma.rvalid), .m_rready(dma.rready), .irq(clk_vif.irq)
  );

  initial begin
    clk_vif.clk = 1'b0;
    forever #5 clk_vif.clk = ~clk_vif.clk;
  end

  initial begin
    clk_vif.rst_n = 1'b0;
    repeat (10) @(negedge clk_vif.clk);
    clk_vif.rst_n = 1'b1;
  end


  initial begin

    uvm_config_db#(virtual clk_rst_irq_if)::set(null,"uvm_test_top","clk_vif",clk_vif);
    uvm_config_db#(virtual apb_if)::set(null,"uvm_test_top","apb_vif",apb_vif);
    uvm_config_db#(virtual qspi_if)::set(null,"uvm_test_top.env","qspi_vif",qspi_vif);
    uvm_config_db#(virtual axi_if)::set(null,"uvm_test_top","axi_vif",axi_vif);
    run_test();

  end

endmodule : tb_top
