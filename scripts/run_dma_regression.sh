#!/bin/bash
# dma regression entry point; the Python runner owns all acceptance rules.
set -eu
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SEED=1
COV_EN=0
ARGS=()
ONLY_CASES=""
usage() {
    echo "Usage: $0 [SEED] [COV_EN] [--seed N] [--cov|--diag-cov] [--no-build] [--only cases] [--plusargs args]"
    echo "Default suite: dma_all. CLEAN_COV=1 explicitly clears previous coverage."
}
if [ $# -ge 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
    SEED="$1"; shift
    if [ $# -ge 1 ] && [[ "$1" =~ ^[01]$ ]]; then COV_EN="$1"; shift; fi
fi
while [ $# -gt 0 ]; do
    case "$1" in
        -s|--seed)
            [ $# -ge 2 ] && [[ "$2" =~ ^[0-9]+$ ]] || { usage; exit 2; }
            SEED="$2"; shift 2 ;;
        -c|--cov) COV_EN=1; shift ;;
        --diag-cov) ARGS+=(--diag-cov); shift ;;
        --no-build) ARGS+=(--no-build); shift ;;
        --only)
            [ $# -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
            ONLY_CASES="$2"; shift 2 ;;
        --plusargs)
            [ $# -ge 2 ] || { usage; exit 2; }
            ARGS+=("--plusargs=$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done
if [ "$COV_EN" = 1 ]; then ARGS+=(--cov); fi
if [ -n "$ONLY_CASES" ]; then ARGS+=(--tests "$ONLY_CASES"); fi
exec python3 "$SCRIPT_DIR/run_regression.py" --suite dma_all --mode dma \
    --seed "$SEED" --jobs 1 "${ARGS[@]}"
