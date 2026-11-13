# Testbench only: RTL is already supplied by filelist/rtl.f.
# Keep agent locations in their component filelists so Linux can retain the
# teammate SPI path without hard-coding the local checkout layout here.
+incdir+.
-f filelist/udf.f
-f filelist/apb.f
-f filelist/flash.f
-f filelist/axi.f
-f filelist/cfg.f
-f filelist/ral.f
-f filelist/chk.f
-f filelist/cov.f
-f filelist/seq.f
-f filelist/env.f
-f filelist/tst.f
-f filelist/top.f
