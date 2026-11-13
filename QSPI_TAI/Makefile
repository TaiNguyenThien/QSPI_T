# ============================================================
# VNCHIP QSPI DV TRAINING
# Student Makefile Skeleton
# Simulator : Cadence Xcelium
# Made by Nguyen Bao Tinh
# ============================================================
.DEFAULT_GOAL := help
SHELL := /bin/bash

# ----------------------------------------
# 1. PROJECT DIRECTORIES
# ----------------------------------------

RTL_DIR         := rtl
TB_DIR          := tb
FILELIST_DIR    := filelist
LOG_DIR         := logs
MODE            ?= $(if $(filter +QSPI_DMA_CASE=%,$(PLUSARGS)),dma,pio)
COV_DIR         ?= cov_work_$(MODE)

RTL_FLIST       := $(FILELIST_DIR)/rtl.f
TB_FLIST        := $(FILELIST_DIR)/tb.f
COV_SCOPE_DIR   := $(abspath $(COV_DIR)/scope)
COV_REPORT_DIR  := $(abspath coverage_report_$(MODE))

# ----------------------------------------
# 2. SIMULATION CONFIGURATION
# ----------------------------------------

TOP             ?= tb_top
SNAPSHOT        ?= tb_qspi_top_snap
TEST            ?=
SEED            ?= 1
WAVE_EN         ?= 0
COV_EN          ?= 0
REPORT          ?= text
PLUSARGS        ?=

VCD_FILE        := $(TEST)_$(SEED).vcd
VCD_TCL         := .vcd.tcl

# ----------------------------------------
# 3. TOOL
# ----------------------------------------

SRUN            ?= srun
XMVLOG          ?= xmvlog
XMELAB          ?= xmelab
XMSIM           ?= xmsim
IMC             ?= imc
SIMVISION       ?= simvision

# ----------------------------------------
# 4. TOOL FLAGS
# ----------------------------------------

UVM_HOME        := $(MDV_XLM_HOME)/tools.lnx86/methodology/UVM/CDNS-1.2/sv/src
UVM_PKG         := $(UVM_HOME)/uvm_pkg.sv
UVM_DPI_DIR     := $(MDV_XLM_HOME)/tools.lnx86/methodology/UVM/CDNS-1.2/additions/sv/lib/64bit
UVM_DPI_LIB     := uvmdpi

SRUN_OPTS       := --partition=TRAINING
GUI_SRUN_OPTS   := $(SRUN_OPTS) --x11

XMVLOG_OPTS     := -64bit -sv -messages -incdir $(UVM_HOME)
XMELAB_OPTS     := -64bit -messages -access +rwc -snapshot $(SNAPSHOT)

XMSIM_OPTS      := -64bit \
                   +UVM_TESTNAME=$(TEST) \
                   +UVM_NO_RELNOTES \
                   -svseed $(SEED) \
                   -sv_lib $(UVM_DPI_DIR)/lib$(UVM_DPI_LIB)

COV_OPTS        := $(if $(filter 1,$(COV_EN)),-coverage all$(if $(wildcard scripts/coverage.ccf), -covfile scripts/coverage.ccf,),)
COV_TEST        ?= $(if $(filter +QSPI_PIO_CASE=%,$(PLUSARGS)),tc$(patsubst +QSPI_PIO_CASE=%,%,$(filter +QSPI_PIO_CASE=%,$(PLUSARGS))),$(if $(filter +QSPI_DMA_CASE=%,$(PLUSARGS)),tc$(patsubst +QSPI_DMA_CASE=%,%,$(filter +QSPI_DMA_CASE=%,$(PLUSARGS))),$(TEST)))
COV_RUN_OPTS    ?= -covtest $(COV_TEST) -covoverwrite -covworkdir $(COV_DIR)

# ----------------------------------------
# 5. COURSE TARGETS
# ----------------------------------------

.PHONY: dirs udf apb axi seq cfg flash ral cov env chk tst top \
        compile_tb compile build run _run_test vcd_setup wave \
        cov_merge cov_gui cov_report \
        clean clean_all help

dirs:
	@mkdir -p $(LOG_DIR) $(COV_DIR)

