// A project-level command description, not an agent configuration or monitor item.
class qspi_pio_cmd extends uvm_object;
  `uvm_object_utils(qspi_pio_cmd)
  rand bit [7:0] opcode = 8'h03;
  rand bit [31:0] address;
  rand int unsigned addr_bytes = 3;
  rand int unsigned cmd_lanes = 1, addr_lanes = 1, data_lanes = 1;
  rand bit read_direction = 1;
  rand bit mode_enable;
  rand bit [7:0] mode_value;
  rand int unsigned dummy_cycles=0, extra_dummy=0;
  rand bit cpol, cpha;
  rand bit [2:0] clk_div = 3;
  rand bit [1:0] cs_delay;
  bit cs_auto = 1;
  bit cs_level = 0;
  bit [4:0] interrupt_enable = 5'b00101;
  rand int unsigned length = 4;
  int unsigned preloaded_tx_words = 0;
  rand byte unsigned tx_bytes[$], flash_bytes[$];
  rand bit use_lut;
  rand bit [1:0] lut_index;
  bit expect_error;
  bit [2:0] required_err_bits, any_err_bits;
  bit program_lut=1;
  bit rx_drain_after_done;
  bit allow_no_serial;
  bit service_tx = 1, service_rx = 1;
  bit reset_abort_allowed;
  bit use_device_model;

  constraint legal_fields {
    cmd_lanes inside {1,2,4}; addr_lanes inside {1,2,4}; data_lanes inside {1,2,4};
    addr_bytes inside {0,3,4}; dummy_cycles inside {[0:15]}; extra_dummy inside {[0:255]};
    tx_bytes.size() <= length;
    if (!expect_error) {
      if (read_direction) { flash_bytes.size() == length; tx_bytes.size() == 0; }
      else { tx_bytes.size() == length; flash_bytes.size() == 0; }
    }
    preloaded_tx_words <= 4;
    if (read_direction) preloaded_tx_words == 0;
    preloaded_tx_words <= (tx_bytes.size()+3)/4;
  }
  constraint random_policy {
    soft length inside {0,1,2,3,4,5,12,15,16,17,31,40,64};
    soft addr_bytes inside {3,4};
    if (read_direction) opcode == (data_lanes==4 ? 8'h6b : data_lanes==2 ? 8'h3b : 8'h0b);
    else { opcode == (data_lanes==4 ? 8'h32 : 8'h02); dummy_cycles==0; extra_dummy==0; }
    if (length==0) { mode_enable==0; dummy_cycles==0; extra_dummy==0; }
    soft extra_dummy inside {[0:15]};
  }

  function new(string name = "qspi_pio_cmd");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    qspi_pio_cmd other;
    if (!$cast(other,rhs)) begin `uvm_fatal("QSPI_PIO_CMD_COPY", "Incompatible command object") return; end
    super.do_copy(rhs);
    opcode=other.opcode; address=other.address; addr_bytes=other.addr_bytes;
    cmd_lanes=other.cmd_lanes; addr_lanes=other.addr_lanes; data_lanes=other.data_lanes;
    read_direction=other.read_direction; mode_enable=other.mode_enable; mode_value=other.mode_value;
    dummy_cycles=other.dummy_cycles; extra_dummy=other.extra_dummy;
    cpol=other.cpol; cpha=other.cpha; clk_div=other.clk_div; cs_delay=other.cs_delay;
    cs_auto=other.cs_auto; cs_level=other.cs_level;
    interrupt_enable=other.interrupt_enable; length=other.length;
    preloaded_tx_words=other.preloaded_tx_words;
    tx_bytes=other.tx_bytes; flash_bytes=other.flash_bytes;
    use_lut=other.use_lut; lut_index=other.lut_index; expect_error=other.expect_error;
    required_err_bits=other.required_err_bits; any_err_bits=other.any_err_bits;
    program_lut=other.program_lut; rx_drain_after_done=other.rx_drain_after_done;
    allow_no_serial=other.allow_no_serial;
    service_tx=other.service_tx; service_rx=other.service_rx;
    reset_abort_allowed=other.reset_abort_allowed;
    use_device_model=other.use_device_model;
  endfunction

  virtual function bit do_compare(uvm_object rhs,uvm_comparer comparer);
    qspi_pio_cmd other;
    if (!$cast(other,rhs)) return 0;
    return super.do_compare(rhs,comparer) && opcode==other.opcode && address==other.address &&
      addr_bytes==other.addr_bytes && cmd_lanes==other.cmd_lanes &&
      addr_lanes==other.addr_lanes && data_lanes==other.data_lanes &&
      read_direction==other.read_direction && mode_enable==other.mode_enable && mode_value==other.mode_value &&
      dummy_cycles==other.dummy_cycles && extra_dummy==other.extra_dummy &&
      cpol==other.cpol && cpha==other.cpha && clk_div==other.clk_div && cs_delay==other.cs_delay &&
      cs_auto==other.cs_auto && cs_level==other.cs_level &&
      interrupt_enable==other.interrupt_enable && length==other.length &&
      preloaded_tx_words==other.preloaded_tx_words &&
      tx_bytes==other.tx_bytes && flash_bytes==other.flash_bytes &&
      use_lut==other.use_lut && lut_index==other.lut_index && expect_error==other.expect_error &&
      required_err_bits==other.required_err_bits && any_err_bits==other.any_err_bits &&
      program_lut==other.program_lut && rx_drain_after_done==other.rx_drain_after_done &&
      allow_no_serial==other.allow_no_serial &&
      service_tx==other.service_tx && service_rx==other.service_rx &&
      reset_abort_allowed==other.reset_abort_allowed &&
      use_device_model==other.use_device_model;
  endfunction

  virtual function string convert2string();
    return $sformatf("op=%02h addr=%08h/%0d lanes=%0d/%0d/%0d dir=%0b bytes=%0d preloaded_tx=%0d mode=%0d div=%0d LUT=%0b/%0d expected-error=%0b TX=%p FLASH=%p",
      opcode,address,addr_bytes,cmd_lanes,addr_lanes,data_lanes,read_direction,
      length,preloaded_tx_words,{cpol,cpha},clk_div,use_lut,lut_index,expect_error,tx_bytes,flash_bytes);
  endfunction

  function void validate();
    if (!(cmd_lanes inside {1,2,4}) || !(addr_lanes inside {1,2,4}) ||
        !(data_lanes inside {1,2,4}) || !(addr_bytes inside {0,3,4}) ||
        dummy_cycles > 15 || extra_dummy > 255)
      `uvm_fatal("QSPI_PIO_STIMULUS", "Reserved lane/address or out-of-range dummy setting")
    if (!expect_error && ((!read_direction && tx_bytes.size() != length) ||
                         (read_direction && flash_bytes.size() < length)))
      `uvm_fatal("QSPI_PIO_STIMULUS", "A success command needs all source payload bytes")
    if (!expect_error && (!service_tx || !service_rx))
      `uvm_fatal("QSPI_PIO_STIMULUS", "Disabled FIFO service requires explicit expected-error intent")
    if (tx_bytes.size() > length)
      `uvm_fatal("QSPI_PIO_STIMULUS", "TX preload exceeds CMD_LEN")
    if (preloaded_tx_words > 4 || (read_direction && preloaded_tx_words != 0) ||
        (preloaded_tx_words > (tx_bytes.size() + 3) / 4))
      `uvm_fatal("QSPI_PIO_STIMULUS", "Invalid preloaded_tx_words configuration")
  endfunction

  function bit [1:0] encode_lanes(int unsigned lanes);
    case (lanes)
      1: return 0;
      2: return 1;
      4: return 2;
      default: begin `uvm_fatal("QSPI_PIO_STIMULUS", "Invalid lane count") return 0; end
    endcase
  endfunction

  function bit [31:0] format_word();
    bit [31:0] val;
    val = 0;
    val[1:0] = encode_lanes(cmd_lanes);
    val[3:2] = encode_lanes(addr_lanes);
    val[5:4] = encode_lanes(data_lanes);
    case (addr_bytes)
      0: val[7:6] = 0;
      3: val[7:6] = 1;
      4: val[7:6] = 2;
    endcase
    val[8] = mode_enable;
    val[12:9] = dummy_cycles[3:0];
    val[13] = read_direction;
    return val;
  endfunction

  function bit [31:0] control_word();
    bit [31:0] val;
    val = 1; // ENABLE; XIP_EN and DMA_EN stay zero for PIO.
    val[2] = cmd_lanes == 4 || addr_lanes == 4 || data_lanes == 4;
    val[3] = cpol;
    val[4] = cpha;
    return val;
  endfunction
endclass
