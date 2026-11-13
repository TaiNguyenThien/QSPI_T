#!/bin/bash
# ==============================================================================
# Project   : VNCHIP QSPI Controller Functional Verification
# Script    : scripts/run_dma_regression.sh
# Role      : Enterprise DMA Mode Regression Runner (dma_01 -> dma_30)
# Simulator : Cadence Xcelium (via Slurm srun / Makefile)
# Standards : UVM-1.2 Sign-off Criteria (0 UVM_ERROR, 0 UVM_FATAL, 0 SVA Error)
#
# Usage     :
#   1. Positional (compatible with run_pio_regression.sh):
#        ./scripts/run_dma_regression.sh [SEED] [COV_EN]
#        Example: ./scripts/run_dma_regression.sh 1 1
#
#   2. Enterprise Flags:
#        ./scripts/run_dma_regression.sh [--seed N] [--cov] [--no-build]
#                                        [--only dma_01,dma_02] [--help]
# ==============================================================================
set -u

# ------------------------------------------------------------------------------
# 1. Default Configuration & Argument Parsing
# ------------------------------------------------------------------------------
SEED="1"
COV_EN="0"
DO_BUILD="1"
ONLY_CASES=""

usage() {
    cat <<EOF
================================================================================
 VNCHIP QSPI DMA Regression Runner - Usage
================================================================================
  Positional syntax (same as run_pio_regression.sh):
    ./scripts/run_dma_regression.sh [SEED] [COV_EN]

  Flag syntax:
    ./scripts/run_dma_regression.sh [OPTIONS]

  Options:
    -s, --seed <N>         Simulation random seed (default: 1)
    -c, --cov              Enable coverage collection, merge & HTML/text report
        --no-build         Skip initial 'make build' step (reuse existing snapshot)
        --only <list>      Comma-separated subset (e.g., dma_01,dma_03,dma_04)
    -h, --help             Show this help message
================================================================================
EOF
    exit 0
}

if [ $# -ge 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    SEED="$1"
    shift
    if [ $# -ge 1 ] && [[ "$1" =~ ^[01]$ ]]; then
        COV_EN="$1"
        shift
    fi
fi

while [ $# -gt 0 ]; do
    case "$1" in
        -s|--seed)
            SEED="$2"
            shift 2
            ;;
        -c|--cov)
            COV_EN="1"
            shift
            ;;
        --no-build)
            DO_BUILD="0"
            shift
            ;;
        --only)
            ONLY_CASES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo "[ERROR] Unknown argument: $1"
            usage
            ;;
    esac
done