udf: dirs
	@echo "========================================"
	@echo " Compile/check $@"
	@echo "========================================"
	@set -o pipefail; \
		$(SRUN) $(SRUN_OPTS) \
		$(XMVLOG) $(XMVLOG_OPTS) \
		$(UVM_PKG) \
		-f $(FILELIST_DIR)/$@.f \
		2>&1 | tee $(LOG_DIR)/$@.log

apb axi seq cfg flash ral cov chk env tst top: dirs
	@echo "========================================"
	@echo " Compile/check $@"
	@echo "========================================"
	@set -o pipefail; \
		$(SRUN) $(SRUN_OPTS) \
		$(XMVLOG) $(XMVLOG_OPTS) \
		-f $(FILELIST_DIR)/$@.f \
		2>&1 | tee $(LOG_DIR)/$@.log

vcd_setup: dirs
	@echo "Creating VCD control file..."
	@echo 'database -open waves -vcd -into $(VCD_FILE)' > $(VCD_TCL)
	@echo 'probe -create -database waves -all -depth all' >> $(VCD_TCL)
	@echo 'run' >> $(VCD_TCL)
	@echo 'exit' >> $(VCD_TCL)

compile_tb: dirs
	@echo "========================================"
	@echo " Compile complete testbench"
	@echo "========================================"
	@set -o pipefail; \
	$(SRUN) $(SRUN_OPTS) \
		$(XMVLOG) $(XMVLOG_OPTS) \
		$(UVM_PKG) -f $(TB_FLIST) \
		2>&1 | tee $(LOG_DIR)/compile_tb.log

compile: dirs
	@echo "========================================"
	@echo " Compile RTL + Testbench"
	@echo "========================================"
	@set -o pipefail; \
	$(SRUN) $(SRUN_OPTS) \
		$(XMVLOG) $(XMVLOG_OPTS) \
		$(UVM_PKG) -f $(RTL_FLIST) -f $(TB_FLIST) \
		2>&1 | tee $(LOG_DIR)/compile.log

build: compile
	@echo "========================================"
	@echo " Elaborate $(TOP)"
	@echo " Snapshot : $(SNAPSHOT)"
	@echo " Coverage : $(COV_EN)"
	@echo "========================================"
	@set -o pipefail; \
	$(SRUN) $(SRUN_OPTS) \
		$(XMELAB) $(XMELAB_OPTS) \
		$(COV_OPTS) \
		$(TOP) \
		2>&1 | tee $(LOG_DIR)/elab.log

run: build
	@if [ -n "$(TEST)" ]; then \
		$(MAKE) --no-print-directory _run_test \
			TEST="$(TEST)" \
			SEED="$(SEED)" \
			WAVE_EN="$(WAVE_EN)" \
			COV_EN="$(COV_EN)" \
			PLUSARGS="$(PLUSARGS)"; \
	else \
		echo "ERROR: TEST is required"; \
		echo "Usage: make run TEST=qspi_pio_test PLUSARGS=\"+QSPI_PIO_CASE=smoke\""; \
		exit 1; \
	fi

_run_test:
	@echo "========================================"
	@echo " Run : $(TEST)"
	@echo " Seed: $(SEED)"
	@echo " Wave: $(WAVE_EN)"
	@echo "========================================"
	@if [ "$(WAVE_EN)" = "1" ]; then \
		$(MAKE) --no-print-directory vcd_setup; \
		INPUT_OPT="-input $(VCD_TCL)"; \
	else \
		INPUT_OPT=""; \
	fi; \
	set -o pipefail; \
	$(SRUN) $(SRUN_OPTS) \
		$(XMSIM) $(XMSIM_OPTS) $(COV_RUN_OPTS) $(PLUSARGS) \
		$(SNAPSHOT) $$INPUT_OPT \
		2>&1 | tee $(LOG_DIR)/$(COV_TEST)_$(SEED).log

wave:
	@if [ ! -f "$(VCD_FILE)" ]; then \
		echo "ERROR: $(VCD_FILE) not found"; \
		echo "Run with WAVE_EN=1 first"; \
		exit 1; \
	fi
	$(SRUN) $(GUI_SRUN_OPTS) $(SIMVISION) $(VCD_FILE)

