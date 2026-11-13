#!/bin/bash
# ============================================================
# VNCHIP QSPI PIO Regression Runner
# Tự động chạy toàn bộ Test 001 -> 078 và tổng kết kết quả
# ============================================================
set -u

SEED="${1:-1}"
COV_EN="${2:-0}"

# Danh sách từ 001 đến 078
TESTS=($(seq -f "%03g" 1 78))

mkdir -p logs

echo "=================================================="
echo "      VNCHIP QSPI PIO REGRESSION (001 -> 078)     "
echo "=================================================="
echo " Seed         : $SEED"
echo " Coverage     : $COV_EN"
echo " Total tests  : 76 (đã bỏ qua 021, 041 ngoài spec)"
echo "=================================================="
echo

# Nếu bật Coverage, dọn dẹp database cũ và build snapshot với COV_EN=1 trước
if [ "$COV_EN" = "1" ]; then
    echo ">> Cleaning old PIO coverage databases to prevent model mismatch..."
    rm -rf cov_work_pio/scope/* coverage_report_pio/*
    echo ">> Elaborating snapshot with Coverage enabled (COV_EN=1)..."
    make build COV_EN=1 MODE=pio > logs/build_cov.log 2>&1
    if [ $? -ne 0 ]; then
        echo "ERROR: make build COV_EN=1 failed. See logs/build_cov.log"
        exit 1
    fi
    echo ">> Build completed successfully with Coverage instrumentation."
    echo
fi

pass=0
fail=0
total=0
results=""

for tc in "${TESTS[@]}"; do
    # Bỏ qua 2 test không thuộc manifest
    if [ "$tc" = "021" ] || [ "$tc" = "041" ]; then
        continue
    fi

    total=$((total + 1))
    printf "[%02d/76] Running Test %s ... " "$total" "$tc"

    # 1. Chạy testcase
    make --no-print-directory _run_test \
        TEST="qspi_pio_test" \
        PLUSARGS="+QSPI_PIO_CASE=$tc" \
        SEED="$SEED" \
        WAVE_EN=0 \
        COV_EN="$COV_EN" \
        MODE="pio" \
        COV_DIR="cov_work_pio" \
        COV_RUN_OPTS="-covtest tc$tc -covoverwrite -covworkdir cov_work_pio" \
        >/dev/null 2>&1

    raw_log="logs/qspi_pio_test_${SEED}.log"
    saved_log="logs/tc${tc}_${SEED}.log"

    # Lưu riêng log của từng testcase để tiện debug
    if [ -f "$raw_log" ]; then
        cp -f "$raw_log" "$saved_log"
    fi

    # 2. Đánh giá kết quả theo chuẩn UVM Report Summary
    if [ -f "$saved_log" ] && \
       grep -q "Report counts by severity" "$saved_log" && \
       grep -Eq 'UVM_ERROR[[:space:]]*:[[:space:]]*0' "$saved_log" && \
       grep -Eq 'UVM_FATAL[[:space:]]*:[[:space:]]*0' "$saved_log"; then
        pass=$((pass + 1))
        echo "PASS"
        results="${results}\n  Test $tc : PASS"
    else
        fail=$((fail + 1))
        echo "FAIL (xem $saved_log)"
        results="${results}\n  Test $tc : FAIL"
    fi
done

echo
echo "=================================================="
echo "             QSPI REGRESSION SUMMARY              "
echo "=================================================="
printf "%b\n" "$results"
echo "--------------------------------------------------"
echo " KẾT QUẢ CUỐI CÙNG : $pass/$total PASS ($fail FAIL)"
echo "=================================================="

# Nếu bật Coverage, tự động merge toàn bộ database sau khi chạy xong
if [ "$COV_EN" = "1" ]; then
    echo
    echo ">> Merging all PIO coverage databases into cov_work_pio/scope/merged_cov_pio..."
    make cov_merge MODE=pio
    echo ">> Generating HTML PIO coverage report..."
    make cov_report MODE=pio REPORT=html
fi

# Thoát với mã lỗi nếu có test fail
if [ "$fail" -eq 0 ]; then
    exit 0
else
    exit 1
fi