# ------------------------------------------------------------------------------
# 2. Test Suite Manifest (30 Single-Responsibility DMA Testcases)
# ------------------------------------------------------------------------------
DMA_CASES=(
    "dma_01|TC_DMA_REG_01|CSR Reset & RW/RO Access            |Protocol/CSR"
    "dma_02|TC_DMA_RX_01 |Aligned RX vs FIFO Depth (E2E LE)   |E2E Payload "
    "dma_03|TC_DMA_RX_02 |RX Fixed Address Mode (INCR_ADDR=0) |AXI/Guard   "
    "dma_04|TC_DMA_RX_03 |Unaligned RX & WSTRB Guard Masking  |AXI/WSTRB   "
    "dma_05|TC_DMA_TX_01 |Aligned TX vs FIFO Depth (E2E LE)   |E2E Payload "
    "dma_06|TC_DMA_TX_02 |TX Fixed Address Mode (INCR_ADDR=0) |AXI/ARADDR  "
    "dma_07|TC_DMA_TX_03 |Unaligned TX Payload (E2E LE)       |E2E Payload "
    "dma_08|TC_DMA_CFG_01|Direct CSR vs Command LUT (B0..B3)  |CFG/LUT     "
    "dma_09|TC_DMA_CFG_02|Multi-Lane Opcodes (1-1-1..1-4-4)   |CFG/Lanes   "
    "dma_10|TC_DMA_CFG_03|Timing Sweep (Mode/Div/CS_DELAY)    |CFG/Timing  "
    "dma_11|TC_DMA_AXI_01|AXI INCR, 4B Size, LAST, Half-Duplex|AXI Protocol"
    "dma_12|TC_DMA_AXI_02|1024B Burst & Single Outstanding    |AXI Protocol"
    "dma_13|TC_DMA_AXI_03|5-Channel AXI Handshake Backpressure|AXI Stall   "
    "dma_14|TC_DMA_AXI_04|4KB Boundary Crossing Split         |AXI 4KB     "
    "dma_15|TC_DMA_AXI_05|Back-to-Back RX/TX DMA Turnaround   |AXI Stream  "
    "dma_16|TC_DMA_INT_01|CMD_DONE & DMA_DONE Sync + IRQ      |Interrupt   "
    "dma_17|TC_DMA_INT_02|INT_EN Masking & Dynamic Unmask     |Interrupt   "
    "dma_18|TC_DMA_INT_03|INT_STAT W1C & Bit Preservation     |Interrupt   "
    "dma_19|TC_DMA_INT_04|INT_STAT.ERR Latching & W1C Clear   |Interrupt   "
    "dma_20|TC_DMA_ERR_01|AXI SLVERR (2'b10) Abort & Recovery |Error/Abort "
    "dma_21|TC_DMA_ERR_02|AXI DECERR (2'b11) Abort & Recovery |Error/Abort "
    "dma_22|TC_DMA_ERR_03|FIFO Underrun Detection & Recovery  |Error/FIFO  "
    "dma_23|TC_DMA_ERR_04|Extended AXI Stall & Recovery       |Error/Stall "
    "dma_24|TC_DMA_ERR_05|Mid-Transfer Hard Reset & Recovery  |Reset/Recov "
    "dma_25|TC_DMA_ERR_06|Length Mismatch (Out-of-Scope) Recov|Out-of-Scope"
    "dma_26|TC_DMA_ERR_07|Zero Length (Out-of-Scope) Recovery |Out-of-Scope"
    "dma_27|TC_DMA_RND_01|Random/Boundary RX+TX Stress (E2E)  |E2E Stress  "
    "dma_28|TC_DMA_XIP_01|XIP Mode Blockage & DMA Coexistence |Coexistence "
    "dma_29|TC_DMA_SEC_01|Unmapped High Address DECERR & Recov|Security/Bus"
    "dma_30|TC_DMA_PERF_01|256B Quad Read Throughput Benchmark |Performance "
)

mkdir -p logs

SUMMARY_CSV="logs/dma_regression_summary.csv"
FAILED_LIST="logs/dma_failed_tests.txt"
rm -f "$SUMMARY_CSV" "$FAILED_LIST"
echo "Case_ID,VPlan_ID,Category,Seed,Status,UVM_Errors,UVM_Fatals,Duration_Sec,Log_File,Reason" > "$SUMMARY_CSV"

echo "================================================================================"
echo "               VNCHIP QSPI ENTERPRISE DMA REGRESSION RUNNER                     "
echo "================================================================================"
echo " Timestamp    : $(date '+%Y-%m-%d %H:%M:%S')"
echo " Seed         : $SEED"
echo " Coverage     : $([ "$COV_EN" = "1" ] && echo "ENABLED (COV_EN=1)" || echo "DISABLED (COV_EN=0)")"
echo " Build Step   : $([ "$DO_BUILD" = "1" ] && echo "ENABLED" || echo "SKIPPED (--no-build)")"
echo " Summary CSV  : $SUMMARY_CSV"
echo "================================================================================"
echo