cov_merge: dirs
	@echo "========================================"
	@echo " Merging Coverage Databases..."
	@echo "========================================"
	@SCOPES=$$(ls -d $(COV_SCOPE_DIR)/tc* 2>/dev/null | grep -v "merged_cov" | tr '\n' ' '); \
	if [ -z "$$SCOPES" ]; then \
		SCOPES=$$(ls -d $(COV_SCOPE_DIR)/* 2>/dev/null | grep -v "merged_cov" | tr '\n' ' '); \
	fi; \
	if [ -z "$$SCOPES" ]; then \
		echo "ERROR: No coverage databases found in $(COV_SCOPE_DIR)"; \
		echo "Run tests with COV_EN=1 first."; \
		exit 1; \
	fi; \
	echo "merge $$SCOPES -out $(COV_SCOPE_DIR)/merged_cov_$(MODE) -overwrite" > $(LOG_DIR)/merge.tcl; \
	echo "exit" >> $(LOG_DIR)/merge.tcl; \
	$(SRUN) $(SRUN_OPTS) $(IMC) -exec $(LOG_DIR)/merge.tcl && \
	echo "Successfully merged into: $(COV_SCOPE_DIR)/merged_cov_$(MODE)"

cov_gui:
	@if [ "$(TEST)" = "merged" ] || [ "$(TEST)" = "merged_cov" ] || [ -z "$(TEST)" ]; then \
		if [ ! -d "$(COV_SCOPE_DIR)/merged_cov_$(MODE)" ]; then \
			$(MAKE) --no-print-directory cov_merge MODE=$(MODE); \
		fi; \
		SCOPE="$(COV_SCOPE_DIR)/merged_cov_$(MODE)"; NAME="merged_cov_$(MODE)"; \
	else \
		SCOPE="$(COV_SCOPE_DIR)/$(TEST)"; NAME="$(TEST)"; \
	fi; \
	if [ ! -d "$$SCOPE" ]; then \
		echo "ERROR: Coverage scope not found: $$SCOPE"; \
		echo "Run with COV_EN=1 first."; \
		exit 1; \
	fi; \
	$(SRUN) $(GUI_SRUN_OPTS) $(IMC) -load "$$SCOPE"

cov_report:
	@if [ "$(TEST)" = "merged" ] || [ "$(TEST)" = "merged_cov" ] || [ -z "$(TEST)" ]; then \
		if [ ! -d "$(COV_SCOPE_DIR)/merged_cov_$(MODE)" ]; then \
			$(MAKE) --no-print-directory cov_merge MODE=$(MODE); \
		fi; \
		SCOPE="$(COV_SCOPE_DIR)/merged_cov_$(MODE)"; NAME="merged_cov_$(MODE)"; \
	else \
		SCOPE="$(COV_SCOPE_DIR)/$(TEST)"; NAME="$(TEST)"; \
	fi; \
	if [ ! -d "$$SCOPE" ]; then \
		echo "ERROR: Coverage scope not found: $$SCOPE"; \
		echo "Run with COV_EN=1 first."; \
		exit 1; \
	fi; \
	mkdir -p $(COV_REPORT_DIR); \
	if [ "$(REPORT)" = "html" ]; then \
		OUT="$(COV_REPORT_DIR)/$$NAME.html"; \
		echo "report -html -metrics all -out $$OUT -overwrite" > $(LOG_DIR)/report.tcl; \
		echo "exit" >> $(LOG_DIR)/report.tcl; \
		$(SRUN) $(SRUN_OPTS) $(IMC) -load "$$SCOPE" -exec $(LOG_DIR)/report.tcl; \
		echo "HTML report: $$OUT/index.html"; \
	else \
		OUT="$(COV_REPORT_DIR)/$$NAME.txt"; \
		echo "report -metrics all -out $$OUT -overwrite" > $(LOG_DIR)/report.tcl; \
		echo "exit" >> $(LOG_DIR)/report.tcl; \
		$(SRUN) $(SRUN_OPTS) $(IMC) -load "$$SCOPE" -exec $(LOG_DIR)/report.tcl; \
		echo "Text report: $$OUT"; \
	fi

cov_full_merge: dirs
	@echo "========================================"
	@echo " Merging Both PIO & DMA Databases..."
	@echo "========================================"
	@mkdir -p cov_work_full/scope
	echo "merge $(abspath cov_work_pio/scope/merged_cov_pio) $(abspath cov_work_dma/scope/merged_cov_dma) -out $(abspath cov_work_full/scope/merged_full_chip) -overwrite" > $(LOG_DIR)/merge_full.tcl; \
	echo "exit" >> $(LOG_DIR)/merge_full.tcl; \
	$(SRUN) $(SRUN_OPTS) $(IMC) -exec $(LOG_DIR)/merge_full.tcl && \
	echo "Successfully merged Full-Chip into: cov_work_full/scope/merged_full_chip"

clean_cov:
	@echo "Cleaning coverage databases..."
	@rm -rf $(COV_DIR) $(COV_REPORT_DIR)

clean:
	@echo "Cleaning simulation files..."
	@rm -rf \
		xcelium.d \
		INCA_libs \
		xm*.key \
		imc.* \
		*.history \
		*.vcd *.dsn *.trn \
		*.log \
		$(VCD_TCL) .simvision

clean_all: clean
	@echo "Cleaning build/log/coverage/report..."
	@rm -rf \
		$(LOG_DIR) \
		$(COV_DIR) \
		$(COV_REPORT_DIR)

help:
	@echo ""
	@echo "=========================================================="
	@echo " VNCHIP QSPI DV TRAINING - Makefile Help"
	@echo "=========================================================="
	@echo ""
	@echo "  COURSE COMPILE TARGETS"
	@echo "      make udf   - Compile UDF / interface files"
	@echo "      make apb   - Compile APB agent package"
	@echo "      make seq   - Compile sequence package"
	@echo "      make cfg   - Compile configuration package"
	@echo "      make flash - Compile QSPI Flash agent package"
	@echo "      make ral   - Compile register model / APB adapter package"
	@echo "      make chk   - Compile checker / scoreboard package"
	@echo "      make cov   - Compile functional coverage package"
	@echo "      make env   - Compile UVM environment package"
	@echo "      make tst   - Compile UVM test package"
	@echo "      make top   - Compile testbench top"
	@echo "      PIO order: udf -> apb -> flash -> cfg -> ral -> chk -> cov -> seq -> env -> tst -> top"
	@echo "      make udf compiles UVM once; later package targets reuse it automatically."
	@echo ""
	@echo "  SIMULATION FLOW"
	@echo "      make compile_tb                     - Compile all TB packages, interfaces and top"
	@echo "      make compile                        - Compile RTL + full testbench"
	@echo "      make build                          - Compile + elaborate tb_top"
	@echo "      make run TEST=<test> [OPTIONS]      - Run a single test"
	@echo "      scripts/run_pio_regression.sh       - Run the PIO 001..078 regression"
	@echo "      make wave TEST=<test> [SEED=<n>]    - Open waveform"
	@echo ""
	@echo "      OPTIONS: SEED=<n> | WAVE_EN=1 | COV_EN=1 | PLUSARGS=<args>"
	@echo "               SEED      - Set simulation random seed"
	@echo "               WAVE_EN=1 - Enable waveform dumping"
	@echo "               COV_EN=1  - Enable coverage collection"
	@echo "               PLUSARGS  - Extra +args passed to xmsim, e.g. PLUSARGS=\"+QSPI_PIO_CASE=apb\""
	@echo ""
	@echo "  COVERAGE"
	@echo "    - MERGE:"
	@echo "        make cov_merge                       - Merge all tc* coverage runs into merged_cov"
	@echo ""
	@echo "    - IMC:"
	@echo "        make cov_gui [TEST=<test|merged>]    - Open test or merged coverage"
	@echo ""
	@echo "    - REPORT:"
	@echo "        make cov_report [TEST=<test|merged>] - Generate test or merged coverage report"
	@echo "           Use REPORT=html for detailed HTML report."
	@echo ""
	@echo "  CLEAN"
	@echo "      make clean     - Remove simulation temporary files"
	@echo "      make clean_all - Remove all generated files and reports"
	@echo ""
	@echo "=========================================================="
