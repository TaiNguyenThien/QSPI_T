class qspi_cfg extends uvm_object;
  `uvm_object_utils(qspi_cfg)

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit quad_en;
  bit cpol;
  bit cpha;
  bit [1:0] cmd_lanes;
  bit [1:0] addr_lanes;
  bit [1:0] data_lanes;
  bit [1:0] addr_bytes;
  bit [31:0] length;
  bit mode_en;
  bit [7:0] mode_bits;
  bit [3:0] dummy_cycles;
  bit [7:0] extra_dummy;
  bit dir;
  bit [7:0] read_bytes[$];

  function new(string name = "qspi_cfg");
    super.new(name);
  endfunction

  function string convert2string();
    return $sformatf("mode=%0d/%0d lanes(cmd/addr/data)=%0d/%0d/%0d addr_bytes=%0d dummy=%0d+%0d dir=%0b len=%0d",
      cpol, cpha, cmd_lanes, addr_lanes, data_lanes, addr_bytes, dummy_cycles, extra_dummy, dir, length);
  endfunction
endclass
