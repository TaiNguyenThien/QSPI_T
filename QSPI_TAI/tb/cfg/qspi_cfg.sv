//TAI
//
//=====================
  class qspi_cfg extends uvm_object;
    `uvm_object_utils(qspi_cfg)
    string my_name;
    rand bit quad_en;
    rand bit cpol;
    rand bit cpha;
    rand bit [1:0] cmd_lanes;
    rand bit [1:0] addr_lanes;
    rand bit [1:0] data_lanes;
    rand bit [1:0] addr_bytes;
    rand bit [31:0] length;
    rand bit mode_en;
    rand bit [7:0] mode_bits;
    rand bit [3:0] dummy_cycles;
    rand bit [7:0] extra_dummy;
    rand bit dir;
    function new(string name="");
      super.new(name);
      my_name =name;
    endfunction
  endclass