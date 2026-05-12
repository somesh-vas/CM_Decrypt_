#!/usr/bin/env python3
"""Run one correctness/profile iteration for Codex GPU optimization.

This script is intentionally a thin orchestration layer around the existing
project Makefiles and profiling utilities. It does not replace the current
`make full-profile` flow; it records every attempt in a stable artifact layout
so performance changes can be compared across iterations.
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
RESULTS_ROOT = ROOT / "bench" / "results"
PARAMS_DEFAULT = ["348864", "6960119"]
ARCH_DEFAULT = "sm_75"


def now_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def safe_label(label: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_.-]+", "-", label.strip())
    cleaned = cleaned.strip("-._")
    return cleaned or "iteration"


def run_cmd(cmd: list[str], *, cwd: Path, log_path: Path, allow_fail: bool = True) -> int:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as handle:
        handle.write("$ " + " ".join(cmd) + "\n\n")
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
    if not src.exists():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    return True


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
        m = re.search(pattern, text)
        if not m:
            continue
        value = m.group(1)
        data[key] = int(value) if key in {"ciphertexts", "batch_size"} else float(value)
    if all(k in data for k in ["syndrome_ms", "bm_ms", "chien_ms"]):
        kernel_ms = data["syndrome_ms"] + data["bm_ms"] + data["chien_ms"]
        data["kernel_ms"] = kernel_ms
        data["chien_kernel_pct"] = (100.0 * data["chien_ms"] / kernel_ms) if kernel_ms > 0 else None
    return data


def parse_compare(log_path: Path, param: str) -> str:
    if not log_path.exists():
        return "MISSING"
    text = log_path.read_text(encoding="utf-8", errors="ignore")
    if "COMPARE_STATUS=PASS" in text and f"[PASS] param{param} match" in text:
        return "PASS"
    if "COMPARE_STATUS=FAIL" in text or f"[FAIL] param{param}" in text:
        return "FAIL"
    return "UNKNOWN"


def collect_device(iter_dir: Path) -> dict[str, Any]:
    device_dir = iter_dir / "device"
    device_dir.mkdir(parents=True, exist_ok=True)

    report_path = device_dir / "device_report.txt"
    script = ROOT / "utility" / "device_gpu_specs.sh"
    if script.exists():
        run_cmd(["sh", str(script), str(report_path)], cwd=ROOT, log_path=device_dir / "device_report_command.log")
    else:
        write_text(report_path, "utility/device_gpu_specs.sh not found\n")

    queries = {
        "nvidia_smi_list": ["nvidia-smi", "-L"],
        "nvidia_smi_query": [
            "nvidia-smi",
            "--query-gpu=index,name,compute_cap,driver_version,memory.total,power.limit,clocks.max.sm,clocks.max.memory",
            "--format=csv,noheader",
        ],
        "nvcc_version": ["nvcc", "--version"],
        "ncu_version": ["ncu", "--version"],
        "git_head": ["git", "rev-parse", "HEAD"],
        "git_branch": ["git", "branch", "--show-current"],
    }
    summary = {key: capture_cmd(cmd, cwd=ROOT) for key, cmd in queries.items()}
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


def selected_params(value: str) -> list[str]:
    if value.strip() == "all":
        return ["348864", "460896", "6688128", "6960119", "8192128"]
    params = [p.strip() for p in value.split(",") if p.strip()]
    valid = {"348864", "460896", "6688128", "6960119", "8192128"}
    bad = [p for p in params if p not in valid]
    if bad:
        raise SystemExit(f"Unsupported params: {','.join(bad)}")
    return params


def run_correctness(param: str, args: argparse.Namespace, iter_dir: Path) -> tuple[str, int]:
    log_dir = iter_dir / "logs" / f"param{param}"
    rc_output = run_cmd(
        [
            "make",
            "output",
            f"PARAM={param}",
            f"KATNUM={args.correctness_katnum}",
            f"ARCH={args.arch}",
        ],
        cwd=ROOT,
        log_path=log_dir / "01_make_output.log",
    )
    if rc_output != 0:
        return "FAIL", rc_output

    rc_compare = run_cmd(
        ["make", "compare-opt", f"PARAM={param}"],
        cwd=ROOT,
        log_path=log_dir / "02_compare_optimised.log",
    )
    status = parse_compare(log_dir / "02_compare_optimised.log", param)
    return status, rc_compare


def run_profile(param: str, args: argparse.Namespace, iter_dir: Path) -> int:
    log_dir = iter_dir / "logs" / f"param{param}"
    cmd = [
        "make",
        "full-profile",
        f"PARAM={param}",
        f"KATNUM={args.profile_katnum}",
        f"ARCH={args.arch}",
    ]
    if args.skip_ncu:
        cmd.append("SKIP_NCU=1")
    if args.sudo:
        cmd.append("SUDO=1")
    return run_cmd(cmd, cwd=ROOT, log_path=log_dir / "03_full_profile.log")


def collect_param_artifacts(param: str, iter_dir: Path) -> dict[str, Any]:
    out_dir = iter_dir / "outputs" / f"param{param}"
    prof_dir = iter_dir / "profiles" / f"param{param}"
    out_dir.mkdir(parents=True, exist_ok=True)
    prof_dir.mkdir(parents=True, exist_ok=True)

    artifacts: dict[str, Any] = {"param": param, "copied": []}
    files = [
        (ROOT / "CPU" / "results" / "output" / f"errorstream0_{param}.bin", out_dir / "cpu_errorstream0.bin"),
        (ROOT / "GPU_Optimised" / "results" / "output" / f"errorstream0_{param}.bin", out_dir / "gpu_optimised_errorstream0.bin"),
        (ROOT / "GPU_Optimised" / "results" / "profile" / f"Profile_GPU_optimised_{param}.txt", prof_dir / "Profile_GPU_optimised.txt"),
        (ROOT / "GPU_Baseline" / "results" / "profile" / f"Profile_GPU_baseline_{param}.txt", prof_dir / "Profile_GPU_baseline.txt"),
        (ROOT / "CPU" / "results" / "profile" / f"Profile_CPU_{param}.txt", prof_dir / "Profile_CPU.txt"),
    ]
    for src, dst in files:
        if copy_if_exists(src, dst):
            artifacts["copied"].append(str(dst.relative_to(iter_dir)))

    # Copy current full-profile text tree for this param, if present.
    full_root = ROOT / "full_profile_txt"
    if full_root.exists():
        for src in full_root.rglob(f"*{param}*"):
            if src.is_file():
                rel = src.relative_to(full_root)
                dst = prof_dir / "full_profile_txt" / rel
                if copy_if_exists(src, dst):
                    artifacts["copied"].append(str(dst.relative_to(iter_dir)))

    # Copy Nsight Compute details for this param from project-local profile dirs.
    for project in ["GPU_Optimised", "GPU_Baseline"]:
        project_profile = ROOT / project / "profile"
        if project_profile.exists():
            for src in project_profile.rglob(f"*{param}*"):
                if src.is_file() and src.suffix in {".txt", ".ncu-rep"}:
                    dst = prof_dir / "ncu" / project / src.relative_to(project_profile)
                    if copy_if_exists(src, dst):
                        artifacts["copied"].append(str(dst.relative_to(iter_dir)))

    opt_profile = prof_dir / "Profile_GPU_optimised.txt"
    base_profile = prof_dir / "Profile_GPU_baseline.txt"
    artifacts["optimised_metrics"] = parse_profile(opt_profile)
    artifacts["baseline_metrics"] = parse_profile(base_profile)
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
        "profile_status",
        "profile_katnum",
        "throughput_ct_s",
        "wall_ms",
        "kernel_ms",
        "syndrome_ms",
        "bm_ms",
        "chien_ms",
        "chien_kernel_pct",
        "baseline_throughput_ct_s",
        "baseline_chien_ms",
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
    lines = []
    lines.append(f"# Iteration {summary['iteration_id']}")
    lines.append("")
    lines.append(f"- Label: `{summary['label']}`")
    lines.append(f"- UTC: `{summary['timestamp_utc']}`")
    lines.append(f"- ARCH: `{summary['arch']}`")
    lines.append(f"- Params: `{','.join(summary['params'])}`")
    lines.append(f"- Correctness KATNUM: `{summary['correctness_katnum']}`")
    lines.append(f"- Profile KATNUM: `{summary['profile_katnum']}`")
    lines.append("")
    lines.append("## Results")
    lines.append("")
    lines.append("| Param | Correctness | Profile | Throughput ct/s | Chien ms | Chien % kernel |")
    lines.append("|---|---:|---:|---:|---:|---:|")
    for p in summary["results"]:
        m = p.get("artifacts", {}).get("optimised_metrics", {})
        lines.append(
            "| {param} | {correctness} | {profile} | {throughput} | {chien} | {chien_pct} |".format(
                param=p["param"],
                correctness=p["correctness_status"],
                profile=p["profile_status"],
                throughput=f"{m.get('throughput_ct_s', ''):.2f}" if isinstance(m.get("throughput_ct_s"), float) else "",
                chien=f"{m.get('chien_ms', ''):.3f}" if isinstance(m.get("chien_ms"), float) else "",
                chien_pct=f"{m.get('chien_kernel_pct', ''):.2f}" if isinstance(m.get("chien_kernel_pct"), float) else "",
            )
        )
    lines.append("")
    lines.append("## Files to inspect")
    lines.append("")
    lines.append("- `codex_change.md`")
    lines.append("- `summary.json`")
    lines.append("- `profiles/param*/metrics.json`")
    lines.append("- `logs/param*/01_make_output.log`")
    lines.append("- `logs/param*/02_compare_optimised.log`")
    lines.append("- `logs/param*/03_full_profile.log`, when profiling ran")
    lines.append("- `device/device_report.txt`")
    write_text(iter_dir / "summary.md", "\n".join(lines) + "\n")


def maybe_commit(args: argparse.Namespace, iter_dir: Path) -> None:
    if not args.commit:
        return
    paths = [str(iter_dir.relative_to(ROOT)), "bench/results/metrics_history.csv"]
    if args.commit_mode == "all":
        run_cmd(["git", "add", "-A"], cwd=ROOT, log_path=iter_dir / "logs" / "git_add.log")
    else:
        run_cmd(["git", "add", *paths], cwd=ROOT, log_path=iter_dir / "logs" / "git_add.log")
    run_cmd(
        ["git", "commit", "-m", f"bench: record {iter_dir.name}"],
        cwd=ROOT,
        log_path=iter_dir / "logs" / "git_commit.log",
    )
    if args.push:
        run_cmd(["git", "push"], cwd=ROOT, log_path=iter_dir / "logs" / "git_push.log")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run one Codex GPU optimization benchmark iteration")
    parser.add_argument("--label", default="iteration", help="Short human-readable iteration label")
    parser.add_argument("--params", default=",".join(PARAMS_DEFAULT), help="Comma-separated params or all")
    parser.add_argument("--arch", default=ARCH_DEFAULT)
    parser.add_argument("--correctness-katnum", type=int, default=5)
    parser.add_argument("--profile-katnum", type=int, default=50000)
    parser.add_argument("--codex-note-file", help="Markdown file describing what Codex changed")
    parser.add_argument("--codex-note", default="", help="Inline Markdown note describing what Codex changed")
    parser.add_argument("--skip-ncu", action="store_true", help="Run full-profile with SKIP_NCU=1")
    parser.add_argument("--sudo", action="store_true", help="Allow full-profile to pass SUDO=1 for NCU")
    parser.add_argument("--profile-on-fail", action="store_true", help="Profile even if correctness comparison fails")
    parser.add_argument("--commit", action="store_true", help="Commit benchmark artifacts after the run")
    parser.add_argument("--push", action="store_true", help="Push after committing")
    parser.add_argument("--commit-mode", choices=["artifacts", "all"], default="artifacts")
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

    results: list[dict[str, Any]] = []
    history_rows: list[dict[str, Any]] = []
    git_head = (iter_dir / "git" / "head.txt").read_text(encoding="utf-8", errors="ignore").strip()

    for param in params:
        correctness_status, correctness_rc = run_correctness(param, args, iter_dir)
        profile_rc: int | None = None
        profile_status = "SKIP"
        if correctness_status == "PASS" or args.profile_on_fail:
            profile_rc = run_profile(param, args, iter_dir)
            profile_status = "PASS" if profile_rc == 0 else "FAIL"
        artifacts = collect_param_artifacts(param, iter_dir)
        result = {
            "param": param,
            "correctness_status": correctness_status,
            "correctness_returncode": correctness_rc,
            "profile_status": profile_status,
            "profile_returncode": profile_rc,
            "artifacts": artifacts,
        }
        results.append(result)

        opt = artifacts.get("optimised_metrics", {})
        base = artifacts.get("baseline_metrics", {})
        history_rows.append(
            {
                "iteration_id": iter_id,
                "label": label,
                "timestamp_utc": timestamp,
                "arch": args.arch,
                "param": param,
                "correctness_status": correctness_status,
                "profile_status": profile_status,
                "profile_katnum": args.profile_katnum,
                "throughput_ct_s": opt.get("throughput_ct_s", ""),
                "wall_ms": opt.get("wall_ms", ""),
                "kernel_ms": opt.get("kernel_ms", ""),
                "syndrome_ms": opt.get("syndrome_ms", ""),
                "bm_ms": opt.get("bm_ms", ""),
                "chien_ms": opt.get("chien_ms", ""),
                "chien_kernel_pct": opt.get("chien_kernel_pct", ""),
                "baseline_throughput_ct_s": base.get("throughput_ct_s", ""),
                "baseline_chien_ms": base.get("chien_ms", ""),
                "git_head": git_head,
            }
        )

    append_history(iter_id, args, history_rows)

    summary = {
        "iteration_id": iter_id,
        "label": label,
        "timestamp_utc": timestamp,
        "arch": args.arch,
        "params": params,
        "correctness_katnum": args.correctness_katnum,
        "profile_katnum": args.profile_katnum,
        "skip_ncu": args.skip_ncu,
        "results": results,
    }
    write_summary(iter_dir, summary)

    maybe_commit(args, iter_dir)

    print(f"\nIteration artifacts: {iter_dir.relative_to(ROOT)}")
    print(f"Summary: {iter_dir.relative_to(ROOT) / 'summary.md'}")
    failed = [r for r in results if r["correctness_status"] != "PASS" or r["profile_status"] == "FAIL"]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
