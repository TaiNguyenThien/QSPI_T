import uvm_pkg::*;
import apb_agent_pkg::*;
import qspi_agent_pkg::*;
`include "uvm_macros.svh"

`uvm_analysis_imp_decl(_apb)
`uvm_analysis_imp_decl(_qspi)
`uvm_analysis_imp_decl(_flash)

class qspi_sb extends uvm_scoreboard;
  `uvm_component_utils(qspi_sb)
/* Analysis port received trans from monitor*/
  uvm_analysis_imp_apb#(apb_transaction, qspi_sb) item_collected_export_apb;
  uvm_analysis_imp_qspi#(qspi_transaction, qspi_sb) item_collected_export_qspi;
  uvm_analysis_imp_flash#(qspi_transaction, qspi_sb) item_collected_export_flash;

  apb_transaction apb_q[$];
  qspi_transaction qspi_q[$];
  qspi_transaction flash_q[$];

  function new(string name="qspi_sb", uvm_component parent);
    super.new(name,parent);
  endfunction: new

  virtual function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    `uvm_info("build_phase","Entered...",UVM_HIGH)
    item_collected_export_apb  = new ("item_collected_export_apb",this);
    item_collected_export_qspi = new ("item_collected_export_qspi",this);
    item_collected_export_flash = new ("item_collected_export_flash",this);
    `uvm_info("build_phase","Exited...",UVM_HIGH)
  endfunction: build_phase
  virtual task run_phase(uvm_phase phase);
  endtask: run_phase
  virtual function void write_apb(apb_transaction trans);
    `uvm_info(get_type_name(),$sformatf("[scoreboard] [write_apb] Get data from APB \n %s",trans.sprint()),UVM_LOW);

  endfunction: write_apb
  virtual function void write_qspi(qspi_transaction trans);

    `uvm_info(get_type_name(),$sformatf("[scoreboard] [write_apb] Get data from QSPI_MONITOR \n %s",trans.sprint()),UVM_LOW);

  endfunction: write_qspi

  virtual function void write_flash(qspi_transaction trans);

    `uvm_info(get_type_name(),$sformatf("[scoreboard] [write_apb] Get data from QSPI_FLASH \n %s",trans.sprint()),UVM_LOW);

  endfunction: write_flash
endclass