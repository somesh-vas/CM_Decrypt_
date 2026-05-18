#!/usr/bin/env python3
"""Run one Codex GPU optimisation iteration for CM_Decrypt_.

This runner is designed for the remote non-root RTX 3090 Ti workflow:
- do not regenerate CPU/reference outputs during an optimisation iteration;
- build/run only GPU_Optimised for correctness;
- compare GPU_Optimised output against pre-existing CPU errorstreams;
- profile only GPU_Optimised;
- save text summaries and metrics, not heavy .ncu-rep files;
- optionally commit success or commit failure logs and revert failed code.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
RESULTS_ROOT = ROOT / "bench" / "results"
PARAMS_ALL = ["348864", "460896", "6688128", "6960119", "8192128"]
ARCH_DEFAULT = "sm_75"
KATNUM_DEFAULT = 50000


def now_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def safe_label(label: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", label.strip())
    cleaned = cleaned.strip("-._")
    return cleaned or "iteration"


def quote_cmd(cmd: list[str]) -> str:
    return " ".join(cmd)


def run_cmd(cmd: list[str], *, cwd: Path, log_path: Path, allow_fail: bool = True) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as handle:
        handle.write("$ " + quote_cmd(cmd) + "\n\n")
        proc = subprocess.Popen(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            print(line, end="")
            handle.write(line)
        rc = proc.wait()
        handle.write(f"\n[exit_code] {rc}\n")
    if rc != 0 and not allow_fail:
        raise subprocess.CalledProcessError(rc, cmd)
    return rc


def capture_cmd(cmd: list[str], *, cwd: Path) -> dict[str, Any]:
    try:
        proc = subprocess.run(
            cmd,
            cwd=str(cwd),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            check=False,
        )
        return {"cmd": cmd, "returncode": proc.returncode, "output": proc.stdout}
    except FileNotFoundError as exc:
        return {"cmd": cmd, "returncode": 127, "output": str(exc)}


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def copy_if_exists(src: Path, dst: Path) -> bool:
    if not src.exists() or not src.is_file():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return True


def selected_params(value: str) -> list[str]:
    if value.strip() == "all":
        return PARAMS_ALL[:]
    params = [p.strip() for p in value.split(",") if p.strip()]
    bad = [p for p in params if p not in PARAMS_ALL]
    if bad:
        raise SystemExit(f"Unsupported params: {','.join(bad)}")
    return params


def parse_profile(path: Path) -> dict[str, Any]:
    data: dict[str, Any] = {}
    if not path.exists():
        data["profile_found"] = False
        return data
    data["profile_found"] = True
    text = path.read_text(encoding="utf-8", errors="ignore")
    patterns = {
        "ciphertexts": r"ciphertexts processed\s*:\s*([0-9]+)",
        "batch_size": r"batch size\s*:\s*([0-9]+)",
        "h2d_ms": r"H2D\s*:\s*([0-9.]+) ms",
        "syndrome_ms": r"syndrome\s*:\s*([0-9.]+) ms",
        "bm_ms": r"Berlekamp-Massey\s*:\s*([0-9.]+) ms",
        "chien_ms": r"Chien search\s*:\s*([0-9.]+) ms",
        "d2h_ms": r"D2H\s*:\s*([0-9.]+) ms",
        "wall_ms": r"wall\s*:\s*([0-9.]+) ms",
        "overhead_ms": r"overhead\s*:\s*([-0-9.]+) ms",
        "throughput_ct_s": r"throughput\s*:\s*([0-9.]+) ct/s",
    }
    for key, pattern in patterns.items():
        match = re.search(pattern, text, flags=re.IGNORECASE)
        if not match:
            continue
        value = match.group(1)
        data[key] = int(value) if key in {"ciphertexts", "batch_size"} else float(value)
    if all(k in data for k in ["syndrome_ms", "bm_ms", "chien_ms"]):
        kernel_ms = data["syndrome_ms"] + data["bm_ms"] + data["chien_ms"]
        data["kernel_ms"] = kernel_ms
        data["kernel_ct_s"] = (data.get("ciphertexts", 0) * 1000.0 / kernel_ms) if kernel_ms > 0 else None
        data["chien_kernel_pct"] = (100.0 * data["chien_ms"] / kernel_ms) if kernel_ms > 0 else None
    return data


def parse_number(token: str) -> float | None:
    token = token.replace(",", "").strip()
    try:
        return float(token)
    except ValueError:
        return None


def parse_chien_ncu_metrics(txt_files: list[Path]) -> dict[str, Any]:
    """Best-effort extraction of warp_chien_search_kernel metrics from NCU text."""
    metrics: dict[str, Any] = {"ncu_text_found": False}
    interesting = {
        "Duration": "ncu_chien_duration_ms",
        "Compute (SM) Throughput": "ncu_chien_compute_throughput_pct",
        "Memory Throughput": "ncu_chien_memory_throughput_pct",
        "DRAM Throughput": "ncu_chien_dram_throughput_pct",
        "SM Busy": "ncu_chien_sm_busy_pct",
        "Issue Slots Busy": "ncu_chien_issue_slots_busy_pct",
        "Achieved Occupancy": "ncu_chien_achieved_occupancy_pct",
        "Theoretical Occupancy": "ncu_chien_theoretical_occupancy_pct",
        "Registers Per Thread": "ncu_chien_registers_per_thread",
        "Waves Per SM": "ncu_chien_waves_per_sm",
    }

    for path in txt_files:
        text = path.read_text(encoding="utf-8", errors="ignore")
        if "warp_chien_search_kernel" not in text:
            continue
        metrics["ncu_text_found"] = True
        metrics["ncu_source_text"] = str(path)
        start = text.find("warp_chien_search_kernel")
        # Parse until the next kernel header or end. This is intentionally broad
        # because NCU text layout changes between versions.
        chunk = text[start : start + 50000]
        for line in chunk.splitlines():
            for label, key in interesting.items():
                if label not in line or key in metrics:
                    continue
                # Typical row: Metric Name  Metric Unit  Metric Value
                # We take the last numeric-looking token from the row.
                nums = re.findall(r"[-+]?(?:\d+\.\d+|\d+)(?:e[-+]?\d+)?", line, flags=re.I)
                if nums:
                    val = parse_number(nums[-1])
                    if val is not None:
                        metrics[key] = val
        break
    return metrics


def parse_compare(log_path: Path, param: str) -> str:
    if not log_path.exists():
        return "MISSING"
    text = log_path.read_text(encoding="utf-8", errors="ignore")
    if "COMPARE_STATUS=PASS" in text and f"[PASS] param{param} match" in text:
        return "PASS"
    if "COMPARE_STATUS=FAIL" in text or f"[FAIL] param{param}" in text:
        return "FAIL"
    return "UNKNOWN"


def preflight_reference_files(params: list[str], iter_dir: Path) -> dict[str, Any]:
    report: dict[str, Any] = {}
    for param in params:
        cpu = ROOT / "CPU" / "results" / "output" / f"errorstream0_{param}.bin"
        ct = ROOT / "kem" / "test_vectors" / "Cipher_Sk" / f"ct_{param}.bin"
        sk = ROOT / "kem" / "test_vectors" / "Cipher_Sk" / f"sk_{param}.bin"
        report[param] = {
            "cpu_errorstream_exists": cpu.exists(),
            "cpu_errorstream_path": str(cpu.relative_to(ROOT)),
            "cpu_errorstream_size_bytes": cpu.stat().st_size if cpu.exists() else None,
            "ct_exists": ct.exists(),
            "ct_path": str(ct.relative_to(ROOT)),
            "ct_size_bytes": ct.stat().st_size if ct.exists() else None,
            "sk_exists": sk.exists(),
            "sk_path": str(sk.relative_to(ROOT)),
            "sk_size_bytes": sk.stat().st_size if sk.exists() else None,
        }
    write_text(iter_dir / "preflight_reference_files.json", json.dumps(report, indent=2))
    return report


def collect_device(iter_dir: Path) -> dict[str, Any]:
    device_dir = iter_dir / "device"
    device_dir.mkdir(parents=True, exist_ok=True)

    script = ROOT / "utility" / "device_gpu_specs.sh"
    if script.exists():
        run_cmd(["sh", str(script), str(device_dir / "device_report.txt")], cwd=ROOT, log_path=device_dir / "device_report_command.log")
    else:
        write_text(device_dir / "device_report.txt", "utility/device_gpu_specs.sh not found\n")

    queries = {
        "nvidia_smi_list": ["nvidia-smi", "-L"],
        "nvidia_smi_query": [
            "nvidia-smi",
            "--query-gpu=index,name,compute_cap,driver_version,memory.total,power.limit,clocks.max.sm,clocks.max.memory",
            "--format=csv,noheader",
        ],
        "nvcc_version": ["nvcc", "--version"],
        "ncu_version": ["ncu", "--version"],
        "ncu_path": ["bash", "-lc", "command -v ncu || true"],
        "git_head": ["git", "rev-parse", "HEAD"],
        "git_branch": ["git", "branch", "--show-current"],
        "git_status": ["git", "status", "--short"],
    }
    summary = {key: capture_cmd(cmd, cwd=ROOT) for key, cmd in queries.items()}
    summary["assumptions"] = {
        "remote_system": True,
        "root_user": False,
        "sudo_allowed": False,
        "target_arch_default": ARCH_DEFAULT,
        "actual_gpu_expected": "NVIDIA GeForce RTX 3090 Ti, CC 8.6, 84 SMs",
        "nvcc_expected": "CUDA 12.8 / V12.8.61",
        "ncu_expected": "Nsight Compute 2025.1.0.0",
    }
    write_text(device_dir / "device_summary.json", json.dumps(summary, indent=2))
    return summary


def save_git_state(iter_dir: Path) -> None:
    git_dir = iter_dir / "git"
    git_dir.mkdir(parents=True, exist_ok=True)
    commands = {
        "head.txt": ["git", "rev-parse", "HEAD"],
        "branch.txt": ["git", "branch", "--show-current"],
        "status.txt": ["git", "status", "--short"],
        "diff.patch": ["git", "diff", "--patch"],
        "diff_stat.txt": ["git", "diff", "--stat"],
    }
    for name, cmd in commands.items():
        result = capture_cmd(cmd, cwd=ROOT)
        write_text(git_dir / name, result.get("output", ""))


def run_correctness(param: str, args: argparse.Namespace, iter_dir: Path) -> tuple[str, int]:
    """Build/run GPU_Optimised and compare with existing CPU output only."""
    log_dir = iter_dir / "logs" / f"param{param}"

    # Deliberately NOT `make output`, because that regenerates CPU output.
    rc_output = run_cmd(
        [
            "make",
            "gpuopt-output",
            f"PARAM={param}",
            f"KATNUM={args.katnum}",
            f"ARCH={args.arch}",
        ],
        cwd=ROOT,
        log_path=log_dir / "01_gpuopt_output_only.log",
    )
    if rc_output != 0:
        return "FAIL", rc_output

    rc_compare = run_cmd(
        ["make", "compare-opt", f"PARAM={param}"],
        cwd=ROOT,
        log_path=log_dir / "02_compare_optimised_vs_existing_cpu.log",
    )
    status = parse_compare(log_dir / "02_compare_optimised_vs_existing_cpu.log", param)
    return status, rc_compare


def run_ncu_optimised(param: str, args: argparse.Namespace, iter_dir: Path) -> tuple[str, int]:
    if args.skip_ncu:
        return "SKIP", 0
    log_dir = iter_dir / "logs" / f"param{param}"
    cmd = [
        "python3",
        "generate_ncu_reports.py",
        "--project",
        "optimised",
        "--param",
        param,
        "--katnum",
        str(args.katnum),
        "--arch",
        args.arch,
        "--skip-on-permission-error",
    ]
    rc = run_cmd(cmd, cwd=ROOT, log_path=log_dir / "03_ncu_optimised.log")
    text = (log_dir / "03_ncu_optimised.log").read_text(encoding="utf-8", errors="ignore")
    if "NCU_REPORT_STATUS=PASS" in text:
        return "PASS", rc
    if "NCU_REPORT_STATUS=SKIP" in text:
        return "SKIP", rc
    return "FAIL", rc


def collect_param_artifacts(param: str, iter_dir: Path) -> dict[str, Any]:
    out_dir = iter_dir / "outputs" / f"param{param}"
    prof_dir = iter_dir / "profiles" / f"param{param}"
    out_dir.mkdir(parents=True, exist_ok=True)
    prof_dir.mkdir(parents=True, exist_ok=True)

    artifacts: dict[str, Any] = {"param": param, "copied": []}
    files = [
        (ROOT / "CPU" / "results" / "output" / f"errorstream0_{param}.bin", out_dir / "cpu_errorstream0_reference.bin"),
        (ROOT / "GPU_Optimised" / "results" / "output" / f"errorstream0_{param}.bin", out_dir / "gpu_optimised_errorstream0.bin"),
        (ROOT / "GPU_Optimised" / "results" / "profile" / f"Profile_GPU_optimised_{param}.txt", prof_dir / "Profile_GPU_optimised.txt"),
    ]
    for src, dst in files:
        if copy_if_exists(src, dst):
            artifacts["copied"].append(str(dst.relative_to(iter_dir)))

    # Copy text summaries only. Do not copy heavy .ncu-rep files to bench/results.
    copied_ncu_txt: list[Path] = []
    for project in ["GPU_Optimised"]:
        project_profile = ROOT / project / "profile"
        if project_profile.exists():
            for src in project_profile.rglob(f"*{param}*"):
                if src.is_file() and src.suffix == ".txt":
                    dst = prof_dir / "ncu" / project / src.relative_to(project_profile)
                    if copy_if_exists(src, dst):
                        artifacts["copied"].append(str(dst.relative_to(iter_dir)))
                        copied_ncu_txt.append(dst)

    full_root = ROOT / "full_profile_txt"
    if full_root.exists():
        for src in full_root.rglob(f"*{param}*.txt"):
            if src.is_file() and "GPU_Optimised" in str(src):
                dst = prof_dir / "full_profile_txt" / src.relative_to(full_root)
                if copy_if_exists(src, dst):
                    artifacts["copied"].append(str(dst.relative_to(iter_dir)))
                    copied_ncu_txt.append(dst)

    opt_profile = prof_dir / "Profile_GPU_optimised.txt"
    artifacts["optimised_metrics"] = parse_profile(opt_profile)
    artifacts["chien_ncu_metrics"] = parse_chien_ncu_metrics(copied_ncu_txt)
    write_text(prof_dir / "metrics.json", json.dumps(artifacts, indent=2))
    return artifacts


def append_history(iter_id: str, args: argparse.Namespace, rows: list[dict[str, Any]]) -> None:
    RESULTS_ROOT.mkdir(parents=True, exist_ok=True)
    path = RESULTS_ROOT / "metrics_history.csv"
    fields = [
        "iteration_id",
        "label",
        "timestamp_utc",
        "arch",
        "param",
        "correctness_status",
        "ncu_status",
        "katnum",
        "throughput_ct_s",
        "kernel_ct_s",
        "wall_ms",
        "kernel_ms",
        "syndrome_ms",
        "bm_ms",
        "chien_ms",
        "chien_kernel_pct",
        "ncu_chien_duration_ms",
        "ncu_chien_compute_throughput_pct",
        "ncu_chien_memory_throughput_pct",
        "ncu_chien_achieved_occupancy_pct",
        "ncu_chien_registers_per_thread",
        "git_head",
    ]
    exists = path.exists()
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        if not exists:
            writer.writeheader()
        for row in rows:
            writer.writerow({k: row.get(k, "") for k in fields})


def write_summary(iter_dir: Path, summary: dict[str, Any]) -> None:
    write_text(iter_dir / "summary.json", json.dumps(summary, indent=2))
    lines = [
        f"# Iteration {summary['iteration_id']}",
        "",
        f"- Label: `{summary['label']}`",
        f"- UTC: `{summary['timestamp_utc']}`",
        f"- ARCH: `{summary['arch']}`",
        f"- KATNUM: `{summary['katnum']}`",
        f"- Params: `{','.join(summary['params'])}`",
        "- Correctness mode: `GPU_Optimised output compared against existing CPU errorstream; CPU is not rerun`",
        "- NCU mode: `non-root, optimised-only, text artifacts only`",
        "",
        "## Results",
        "",
        "| Param | Correctness | NCU | Throughput ct/s | Kernel ct/s | Chien ms | Chien % kernel | Chien regs/thread | Chien occupancy % |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for result in summary["results"]:
        artifacts = result.get("artifacts", {})
        opt = artifacts.get("optimised_metrics", {})
        ncu = artifacts.get("chien_ncu_metrics", {})
        lines.append(
            "| {param} | {correctness} | {ncu_status} | {throughput} | {kernel_cts} | {chien} | {chien_pct} | {regs} | {occ} |".format(
                param=result["param"],
                correctness=result["correctness_status"],
                ncu_status=result["ncu_status"],
                throughput=f"{opt.get('throughput_ct_s', ''):.2f}" if isinstance(opt.get("throughput_ct_s"), float) else "",
                kernel_cts=f"{opt.get('kernel_ct_s', ''):.2f}" if isinstance(opt.get("kernel_ct_s"), float) else "",
                chien=f"{opt.get('chien_ms', ''):.3f}" if isinstance(opt.get("chien_ms"), float) else "",
                chien_pct=f"{opt.get('chien_kernel_pct', ''):.2f}" if isinstance(opt.get("chien_kernel_pct"), float) else "",
                regs=f"{ncu.get('ncu_chien_registers_per_thread', ''):.0f}" if isinstance(ncu.get("ncu_chien_registers_per_thread"), float) else "",
                occ=f"{ncu.get('ncu_chien_achieved_occupancy_pct', ''):.2f}" if isinstance(ncu.get("ncu_chien_achieved_occupancy_pct"), float) else "",
            )
        )
    lines.extend(
        [
            "",
            "## Files to inspect",
            "",
            "- `codex_change.md`",
            "- `summary.json`",
            "- `preflight_reference_files.json`",
            "- `profiles/param*/metrics.json`",
            "- `logs/param*/01_gpuopt_output_only.log`",
            "- `logs/param*/02_compare_optimised_vs_existing_cpu.log`",
            "- `logs/param*/03_ncu_optimised.log`, when NCU is enabled",
            "- `device/device_report.txt` and `device/device_summary.json`",
        ]
    )
    write_text(iter_dir / "summary.md", "\n".join(lines) + "\n")


def git_output(args: list[str]) -> str:
    return capture_cmd(["git", *args], cwd=ROOT).get("output", "").strip()


def commit_changes(message: str, paths: list[str] | None, log_path: Path) -> str | None:
    if paths:
        run_cmd(["git", "add", *paths], cwd=ROOT, log_path=log_path.parent / "git_add.log")
    else:
        run_cmd(["git", "add", "-A"], cwd=ROOT, log_path=log_path.parent / "git_add.log")
    status = git_output(["status", "--short"])
    if not status:
        write_text(log_path, "No changes to commit.\n")
        return None
    rc = run_cmd(["git", "commit", "-m", message], cwd=ROOT, log_path=log_path)
    if rc != 0:
        return None
    return git_output(["rev-parse", "HEAD"])


def restore_failure_artifacts(failure_commit: str, iter_dir: Path, log_dir: Path) -> None:
    rel_iter = str(iter_dir.relative_to(ROOT))
    run_cmd(["git", "checkout", failure_commit, "--", rel_iter, "bench/results/metrics_history.csv"], cwd=ROOT, log_path=log_dir / "git_restore_failure_artifacts.log")


def maybe_commit(args: argparse.Namespace, iter_dir: Path, failed: bool) -> None:
    if not args.commit:
        return

    log_dir = iter_dir / "logs"
    rel_iter = str(iter_dir.relative_to(ROOT))
    artifact_paths = [rel_iter, "bench/results/metrics_history.csv"]

    if failed and args.failure_action == "commit-and-revert":
        failure_commit = commit_changes(
            f"bench: failed iteration {iter_dir.name}",
            None if args.commit_mode == "all" else artifact_paths,
            log_dir / "git_commit_failure.log",
        )
        if failure_commit and args.commit_mode == "all":
            run_cmd(["git", "revert", "--no-commit", failure_commit], cwd=ROOT, log_path=log_dir / "git_revert_failed_code.log")
            restore_failure_artifacts(failure_commit, iter_dir, log_dir)
            commit_changes(
                f"bench: revert failed code for {iter_dir.name} and keep logs",
                None,
                log_dir / "git_commit_revert.log",
            )
    else:
        commit_changes(
            f"bench: record {iter_dir.name}",
            None if args.commit_mode == "all" else artifact_paths,
            log_dir / "git_commit.log",
        )

    if args.push:
        run_cmd(["git", "push", "-u", "origin", "HEAD"], cwd=ROOT, log_path=log_dir / "git_push.log")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run one Codex GPU optimisation benchmark iteration")
    parser.add_argument("--label", default="iteration", help="Short human-readable iteration label")
    parser.add_argument("--params", default="all", help="Comma-separated params or all")
    parser.add_argument("--arch", default=ARCH_DEFAULT)
    parser.add_argument("--katnum", type=int, default=KATNUM_DEFAULT, help="KATNUM for GPU output and profiling")
    parser.add_argument("--codex-note-file", help="Markdown file describing what Codex changed")
    parser.add_argument("--codex-note", default="", help="Inline Markdown note describing what Codex changed")
    parser.add_argument("--skip-ncu", action="store_true", help="Skip Nsight Compute; still uses app timing profile")
    parser.add_argument("--profile-on-fail", action="store_true", help="Run NCU even if correctness comparison fails")
    parser.add_argument("--commit", action="store_true", help="Commit source/artifact changes after the run")
    parser.add_argument("--push", action="store_true", help="Push after committing")
    parser.add_argument("--commit-mode", choices=["artifacts", "all"], default="all")
    parser.add_argument("--failure-action", choices=["record-only", "commit-and-revert"], default="commit-and-revert")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    params = selected_params(args.params)
    timestamp = now_slug()
    label = safe_label(args.label)
    iter_id = f"{timestamp}_{label}"
    iter_dir = RESULTS_ROOT / iter_id
    iter_dir.mkdir(parents=True, exist_ok=True)

    note = args.codex_note
    if args.codex_note_file:
        note_path = Path(args.codex_note_file)
        if not note_path.is_absolute():
            note_path = ROOT / note_path
        if note_path.exists():
            note = note_path.read_text(encoding="utf-8", errors="ignore")
        else:
            note = f"[missing codex note file] {note_path}\n" + note
    write_text(iter_dir / "codex_change.md", note or "No Codex note supplied.\n")

    collect_device(iter_dir)
    save_git_state(iter_dir)
    preflight_reference_files(params, iter_dir)

    results: list[dict[str, Any]] = []
    history_rows: list[dict[str, Any]] = []
    git_head = (iter_dir / "git" / "head.txt").read_text(encoding="utf-8", errors="ignore").strip()

    for param in params:
        correctness_status, correctness_rc = run_correctness(param, args, iter_dir)
        ncu_status = "SKIP"
        ncu_rc: int | None = None
        if correctness_status == "PASS" or args.profile_on_fail:
            ncu_status, ncu_rc = run_ncu_optimised(param, args, iter_dir)
        artifacts = collect_param_artifacts(param, iter_dir)
        result = {
            "param": param,
            "correctness_status": correctness_status,
            "correctness_returncode": correctness_rc,
            "ncu_status": ncu_status,
            "ncu_returncode": ncu_rc,
            "artifacts": artifacts,
        }
        results.append(result)

        opt = artifacts.get("optimised_metrics", {})
        ncu = artifacts.get("chien_ncu_metrics", {})
        history_rows.append(
            {
                "iteration_id": iter_id,
                "label": label,
                "timestamp_utc": timestamp,
                "arch": args.arch,
                "param": param,
                "correctness_status": correctness_status,
                "ncu_status": ncu_status,
                "katnum": args.katnum,
                "throughput_ct_s": opt.get("throughput_ct_s", ""),
                "kernel_ct_s": opt.get("kernel_ct_s", ""),
                "wall_ms": opt.get("wall_ms", ""),
                "kernel_ms": opt.get("kernel_ms", ""),
                "syndrome_ms": opt.get("syndrome_ms", ""),
                "bm_ms": opt.get("bm_ms", ""),
                "chien_ms": opt.get("chien_ms", ""),
                "chien_kernel_pct": opt.get("chien_kernel_pct", ""),
                "ncu_chien_duration_ms": ncu.get("ncu_chien_duration_ms", ""),
                "ncu_chien_compute_throughput_pct": ncu.get("ncu_chien_compute_throughput_pct", ""),
                "ncu_chien_memory_throughput_pct": ncu.get("ncu_chien_memory_throughput_pct", ""),
                "ncu_chien_achieved_occupancy_pct": ncu.get("ncu_chien_achieved_occupancy_pct", ""),
                "ncu_chien_registers_per_thread": ncu.get("ncu_chien_registers_per_thread", ""),
                "git_head": git_head,
            }
        )

    append_history(iter_id, args, history_rows)
    summary = {
        "iteration_id": iter_id,
        "label": label,
        "timestamp_utc": timestamp,
        "arch": args.arch,
        "katnum": args.katnum,
        "params": params,
        "skip_ncu": args.skip_ncu,
        "commit_mode": args.commit_mode,
        "failure_action": args.failure_action,
        "results": results,
    }
    write_summary(iter_dir, summary)

    failed = any(r["correctness_status"] != "PASS" or r["ncu_status"] == "FAIL" for r in results)
    maybe_commit(args, iter_dir, failed)

    print(f"\nIteration artifacts: {iter_dir.relative_to(ROOT)}")
    print(f"Summary: {iter_dir.relative_to(ROOT) / 'summary.md'}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