# ------------------------------------------------------------------------------
# 3. Build Snapshot (Compile RTL + TB + Elaborate)
# ------------------------------------------------------------------------------
if [ "$COV_EN" = "1" ] && [ "$DO_BUILD" = "1" ]; then
    echo ">> [BUILD] Cleaning old DMA coverage scopes (cov_work/scope/tcdma_*)..."
    rm -rf cov_work_dma/scope/* coverage_report_dma/*
fi

if [ "$DO_BUILD" = "1" ]; then
    build_log="logs/build_dma.log"
    echo ">> [BUILD] Compiling & Elaborating snapshot (COV_EN=$COV_EN) -> $build_log ..."
    make build COV_EN="$COV_EN" > "$build_log" 2>&1
    if [ $? -ne 0 ]; then
        echo "[FATAL] Snapshot build failed! Inspect $build_log for details."
        tail -n 20 "$build_log"
        exit 2
    fi
    echo ">> [BUILD] Snapshot elaborated successfully."
    echo
fi

# ------------------------------------------------------------------------------
# 4. Execute DMA Regression Suite
# ------------------------------------------------------------------------------
pass_count=0
fail_count=0
total_count=0
suite_start_sec=$(date +%s)

declare -a TABLE_ROWS=()

should_run_case() {
    local c="$1"
    local v="$2"
    if [ -z "$ONLY_CASES" ]; then
        return 0
    fi
    IFS=',' read -ra FILTER_ARR <<< "$ONLY_CASES"
    for item in "${FILTER_ARR[@]}"; do
        if [ "$item" = "$c" ] || [ "$item" = "$v" ]; then
            return 0
        fi
    done
    return 1
}

for entry in "${DMA_CASES[@]}"; do
    IFS='|' read -r case_id vplan_id desc category <<< "$entry"
    vplan_id_trim=$(echo "$vplan_id" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    cat_trim=$(echo "$category" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    desc_trim=$(echo "$desc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')

    if ! should_run_case "$case_id" "$vplan_id_trim"; then
        continue
    fi

    total_count=$((total_count + 1))
    cov_test="tc${case_id}"
    raw_log="logs/qspi_dma_test_${SEED}.log"
    log_file="logs/${cov_test}_${SEED}.log"

    printf "[%02d/30] %-7s (%-13s) | %-36s ... " \
        "$total_count" "$case_id" "$vplan_id_trim" "$desc_trim"

    t_start=$(date +%s)

    make --no-print-directory _run_test \
        TEST="qspi_dma_test" \
        PLUSARGS="+QSPI_DMA_CASE=$case_id" \
        SEED="$SEED" \
        WAVE_EN=0 \
        COV_EN="$COV_EN" \
        COV_TEST="$cov_test" \
        MODE="dma" \
        COV_DIR="cov_work_dma" \
        COV_RUN_OPTS="-covtest $cov_test -covoverwrite -covworkdir cov_work_dma" \
        >/dev/null 2>&1

    if [ ! -f "$log_file" ] && [ -f "$raw_log" ]; then
        cp -f "$raw_log" "$log_file"
    fi

    t_end=$(date +%s)
    dur=$((t_end - t_start))

    # Extract UVM_ERROR / UVM_FATAL counts & SVA errors
    uvm_err="-"
    uvm_fat="-"
    status="FAIL"
    reason="Missing UVM Report Summary"

    if [ -f "$log_file" ]; then
        if grep -q "Report counts by severity" "$log_file"; then
            uvm_err=$(grep -E 'UVM_ERROR[[:space:]]*:' "$log_file" | tail -n 1 | awk -F':' '{print $2}' | xargs)
            uvm_fat=$(grep -E 'UVM_FATAL[[:space:]]*:' "$log_file" | tail -n 1 | awk -F':' '{print $2}' | xargs)
            uvm_err="${uvm_err:-999}"
            uvm_fat="${uvm_fat:-999}"

            if grep -Eq '\*E,ASRT|Offending '\''|Assertion error|SVA_ERR' "$log_file"; then
                status="FAIL"
                sva_line=$(grep -E '\*E,ASRT|Offending '\''|Assertion error|SVA_ERR' "$log_file" | head -n 1 | sed 's/,/;/g')
                reason="SVA Violation: ${sva_line:0:60}"
            elif [ "$uvm_err" = "0" ] && [ "$uvm_fat" = "0" ]; then
                status="PASS"
                reason="0 UVM_ERROR, 0 UVM_FATAL"
            else
                status="FAIL"
                first_err=$(grep -E '^UVM_ERROR|^UVM_FATAL' "$log_file" | head -n 1 | sed 's/,/;/g')
                if [ -n "$first_err" ]; then
                    reason=$(echo "$first_err" | sed -E 's/^UVM_(ERROR|FATAL) [^[]*\[/[/' | cut -c1-65)
                else
                    reason="UVM_ERROR=$uvm_err, UVM_FATAL=$uvm_fat"
                fi
            fi
        else
            eda_err=$(grep -E 'xmsim: \*F,|xmsim: \*E,|xmelab: \*E,|xmvlog: \*E,|srun: error:' "$log_file" | head -n 1 | sed 's/,/;/g')
            if [ -n "$eda_err" ]; then
                reason="EDA Error: ${eda_err:0:60}"
            fi
        fi
    else
        reason="Log file $log_file not generated"
    fi

    if [ "$status" = "PASS" ]; then
        pass_count=$((pass_count + 1))
        printf "PASS (%2ds)\n" "$dur"
    else
        fail_count=$((fail_count + 1))
        printf "FAIL (%2ds) -> %s\n" "$dur" "$log_file"
        echo "$case_id ($vplan_id_trim): $reason [log: $log_file]" >> "$FAILED_LIST"
    fi

    row_str=$(printf "| %-2d | %-7s | %-13s | %-12s | %-6s | %4s | %3ss | %-46s |" \
        "$total_count" "$case_id" "$vplan_id_trim" "$cat_trim" "$status" "$uvm_err" "$dur" "${reason:0:46}")
    TABLE_ROWS+=("$row_str")

    echo "\"$case_id\",\"$vplan_id_trim\",\"$cat_trim\",$SEED,\"$status\",\"$uvm_err\",\"$uvm_fat\",$dur,\"$log_file\",\"$reason\"" >> "$SUMMARY_CSV"
done

suite_end_sec=$(date +%s)
suite_dur=$((suite_end_sec - suite_start_sec))

# ------------------------------------------------------------------------------
# 5. Print Enterprise Summary Report Table
# ------------------------------------------------------------------------------
echo
echo "======================================================================================================================="
echo "                                    VNCHIP QSPI DMA REGRESSION SUMMARY REPORT                                          "
echo "======================================================================================================================="
echo "| #  | Case ID | VPlan ID      | Category     | Status | Errs | Time | Diagnostic / First Error Summary               |"
echo "|----|---------|---------------|--------------|--------|------|------|------------------------------------------------|"
for r in "${TABLE_ROWS[@]}"; do
    echo "$r"
done
echo "======================================================================================================================="
printf " FINAL RESULT : %d / %d PASS  |  %d FAIL  |  Total Elapsed: %ds  |  Seed: %s\n" \
    "$pass_count" "$total_count" "$fail_count" "$suite_dur" "$SEED"
echo " CSV Report   : $SUMMARY_CSV"
if [ -f "$FAILED_LIST" ]; then
    echo " Failed List  : $FAILED_LIST"
fi
echo "======================================================================================================================="

# ------------------------------------------------------------------------------
# 6. Optional Coverage Merge & Report Generation
# ------------------------------------------------------------------------------
if [ "$COV_EN" = "1" ]; then
    echo
    echo ">> [COVERAGE] Merging all DMA coverage databases into cov_work_dma/scope/merged_cov_dma..."
    make cov_merge MODE=dma
    echo ">> [COVERAGE] Generating HTML & Text DMA coverage reports..."
    make cov_report MODE=dma REPORT=html
    make cov_report MODE=dma REPORT=text
fi

if [ "$fail_count" -eq 0 ]; then
    exit 0
else
    exit 1
fi
