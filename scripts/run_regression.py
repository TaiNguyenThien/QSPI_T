#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
================================================================================
 VNCHIP QSPI Verification - Self-Contained Regression Runner
 Strictly aligned with Makefile (built-in 142-test CP1-CP3 registry, no configs/):
   - Anchors execution at repo root regardless of caller CWD
   - Unique run IDs: tc_<mode>_<case>_s<seed>[_r<iter>]
   - Per-run passing-only coverage manifest -> no failed/stale scope merge
   - Process-group watchdog termination & strict UVM/SVA/rc PASS gate
   - Returns non-zero exit code on any build, test, or coverage failure
================================================================================
"""

import argparse
import csv
import hashlib
import shlex
import tempfile
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, ".."))
LOG_DIR = "logs"

# Built-in CP1-CP3 test registry (76 PIO + 30 DMA + 36 XIP = 142 cases).
# Embedded directly here so no external configs/ folder is required on servers.
PIO_EXCLUDED_CASES = (21, 41)
PIO_TIMEOUT_OVERRIDES = {
    12: 120, 13: 120, 14: 180, 16: 180, 20: 120, 25: 120, 28: 120, 29: 120,
    30: 120, 31: 120, 32: 120, 38: 240, 40: 120, 42: 180, 57: 120, 59: 180,
    60: 180, 63: 120, 69: 120, 71: 120, 74: 120, 75: 240, 76: 120,
}
DMA_CASE_SPECS = (
    ("TC_DMA_REG_01",  "dma_01", 90),
    ("TC_DMA_RX_01",   "dma_02", 90),
    ("TC_DMA_RX_02",   "dma_03", 90),
    ("TC_DMA_RX_03",   "dma_04", 90),
    ("TC_DMA_TX_01",   "dma_05", 90),
    ("TC_DMA_TX_02",   "dma_06", 90),
    ("TC_DMA_TX_03",   "dma_07", 90),
    ("TC_DMA_CFG_01",  "dma_08", 90),
    ("TC_DMA_CFG_02",  "dma_09", 90),
    ("TC_DMA_CFG_03",  "dma_10", 120),
    ("TC_DMA_AXI_01",  "dma_11", 90),
    ("TC_DMA_AXI_02",  "dma_12", 90),
    ("TC_DMA_AXI_03",  "dma_13", 90),
    ("TC_DMA_AXI_04",  "dma_14", 90),
    ("TC_DMA_AXI_05",  "dma_15", 90),
    ("TC_DMA_INT_01",  "dma_16", 90),
    ("TC_DMA_INT_02",  "dma_17", 90),
    ("TC_DMA_INT_03",  "dma_18", 90),
    ("TC_DMA_INT_04",  "dma_19", 90),
    ("TC_DMA_ERR_01",  "dma_20", 90),
    ("TC_DMA_ERR_02",  "dma_21", 90),
    ("TC_DMA_ERR_03",  "dma_22", 90),
    ("TC_DMA_ERR_04",  "dma_23", 120),
    ("TC_DMA_ERR_05",  "dma_24", 90),
    ("TC_DMA_ERR_06",  "dma_25", 90),
    ("TC_DMA_ERR_07",  "dma_26", 90),
    ("TC_DMA_RND_01",  "dma_27", 180),
    ("TC_DMA_XIP_01",  "dma_28", 120),
    ("TC_DMA_SEC_01",  "dma_29", 90),
    ("TC_DMA_PERF_01", "dma_30", 90),
)
XIP_TIMEOUT_OVERRIDES = {
    19: 120, 21: 120, 23: 180, 24: 120, 29: 120, 31: 180, 32: 180, 34: 180, 36: 600,
}


class TestResult:
    def __init__(self, tc_id, mode, seed, iter_idx=1, cov_test="",
                 status="PENDING", duration=0.0, log_file="", reason=""):
        self.tc_id = tc_id
        self.mode = mode
        self.seed = seed
        self.iter_idx = iter_idx
        self.cov_test = cov_test
        self.status = status  # PASS, FAIL, ERROR, TIMEOUT
        self.duration = duration
        self.log_file = log_file
        self.reason = reason
        self.sim_rc = None
        self.git_sha = ""
        self.dirty_tree_digest = ""
        self.scope_path = os.path.join(f"cov_work_{mode}", "scope", cov_test)


def load_testlist_config():
    """Build and validate the embedded CP1-CP3 test registry (zero external configs/)."""
    tests = {}
    pio_all = []
    for num in range(1, 79):
        if num in PIO_EXCLUDED_CASES:
            continue
        tid = f"TC_PIO_{num:03d}"
        pio_all.append(tid)
        tests[tid] = {
            "uvm_test": "qspi_pio_test",
            "plusargs": f"+QSPI_PIO_CASE={num:03d}",
            "timeout": PIO_TIMEOUT_OVERRIDES.get(num, 90),
        }

    dma_all = []
    for tid, dma_case, timeout_sec in DMA_CASE_SPECS:
        dma_all.append(tid)
        tests[tid] = {
            "uvm_test": "qspi_dma_test",
            "plusargs": f"+QSPI_DMA_CASE={dma_case}",
            "timeout": timeout_sec,
        }

    xip_all = []
    for num in range(1, 37):
        tid = f"TC_XIP_{num:03d}"
        xip_all.append(tid)
        tests[tid] = {
            "uvm_test": "qspi_xip_test",
            "plusargs": f"+QSPI_XIP_CASE=XIP_TC_{num:03d}",
            "timeout": XIP_TIMEOUT_OVERRIDES.get(num, 90),
        }

    suites = {
        "smoke": ["TC_PIO_001", "TC_DMA_RX_01", "TC_DMA_TX_01", "TC_XIP_001"],
        "pio_all": pio_all,
        "dma_all": dma_all,
        "dma_rx": ["TC_DMA_RX_01", "TC_DMA_RX_02", "TC_DMA_RX_03"],
        "dma_tx": ["TC_DMA_TX_01", "TC_DMA_TX_02", "TC_DMA_TX_03"],
        "dma_axi": [f"TC_DMA_AXI_{i:02d}" for i in range(1, 6)],
        "dma_err": [f"TC_DMA_ERR_{i:02d}" for i in range(1, 8)],
        "xip_smoke": ["TC_XIP_001"],
        "xip_all": xip_all,
        "full": pio_all + dma_all + xip_all,
    }
    return {
        "version": "2.0",
        "project": "VNCHIP QSPI Controller Verification",
        "suites": suites,
        "tests": tests,
    }


def infer_test_mode(uvm_test, plusargs):
    """Determine canonical mode ('pio', 'dma', or 'xip') for a test."""
    if "+QSPI_XIP_CASE=" in plusargs or uvm_test.startswith("qspi_xip"):
        return "xip"
    if "+QSPI_DMA_CASE=" in plusargs or uvm_test.startswith("qspi_dma"):
        return "dma"
    return "pio"


def extract_case_raw(tc_id, plusargs):
    """Extract clean case identifier matching Makefile CASE_RAW conventions."""
    for key in ("+QSPI_PIO_CASE=", "+QSPI_DMA_CASE=", "+QSPI_XIP_CASE="):
        if key in plusargs:
            return plusargs.split(key, 1)[1].split()[0]
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", tc_id)


def resolve_test_token(raw_tok, cfg, mode_hint="auto"):
    """Resolve user/rerun test token into a canonical key in cfg['tests']."""
    tests = cfg["tests"]
    tok = raw_tok.strip()
    if not tok:
        raise ValueError("Empty test identifier")
    if tok in tests:
        return tok

    if mode_hint == "xip" and re.fullmatch(r"(?:tc_?|tc)?\d+", tok.lower()):
        tok = "xip_" + re.search(r"\d+", tok).group()
    upper_tok = tok.upper()
    if upper_tok in tests:
        return upper_tok

    # Common mode-aware smoke & XIP aliases: smoke, XIP_TC_001, xip_001
    lower_tok = tok.lower()
    if lower_tok == "smoke":
        if mode_hint == "pio" and "TC_PIO_001" in tests:
            return "TC_PIO_001"
        if mode_hint == "dma" and "TC_DMA_RX_01" in tests:
            return "TC_DMA_RX_01"
        if "TC_XIP_001" in tests:
            return "TC_XIP_001"
    if lower_tok == "xip_sanity_single_read" and "TC_XIP_001" in tests:
        return "TC_XIP_001"
    m_xip = re.fullmatch(r"(?:xip_tc_|tc_xip_|xip_)(\d+)", lower_tok)
    if m_xip:
        cand = f"TC_XIP_{int(m_xip.group(1)):03d}"
        if cand in tests:
            return cand

    # Common PIO aliases: 001, tc001, tc_pio_001
    m_pio = re.fullmatch(r"(?:tc_pio_|tc)?(\d+)", lower_tok)
    if m_pio:
        num = int(m_pio.group(1))
        if num in (21, 41):
            raise ValueError(f"PIO case {num:03d} is excluded out-of-spec in the 76-test PIO registry")
        cand = f"TC_PIO_{num:03d}"
        if cand in tests:
            return cand

    # Common DMA aliases: dma_01..dma_30 matched via plusargs
    for tid, meta in tests.items():
        pa = meta.get("plusargs", "").lower()
        if re.search(rf"(?:^|\s)\+qspi_dma_case={re.escape(lower_tok)}(?:\s|$)", pa):
            return tid

    raise ValueError(f"Unknown test identifier '{tok}' (not registered in run_regression.py)")


VERDICT_TAGS = {
    "pio": "PIO_TEST_VERDICT", "dma": "DMA_TEST_VERDICT",
    "xip": "XIP_TEST_VERDICT",
}


def summarize_log_errors(log):
    """Extract concise root-cause UVM error/fatal IDs for regression terminal & CSV output."""
    err_counts = re.findall(r"^\s*UVM_ERROR\s*:\s*(\d+)\b", log, re.M)
    fat_counts = re.findall(r"^\s*UVM_FATAL\s*:\s*(\d+)\b", log, re.M)
    err_n = max((int(n) for n in err_counts), default=0)
    fat_n = max((int(n) for n in fat_counts), default=0)
    ids = []
    for m in re.finditer(r"^\s*UVM_(?:ERROR|FATAL)\b[^\n]*?\[([A-Za-z0-9_]+)\]", log, re.M):
        tok = m.group(1)
        if tok not in ids:
            ids.append(tok)
    parts = []
    if fat_n > 0:
        parts.append(f"UVM_FATAL={fat_n}")
    if err_n > 0:
        parts.append(f"UVM_ERROR={err_n}")
    if ids:
        shown = ", ".join(ids[:4]) + ("..." if len(ids) > 4 else "")
        parts.append(f"[{shown}]")
    return " ".join(parts)


def parse_uvm_log(log_path, uvm_test, sim_rc=0, mode=None):
    """One strict acceptance gate for every regression entry point."""
    if not os.path.isfile(log_path):
        if sim_rc != 0:
            return "FAIL", f"Simulator/make exited with code {sim_rc} (no log)"
        return "ERROR", "Log file not created"
    mode = mode if mode in VERDICT_TAGS else infer_test_mode(uvm_test, "")
    tag = VERDICT_TAGS[mode]
    with open(log_path, encoding="utf-8", errors="replace") as stream:
        log = stream.read()
    err_hint = summarize_log_errors(log)
    if sim_rc != 0:
        if err_hint:
            return "FAIL", f"{err_hint} (rc={sim_rc})"
        return "FAIL", f"Simulator/make exited with non-zero code ({sim_rc})"
    if not re.search(r"Report counts by severity|UVM Report Summary", log):
        return "FAIL", "Missing UVM Report Summary"
    for severity in ("ERROR", "FATAL"):
        counts = re.findall(rf"^\s*UVM_{severity}\s*:\s*(\d+)\b", log, re.M)
        if not counts or any(int(n) != 0 for n in counts):
            return "FAIL", err_hint or f"Missing/nonzero UVM_{severity} summary count"
        if re.search(rf"^\s*UVM_{severity}\b(?!\s*:)" , log, re.M):
            return "FAIL", err_hint or f"UVM_{severity} report in log"
    if re.search(r"Offending '|Assertion (?:error|failed)|SVA_ERR|XIP_SVA_|"
                 r"\*(?:E|F),|srun: error:|NOSNAP|Cannot find license|"
                 r"Segmentation fault|Segment fault|\[MAKE_RUN_VERDICT\]\s+FAIL", log, re.I):
        return "FAIL", err_hint or "SVA/assertion/simulator error in log"
    verdicts = re.findall(rf"\[{tag}\]\s+\[(PASS|FAIL)\]", log)
    if "FAIL" in verdicts or re.search(r"\[FAIL\]", log):
        return "FAIL", err_hint or f"Explicit failure verdict ({tag})"
    if not verdicts or verdicts[-1] != "PASS":
        return "FAIL", f"Missing [{tag}] [PASS]"
    if mode == "xip" and "[XIP_SB_SUMMARY]" not in log:
        return "FAIL", "Missing XIP_SB_SUMMARY evidence"
    return "PASS", f"sim_rc=0, clean UVM/SVA, {tag} PASS"


def source_provenance():
    """Hash non-RTL source changes without opening the blind design sources."""
    def git_bytes(*args):
        return subprocess.check_output(["git", *args], cwd=REPO_ROOT, stderr=subprocess.DEVNULL)

    digest = hashlib.sha256()
    try:
        sha = git_bytes("rev-parse", "HEAD").decode().strip()
        in_git = True
    except (subprocess.CalledProcessError, FileNotFoundError):
        sha = "nongit"
        in_git = False

    source_names = set()
    if in_git:
        paths = [".", ":(exclude)rtl/**"]
        try:
            digest.update(git_bytes("diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--", *paths))
        except subprocess.CalledProcessError:
            # Fallback for older git (< 1.9) without :(exclude) pathspec magic
            non_rtl_roots = [p for p in ("tb", "inf", "sva", "filelist", "scripts", "Makefile")
                             if os.path.exists(os.path.join(REPO_ROOT, p))]
            if non_rtl_roots:
                digest.update(git_bytes("diff", "--no-ext-diff", "--no-textconv", "--binary", "HEAD", "--", *non_rtl_roots))
        try:
            untracked = git_bytes("ls-files", "--others", "--exclude-standard", "-z")
            source_names.update(filter(None, untracked.split(b"\0")))
        except subprocess.CalledProcessError:
            pass
        # Keep runner file included even if locally ignored by Git.
        source_names.add(b"scripts/run_regression.py")
    else:
        # Non-git server directory fallback: hash non-RTL verification sources deterministically.
        for rel_root in ("Makefile", "filelist", "inf", "sva", "tb", "scripts"):
            abs_root = os.path.join(REPO_ROOT, rel_root)
            if os.path.isfile(abs_root):
                source_names.add(rel_root.encode("utf-8"))
            elif os.path.isdir(abs_root):
                for walk_root, dirnames, filenames in os.walk(abs_root):
                    dirnames[:] = sorted(d for d in dirnames if not d.startswith(".") and d != "__pycache__")
                    for fname in sorted(filenames):
                        if fname.endswith(".pyc"):
                            continue
                        rel_p = os.path.relpath(os.path.join(walk_root, fname), REPO_ROOT).replace("\\", "/")
                        source_names.add(rel_p.encode("utf-8"))

    for name in sorted(source_names):
        relative = os.fsdecode(name).replace("\\", "/")
        candidate = os.path.join(REPO_ROOT, relative)
        if relative.startswith("rtl/") or os.path.islink(candidate):
            continue
        if relative.split("/", 1)[0].startswith(("logs", "cov_work_", "coverage_report_")):
            continue
        if os.path.isfile(candidate):
            digest.update(relative.encode("utf-8") + b"\0")
            with open(candidate, "rb") as stream:
                digest.update(stream.read())
    return sha, digest.hexdigest()


def kill_process_tree(proc):
    """Terminate subprocess and all descendants cleanly."""
    try:
        if os.name == "nt":
            subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
            if proc.poll() is None:
                proc.kill()
        else:
            os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
    except ProcessLookupError:
        pass
    except Exception:
        try:
            proc.kill()
        except Exception:
            pass
    try:
        proc.wait(timeout=5)
    except Exception:
        pass


def run_single_test(tc_id, seed, iter_idx, repeat_same_seed, cov_en, timeout_sec, config, diag_cov=False):
    """Execute one testcase with isolated log and coverage scope."""
    meta = config["tests"][tc_id]
    uvm_test = meta["uvm_test"]
    plusargs = meta["plusargs"]
    tc_timeout = meta.get("timeout", 120)
    effective_timeout = timeout_sec if timeout_sec is not None else tc_timeout

    test_mode = infer_test_mode(uvm_test, plusargs)
    case_raw = extract_case_raw(tc_id, plusargs)
    plusargs += config.get("extra_plusargs", "")
    plusargs = re.sub(r"(?:^|\s)\+QSPI_SEED=\S+", "", plusargs).strip()
    plusargs += f" +QSPI_SEED={seed}"
    cov_test_name = (
        f"tc_{test_mode}_{case_raw}_s{seed}_r{iter_idx}"
        if repeat_same_seed
        else f"tc_{test_mode}_{case_raw}_s{seed}"
    )

    test_log = os.path.join(LOG_DIR, f"{cov_test_name}.log")
    if os.path.exists(test_log):
        os.remove(test_log)

    start_time = time.monotonic()
    result = TestResult(
        tc_id=tc_id,
        mode=test_mode,
        seed=seed,
        iter_idx=iter_idx,
        cov_test=cov_test_name,
        log_file=test_log,
    )

    cov_active = cov_en or diag_cov
    cov_dir = f"cov_work_{test_mode}_diag" if diag_cov else f"cov_work_{test_mode}"
    result.git_sha, result.dirty_tree_digest = config["provenance"]
    result.scope_path = os.path.join(cov_dir, "scope", cov_test_name)
    # Replace only this exact run, retaining every other seed and iteration.
    shutil.rmtree(result.scope_path, ignore_errors=True)
    worker_tmp = tempfile.mkdtemp(prefix=cov_test_name + "_", dir=os.path.join(REPO_ROOT, LOG_DIR))
    worker_env = os.environ.copy()
    worker_env.update(TMPDIR=worker_tmp, TMP=worker_tmp, TEMP=worker_tmp)
    simulator = os.environ.get("XMSIM", "xmsim")
    simulator += " -logfile " + shlex.quote(os.path.join(worker_tmp, "xmsim.log"))
    simulator += " -keyfile " + shlex.quote(os.path.join(worker_tmp, "xmsim.key"))
    cmd = [
        "make", "--no-print-directory", "_run_test",
        f"TEST={uvm_test}",
        f"PLUSARGS={plusargs}",
        f"MODE={test_mode}",
        f"COV_DIR={cov_dir}",
        f"COV_TEST={cov_test_name}",
        f"LOG_FILE={test_log}",
        f"SEED={seed}",
        f"COV_EN={1 if cov_active else 0}",
        f"DIAG_COV={1 if diag_cov else 0}",
        "WAVE_EN=0",
        f"XMSIM={simulator}",
        f"PASS_MANIFEST={os.path.join(worker_tmp, 'pass.list')}",
        f"VCD_TCL={os.path.join(worker_tmp, 'wave.tcl')}",
    ]

    popen_kwargs = {
        "stdout": subprocess.DEVNULL,
        "stderr": subprocess.DEVNULL,
        "cwd": REPO_ROOT,
        "env": worker_env,
    }
    if os.name == "nt":
        popen_kwargs["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP
    else:
        popen_kwargs["start_new_session"] = True

    try:
        proc = subprocess.Popen(cmd, **popen_kwargs)
        try:
            rc = proc.wait(timeout=effective_timeout)
        except subprocess.TimeoutExpired:
            kill_process_tree(proc)
            result.status = "TIMEOUT"
            result.duration = time.monotonic() - start_time
            result.reason = f"Watchdog timeout ({effective_timeout}s)"
            with open(test_log, "a", encoding="utf-8") as f_app:
                f_app.write(f"\n[RUNNER ERROR] Process group killed by watchdog after {effective_timeout}s!\n")
            return result

        result.duration = time.monotonic() - start_time
        result.sim_rc = rc
        status, reason = parse_uvm_log(test_log, uvm_test, rc, mode=test_mode)
        result.status = status
        result.reason = reason

    except Exception as exc:
        result.status = "ERROR"
        result.duration = time.monotonic() - start_time
        result.reason = f"Execution exception: {exc}"

    finally:
        if result.status != "PASS" and not (diag_cov and result.status != "TIMEOUT"):
            shutil.rmtree(result.scope_path, ignore_errors=True)
        shutil.rmtree(worker_tmp, ignore_errors=True)
    return result


def build_run_queue(test_ids, explicit_seeds, repeat_count, fixed_seed, random_seed):
    """Build run queue and guarantee unique _r{occ} tags for duplicate (tc_id, seed) pairs."""
    raw_entries = []
    for tc in test_ids:
        if explicit_seeds is not None:
            for _rep in range(1, repeat_count + 1):
                for s in explicit_seeds:
                    raw_entries.append((tc, s))
        elif repeat_count > 1:
            used_seeds = set()
            for _rep in range(1, repeat_count + 1):
                if random_seed:
                    s = random.randint(1, 999999)
                    while s in used_seeds:
                        s = random.randint(1, 999999)
                    used_seeds.add(s)
                else:
                    s = fixed_seed
                raw_entries.append((tc, s))
        else:
            s = random.randint(1, 999999) if random_seed else fixed_seed
            raw_entries.append((tc, s))

    totals = {}
    for tc, s in raw_entries:
        totals[(tc, s)] = totals.get((tc, s), 0) + 1

    seen = {}
    queue = []
    for tc, s in raw_entries:
        occ = seen.get((tc, s), 0) + 1
        seen[(tc, s)] = occ
        queue.append((tc, s, occ, totals[(tc, s)] > 1))
    return queue


def resolve_range_ids(range_str, mode_arg, suite_arg, cfg):
    """Resolve --range A-B for pio, dma, or xip safely."""
    m = re.fullmatch(r"\s*(\d+)\s*-\s*(\d+)\s*", range_str)
    if not m:
        raise ValueError(f"Invalid --range format '{range_str}' (expected START-END, e.g. 1-10)")
    start_r, end_r = int(m.group(1)), int(m.group(2))
    if start_r < 1 or start_r > end_r:
        raise ValueError(f"Invalid --range bounds {start_r}-{end_r}")

    target_mode = mode_arg
    if target_mode == "auto":
        if "xip" in suite_arg:
            target_mode = "xip"
        elif "pio" in suite_arg:
            target_mode = "pio"
        elif "dma" in suite_arg:
            target_mode = "dma"
        else:
            raise ValueError("--range with ambiguous suite requires --mode {pio|dma|xip}")

    resolved = []
    for i in range(start_r, end_r + 1):
        if target_mode == "pio":
            if i in (21, 41):
                continue
            cand = f"TC_PIO_{i:03d}"
            if cand not in cfg["tests"]:
                raise ValueError(f"PIO range index {i} ({cand}) is out of bounds")
            resolved.append(cand)
        elif target_mode == "xip":
            cand = f"TC_XIP_{i:03d}"
            if cand not in cfg["tests"]:
                raise ValueError(f"XIP range index {i} ({cand}) is out of bounds")
            resolved.append(cand)
        else:  # dma
            resolved.append(resolve_test_token(f"dma_{i:02d}", cfg))
    return resolved


def main():
    try:
        config = load_testlist_config()
    except Exception as exc:
        print(f"[FATAL] {exc}", file=sys.stderr)
        sys.exit(2)

    suite_choices = sorted(config["suites"].keys())

    parser = argparse.ArgumentParser(
        description="VNCHIP QSPI Regression Runner - Manifest & Makefile Aligned",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--suite",
        choices=suite_choices,
        default=None,
        help="Manifest suite; default is <mode>_all or dma_all for auto",
    )
    parser.add_argument(
        "--mode",
        choices=["auto", "pio", "dma", "xip"],
        default="auto",
        help="Execution/coverage mode context (default: auto-detected from selected tests)",
    )
    parser.add_argument("--test", type=str, help="Run one test (e.g., TC_XIP_001, dma_01, 001)")
    parser.add_argument("--tests", type=str, help="Comma-separated Test IDs")
    parser.add_argument("--range", type=str, help="Numeric index range (e.g., 1-10 with --mode pio|dma|xip)")
    parser.add_argument("--seed", type=int, default=1, help="Simulation seed (>= 0, default: 1)")
    parser.add_argument("--random-seed", action="store_true", help="Generate random seed per run")
    parser.add_argument("--seeds", type=str, help="Comma-separated seed list (e.g., 1,2,3)")
    parser.add_argument("--repeat", type=int, default=1, help="Repetitions per test (>= 1, default: 1)")
    parser.add_argument("--jobs", "-j", type=int, default=1, help="Parallel worker count (>= 1, default: 1)")
    parser.add_argument("--timeout", type=int, default=None, help="Per-test watchdog timeout in seconds (> 0)")
    parser.add_argument("--cov", action="store_true", help="Enable coverage collection & passing-only merge")
    parser.add_argument("--diag-cov", action="store_true",
                        help="Diagnostic coverage: keep & merge completed scopes into cov_work_<mode>_diag (NOT for sign-off)")
    parser.add_argument("--no-build", action="store_true", help="Skip 'make build' step")
    parser.add_argument("--rerun-file", type=str, help="Re-run Test IDs listed in file (e.g., logs/failed_tests.txt)")

    parser.add_argument("--plusargs", default="", help="Extra simulator plusargs")
    parser.add_argument("--print-provenance", action="store_true",
                        help="Print canonical blind-box provenance (git_sha, dirty_digest, dut_release_id) and exit")
    parser.add_argument("--check-log", type=str, default=None,
                        help="Validate one simulation log with the canonical verdict parser (requires --mode pio|dma|xip)")
    args = parser.parse_args()
    if args.print_provenance:
        sha, dig = source_provenance()
        dut_rel = os.environ.get("QSPI_DUT_RELEASE_ID", "unspecified").strip() or "unspecified"
        print(f"git_sha={sha}")
        print(f"dirty_digest={dig}")
        print(f"dut_release_id={dut_rel}")
        sys.exit(0)
    if args.check_log is not None:
        if args.mode not in VERDICT_TAGS:
            print(f"[ERROR] --check-log requires --mode in {sorted(VERDICT_TAGS.keys())}", file=sys.stderr)
            sys.exit(2)
        st, reason = parse_uvm_log(args.check_log, f"qspi_{args.mode}_test", sim_rc=0, mode=args.mode)
        print(f"{st}: {reason}")
        sys.exit(0 if st == "PASS" else 1)
    if args.cov and args.diag_cov:
        parser.error("--cov and --diag-cov are mutually exclusive")
    args.suite = args.suite or {"pio": "pio_all", "dma": "dma_all", "xip": "xip_all"}.get(args.mode, "dma_all")
    if re.search(r"\+QSPI_(?:SEED|PIO_CASE|DMA_CASE|XIP_CASE)=",args.plusargs):
        parser.error("Use runner seed/case options for reproducible selection")
    config["extra_plusargs"] = " " + args.plusargs if args.plusargs else ""

    if args.seed < 0:
        print("[ERROR] --seed must be >= 0", file=sys.stderr)
        sys.exit(2)
    if args.repeat < 1:
        print("[ERROR] --repeat must be >= 1", file=sys.stderr)
        sys.exit(2)
    if args.jobs < 1:
        print("[ERROR] --jobs must be >= 1", file=sys.stderr)
        sys.exit(2)
    if args.timeout is not None and args.timeout <= 0:
        print("[ERROR] --timeout must be > 0", file=sys.stderr)
        sys.exit(2)

    os.chdir(REPO_ROOT)
    os.makedirs(LOG_DIR, exist_ok=True)

    # 1. Resolve and strictly validate test IDs
    try:
        if args.rerun_file is not None:
            if not args.rerun_file.strip():
                raise ValueError("Empty --rerun-file argument")
            if not os.path.exists(args.rerun_file):
                raise FileNotFoundError(f"Rerun file not found: {args.rerun_file}")
            raw_tokens = []
            with open(args.rerun_file, "r", encoding="utf-8") as f:
                for line in f:
                    line = line.strip()
                    if not line or line.startswith("#"):
                        continue
                    raw_tokens.append(line.split()[0].rstrip(":"))
            if not raw_tokens:
                raise ValueError(f"Rerun file is empty: {args.rerun_file}")
            test_ids = [resolve_test_token(t, config, args.mode) for t in raw_tokens]
            print(f"[*] Loaded {len(test_ids)} test(s) for rerun from: {args.rerun_file}")
        elif args.test is not None:
            test_ids = [resolve_test_token(args.test, config, args.mode)]
        elif args.tests is not None:
            raw_tokens = [t.strip() for t in args.tests.split(",") if t.strip()]
            if not raw_tokens:
                raise ValueError("Empty --tests list")
            test_ids = [resolve_test_token(t, config, args.mode) for t in raw_tokens]
        elif args.range is not None:
            test_ids = resolve_range_ids(args.range, args.mode, args.suite, config)
        else:
            test_ids = list(config["suites"][args.suite])
        if not test_ids:
            raise ValueError("Selected test list is empty; refusing to exit as PASS.")
    except Exception as exc:
        print(f"[ERROR] {exc}", file=sys.stderr)
        sys.exit(2)

    if args.mode != "auto":
        mismatched = [tid for tid in test_ids if infer_test_mode(config["tests"][tid]["uvm_test"], config["tests"][tid]["plusargs"]) != args.mode]
        if mismatched:
            parser.error(f"Selected tests do not match --mode {args.mode}: {mismatched}")
    config["provenance"] = source_provenance()

    # Determine modes present in this run
    active_modes = sorted({
        infer_test_mode(config["tests"][tid]["uvm_test"], config["tests"][tid]["plusargs"])
        for tid in test_ids
    })
    effective_mode = active_modes[0] if (args.mode == "auto" and len(active_modes) == 1) else (
        "full" if args.mode == "auto" else args.mode
    )

    # 2. Build run queue cleanly supporting multiple seeds and --repeat
    try:
        explicit_seeds = None
        if args.seeds:
            explicit_seeds = []
            for tok in args.seeds.split(","):
                tok = tok.strip()
                if not tok:
                    continue
                val = int(tok)
                if val < 0:
                    raise ValueError(f"Seed must be >= 0: {val}")
                explicit_seeds.append(val)
            if not explicit_seeds:
                raise ValueError("Empty --seeds list")
    except ValueError as exc:
        print(f"[ERROR] Invalid --seeds: {exc}", file=sys.stderr)
        sys.exit(2)

    run_queue = build_run_queue(test_ids, explicit_seeds, args.repeat, args.seed, args.random_seed)

    total_runs = len(run_queue)

    print("================================================================================")
    print("                VNCHIP QSPI REGRESSION RUNNER                                   ")
    print("================================================================================")
    print(f" Workdir        : {REPO_ROOT}")
    print(f" Suite / Mode   : {args.suite} / {effective_mode.upper()} ({len(test_ids)} unique, {total_runs} runs)")
    print(f" Active Modes   : {', '.join(active_modes)}")
    print(f" Parallel Jobs  : {args.jobs}")
    print(f" Seed Policy    : {'RANDOM' if args.random_seed else (args.seeds if args.seeds else f'FIXED ({args.seed})')}")
    cov_active = args.cov or args.diag_cov
    cov_policy = (
        "ENABLED (passing-only sign-off merge)"
        if args.cov
        else ("DIAGNOSTIC ONLY (cov_work_<mode>_diag; NOT for sign-off)" if args.diag_cov else "DISABLED")
    )
    print(f" Coverage       : {cov_policy}")
    print("================================================================================")

    # 3. Clean coverage workspaces & build snapshot if requested
    if cov_active and os.environ.get("CLEAN_COV") == "1":
        for m in active_modes:
            if args.diag_cov:
                shutil.rmtree(f"cov_work_{m}_diag", ignore_errors=True)
                shutil.rmtree(f"coverage_report_{m}_diag", ignore_errors=True)
            else:
                merged_dir = os.path.join(f"cov_work_{m}", "scope", f"merged_cov_{m}")
                shutil.rmtree(merged_dir, ignore_errors=True)
                subprocess.call(["make", "clean_cov", f"MODE={m}"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if not args.diag_cov:
            shutil.rmtree(os.path.join("cov_work_full", "scope", "merged_cov_full"), ignore_errors=True)
            shutil.rmtree("coverage_report_full", ignore_errors=True)

    if not args.no_build:
        cov_flag = 1 if cov_active else 0
        print(f"[*] Building snapshot (make build COV_EN={cov_flag} MODE={effective_mode})...")
        build_log = os.path.join(LOG_DIR, f"build_{effective_mode}.log")
        build_cmd = ["make", "build", f"COV_EN={cov_flag}", f"MODE={effective_mode}"]
        with open(build_log, "w", encoding="utf-8") as bf:
            res = subprocess.call(build_cmd, stdout=bf, stderr=subprocess.STDOUT)
        if res != 0:
            print(f"[-] ERROR: Build snapshot failed! See: {build_log}", file=sys.stderr)
            sys.exit(2)
        print("[+] Build snapshot succeeded!\n")
    else:
        build_meta_path = os.path.join(LOG_DIR, "build_provenance.meta")
        if not os.path.isfile(build_meta_path):
            print(f"[-] ERROR: --no-build requires {build_meta_path} from a matching build.", file=sys.stderr)
            sys.exit(2)
        meta_kv = {}
        with open(build_meta_path, "r", encoding="utf-8") as mf:
            for line in mf:
                if "=" in line:
                    k, v = line.strip().split("=", 1)
                    meta_kv[k] = v
        cur_sha, cur_dig = config["provenance"]
        cur_dut = os.environ.get("QSPI_DUT_RELEASE_ID", "unspecified").strip() or "unspecified"
        if (meta_kv.get("git_sha") != cur_sha or
                meta_kv.get("dirty_digest") != cur_dig or
                meta_kv.get("dut_release_id", "unspecified") != cur_dut):
            print("[-] ERROR: Stale build snapshot provenance; rebuild without --no-build.", file=sys.stderr)
            sys.exit(2)
        if cov_active and meta_kv.get("cov_en") != "1":
            print("[-] ERROR: Existing snapshot was built with COV_EN=0; rebuild with --cov or --diag-cov.", file=sys.stderr)
            sys.exit(2)

    # 4. Dispatch simulations
    print(f"[*] Dispatching {total_runs} simulation job(s) across {args.jobs} worker(s)...\n")
    start_total_time = time.time()
    results = []
    completed_count = 0

    with ThreadPoolExecutor(max_workers=args.jobs) as executor:
        future_map = {
            executor.submit(run_single_test, tc, s, rep, same_seed, args.cov, args.timeout, config, args.diag_cov): (tc, s, rep)
            for tc, s, rep, same_seed in run_queue
        }
        for future in as_completed(future_map):
            tc, s, rep = future_map[future]
            completed_count += 1
            try:
                res = future.result()
            except Exception as exc:
                res = TestResult(tc_id=tc, mode="unknown", seed=s, iter_idx=rep,
                                 status="ERROR", reason=f"Worker exception: {exc}")
            results.append(res)
            print(
                f"[{completed_count:02d}/{total_runs:02d}] {res.tc_id:<16} "
                f"(Seed {res.seed:<6} r{res.iter_idx}) -> [{res.status:<7}] "
                f"({res.duration:5.1f}s) | {res.reason}"
            )

    total_elapsed = time.time() - start_total_time

    # Sort deterministically for reports
    results.sort(key=lambda r: (r.tc_id, r.seed, r.iter_idx))

    pass_list = [r for r in results if r.status == "PASS"]
    fail_list = [r for r in results if r.status == "FAIL"]
    error_list = [r for r in results if r.status == "ERROR"]
    timeout_list = [r for r in results if r.status == "TIMEOUT"]

    # 5. Terminal Summary
    print("\n" + "=" * 96)
    print(f"{'TEST ID':<16} | {'MODE':<4} | {'SEED':<6} | {'ITER':<4} | {'STATUS':<8} | {'TIME':<7} | {'LOG FILE'}")
    print("-" * 96)
    for r in results:
        print(f"{r.tc_id:<16} | {r.mode:<4} | {r.seed:<6} | {r.iter_idx:<4} | {r.status:<8} | {r.duration:>6.1f}s | {r.log_file}")
    print("=" * 96)
    print(
        f" RESULT : {len(pass_list)} PASS | {len(fail_list)} FAIL | "
        f"{len(error_list)} ERROR | {len(timeout_list)} TIMEOUT"
    )
    print(f" ELAPSED: {total_elapsed / 60.0:.2f} min")
    print("=" * 96)

    # 6. Write CSV Summary properly with csv.writer
    report_prefix = active_modes[0] + "_" if len(active_modes)==1 else ""
    csv_file = os.path.join(LOG_DIR, report_prefix + "regression_summary.csv")
    with open(csv_file, "w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, quoting=csv.QUOTE_ALL, lineterminator="\n")
        writer.writerow(["Test_ID", "Mode", "Seed", "Iter", "Status", "Duration_Sec", "Reason", "Log_File", "Scope_Path", "Sim_RC", "Git_SHA", "Dirty_Tree_Digest", "Digest_Scope"])
        for r in results:
            writer.writerow([r.tc_id, r.mode, r.seed, r.iter_idx, r.status, f"{r.duration:.2f}", r.reason, r.log_file, r.scope_path, r.sim_rc, r.git_sha, r.dirty_tree_digest, "non-rtl-source"])
    print(f"\n[+] Saved CSV summary : {csv_file}")

    manifest_csv = os.path.join(LOG_DIR, "run_manifest.csv")
    fresh = not os.path.exists(manifest_csv)
    with open(manifest_csv, "a", encoding="utf-8", newline="") as stream:
        writer=csv.writer(stream, lineterminator="\n")
        if fresh:
            writer.writerow(["Case", "Mode", "Seed", "Iter", "Verdict", "Sim_RC", "Git_SHA", "Dirty_Tree_Digest", "Digest_Scope", "Log_Path", "Scope_Path"])
        for r in results:
            writer.writerow([extract_case_raw(r.tc_id,config["tests"][r.tc_id]["plusargs"]),r.mode,r.seed,r.iter_idx,r.status,r.sim_rc,r.git_sha,r.dirty_tree_digest,"non-rtl-source",r.log_file,r.scope_path])

    # 7. Write deduplicated failing tests list
    failed_txt = os.path.join(LOG_DIR, report_prefix + "failed_tests.txt")
    re_candidates = fail_list + error_list + timeout_list
    if re_candidates:
        seen = set()
        unique_failed = []
        for r in re_candidates:
            if r.tc_id not in seen:
                seen.add(r.tc_id)
                unique_failed.append(r.tc_id)
        with open(failed_txt, "w", encoding="utf-8") as f:
            for tid in unique_failed:
                f.write(f"{tid}\n")
        print(f"[!] Saved failed list : {failed_txt}")
        print(f"[*] Rerun command     : python3 scripts/run_regression.py --rerun-file {failed_txt}")
    elif os.path.exists(failed_txt):
        os.remove(failed_txt)

    # 8. Passing-only coverage merge & report per active mode + optional multi-mode merge
    cov_failed = False
    if args.cov:
        merged_modes_ok = []
        is_multi_mode = len(active_modes) > 1
        for m in active_modes:
            mode_runs = [r for r in results if r.mode == m]
            mode_pass = [r for r in mode_runs if r.status == "PASS"]
            merged_dir = os.path.join(f"cov_work_{m}", "scope", f"merged_cov_{m}")
            shutil.rmtree(merged_dir, ignore_errors=True)

            if not mode_pass:
                print(f"[!] Zero passing tests for mode '{m}'; refusing to merge coverage.")
                cov_failed = True
                continue

            os.makedirs(f"cov_work_{m}", exist_ok=True)
            manifest_path = os.path.join(f"cov_work_{m}", f"pass_scopes_{m}_run.list")
            valid_scopes = []
            mode_cov_missing = False
            with open(manifest_path, "w", encoding="utf-8") as mf:
                for r in mode_pass:
                    scope_path = os.path.join(f"cov_work_{m}", "scope", r.cov_test)
                    if os.path.isdir(scope_path):
                        valid_scopes.append(scope_path)
                        mf.write(scope_path + "\n")
                    else:
                        print(f"[-] ERROR: missing coverage scope directory {scope_path}")
                        mode_cov_missing = True
                        cov_failed = True
            if len(valid_scopes) != len(mode_pass) or mode_cov_missing or not valid_scopes:
                print(f"[-] Incomplete coverage scopes for MODE={m} ({len(valid_scopes)}/{len(mode_pass)} found); failing coverage gate.")
                cov_failed = True
                continue

            print(f"\n[*] Merging {len(valid_scopes)} passing scope(s) for MODE={m}...")
            rc_m = subprocess.call(["make", "cov_merge", f"MODE={m}", f"PASS_MANIFEST={manifest_path}"])
            rc_h = subprocess.call(["make", "cov_report", f"MODE={m}", "REPORT=html"]) if rc_m == 0 else 1
            rc_t = subprocess.call(["make", "cov_report", f"MODE={m}", "REPORT=text"]) if rc_m == 0 else 1
            if rc_m != 0 or rc_h != 0 or rc_t != 0:
                print(f"[-] Coverage merge/report failed for MODE={m}")
                cov_failed = True
            else:
                merged_modes_ok.append(m)

        if is_multi_mode:
            if len(merged_modes_ok) == len(active_modes) and merged_modes_ok:
                modes_arg = " ".join(merged_modes_ok)
                print(f"\n[*] Merging Multi-Mode coverage across modes: {modes_arg}...")
                fm_cmd = ["make", "cov_full_merge", f"FULL_MODES={modes_arg}"]
                rc_fm = subprocess.call(fm_cmd)
                rc_fh = subprocess.call(["make", "cov_report", "MODE=full", "REPORT=html"]) if rc_fm == 0 else 1
                rc_ft = subprocess.call(["make", "cov_report", "MODE=full", "REPORT=text"]) if rc_fm == 0 else 1
                if rc_fm != 0 or rc_fh != 0 or rc_ft != 0:
                    print("[-] Multi-mode coverage merge/report failed")
                    cov_failed = True
            else:
                shutil.rmtree(os.path.join("cov_work_full", "scope", "merged_cov_full"), ignore_errors=True)
                cov_failed = True
    elif args.diag_cov:
        for m in active_modes:
            cov_dir = f"cov_work_{m}_diag"
            mode_runs = [r for r in results if r.mode == m and r.status != "TIMEOUT"]
            os.makedirs(cov_dir, exist_ok=True)
            manifest_path = os.path.join(cov_dir, f"diag_scopes_{m}_run.list")
            valid_scopes = []
            with open(manifest_path, "w", encoding="utf-8") as mf:
                for r in mode_runs:
                    scope_path = os.path.join(cov_dir, "scope", r.cov_test)
                    if os.path.isdir(scope_path):
                        valid_scopes.append(scope_path)
                        mf.write(scope_path + "\n")
            if not valid_scopes:
                print(f"[!] Zero diagnostic coverage scopes found for MODE={m} in {cov_dir}/scope")
                cov_failed = True
                continue
            print(f"\n[*] [DIAGNOSTIC ONLY] Merging {len(valid_scopes)} completed scope(s) for MODE={m}...")
            rc_m = subprocess.call(["make", "cov_diag_merge", f"MODE={m}", "DIAG_COV=1", f"DIAG_MANIFEST={manifest_path}"])
            rc_h = subprocess.call(["make", "cov_report", f"MODE={m}", "DIAG_COV=1", f"TEST=merged_cov_{m}_diag", "REPORT=html"]) if rc_m == 0 else 1
            rc_t = subprocess.call(["make", "cov_report", f"MODE={m}", "DIAG_COV=1", f"TEST=merged_cov_{m}_diag", "REPORT=text"]) if rc_m == 0 else 1
            if rc_m != 0 or rc_h != 0 or rc_t != 0:
                print(f"[-] Diagnostic coverage merge/report failed for MODE={m}")
                cov_failed = True
            else:
                print(f"[+] Diagnostic HTML : coverage_report_{m}_diag/merged_cov_{m}_diag.html/index.html")
                print(f"[+] Diagnostic Text : coverage_report_{m}_diag/merged_cov_{m}_diag.txt")
                print(f"[+] Diagnostic GUI  : make cov_gui MODE={m} DIAG_COV=1")

    if re_candidates or cov_failed:
        print("\n>> Regression finished WITH FAILURES.")
        sys.exit(1)

    print("\n>> Regression finished ALL PASS.")
    sys.exit(0)


if __name__ == "__main__":
    main()
