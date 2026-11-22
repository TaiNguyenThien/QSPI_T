`ifndef QSPI_CFG_SV
`define QSPI_CFG_SV

class qspi_cfg extends uvm_object;
  `uvm_object_utils(qspi_cfg)

  uvm_active_passive_enum is_active = UVM_ACTIVE;
  typedef enum {
    DEVICE_MODEL,
    OVERRIDE_BUFFER
  } qspi_response_source_e;

  qspi_response_source_e response_source = DEVICE_MODEL;
  bit [7:0]  override_pad = 8'hff;
  bit        cpol;
  bit        cpha;
  bit [1:0]  cmd_lanes;
  bit [1:0]  addr_lanes;
  bit [1:0]  data_lanes;
  bit [1:0]  addr_bytes;
  bit        mode_en;
  bit [3:0]  dummy_cycles;
  bit [7:0]  extra_dummy;
  bit        dir;
  bit [7:0]  read_bytes[$];
  int unsigned payload_len;
  bit [1:0]  cs_delay;
  int unsigned sector_erase_bytes = 4096;
  int unsigned block_erase_bytes  = 65536;

  function new(string name = "qspi_cfg");
    super.new(name);
  endfunction

  function void clear_override();
    response_source = DEVICE_MODEL;
    read_bytes.delete();
  endfunction

  function qspi_cfg snapshot(string name = "active_qspi_cfg");
    qspi_cfg copy_h = qspi_cfg::type_id::create(name);
    copy_h.is_active       = is_active;
    copy_h.response_source = response_source;
    copy_h.override_pad    = override_pad;
    copy_h.cpol            = cpol;
    copy_h.cpha            = cpha;
    copy_h.cmd_lanes       = cmd_lanes;
    copy_h.addr_lanes      = addr_lanes;
    copy_h.data_lanes      = data_lanes;
    copy_h.addr_bytes      = addr_bytes;
    copy_h.mode_en         = mode_en;
    copy_h.dummy_cycles    = dummy_cycles;
    copy_h.extra_dummy     = extra_dummy;
    copy_h.dir             = dir;
    copy_h.read_bytes      = read_bytes;
    copy_h.payload_len     = payload_len;
    copy_h.cs_delay           = cs_delay;
    copy_h.sector_erase_bytes = sector_erase_bytes;
    copy_h.block_erase_bytes  = block_erase_bytes;
    return copy_h;
  endfunction

  function string convert2string();
    return $sformatf(
      "mode=%0d/%0d lanes(cmd/addr/data)=%0d/%0d/%0d addr_bytes=%0d mode_en=%0b dummy=%0d+%0d dir=%0b",
      cpol, cpha, cmd_lanes, addr_lanes, data_lanes, addr_bytes, mode_en,
      dummy_cycles, extra_dummy, dir);
  endfunction
endclass : qspi_cfg

`endif
