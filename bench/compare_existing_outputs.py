#!/usr/bin/env python3
"""Compare existing CPU and GPU_Optimised .bin outputs without regenerating anything.

Use this when CPU and GPU output files are already generated and known to be the
correct inputs for an optimisation iteration. This script deliberately does not
run make, nvcc, CPU reference code, GPU binaries, or Nsight Compute.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
RESULTS_ROOT = ROOT / "bench" / "results"
PARAMS_ALL = ["348864", "460896", "6688128", "6960119", "8192128"]


def now_slug() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def safe_label(label: str) -> str:
    keep = []
    for ch in label.strip():
        keep.append(ch if ch.isalnum() or ch in "._-" else "-")
    cleaned = "".join(keep).strip("-._")
    return cleaned or "compare-existing"


def selected_params(value: str) -> list[str]:
    if value.strip() == "all":
        return PARAMS_ALL[:]
    params = [p.strip() for p in value.split(",") if p.strip()]
    bad = [p for p in params if p not in PARAMS_ALL]
    if bad:
        raise SystemExit(f"Unsupported params: {','.join(bad)}")
    return params


def write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")


def capture(cmd: list[str]) -> dict[str, Any]:
    try:
        proc = subprocess.run(cmd, cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, check=False)
        return {"cmd": cmd, "returncode": proc.returncode, "output": proc.stdout}
    except FileNotFoundError as exc:
        return {"cmd": cmd, "returncode": 127, "output": str(exc)}


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(chunk_size)
            if not chunk:
                break
            h.update(chunk)
    return h.hexdigest()


def first_mismatch(a: Path, b: Path, chunk_size: int = 1024 * 1024) -> int | None:
    offset = 0
    with a.open("rb") as fa, b.open("rb") as fb:
        while True:
            ca = fa.read(chunk_size)
            cb = fb.read(chunk_size)
            if ca == cb:
                if not ca:
                    return None
                offset += len(ca)
                continue
            limit = min(len(ca), len(cb))
            for i in range(limit):
                if ca[i] != cb[i]:
                    return offset + i
            return offset + limit


def compare_param(param: str) -> dict[str, Any]:
    cpu = ROOT / "CPU" / "results" / "output" / f"errorstream0_{param}.bin"
    gpu = ROOT / "GPU_Optimised" / "results" / "output" / f"errorstream0_{param}.bin"
    result: dict[str, Any] = {
        "param": param,
        "cpu_path": str(cpu.relative_to(ROOT)),
        "gpu_path": str(gpu.relative_to(ROOT)),
        "cpu_exists": cpu.exists(),
        "gpu_exists": gpu.exists(),
        "status": "FAIL",
    }
    if not cpu.exists() or not gpu.exists():
        result["reason"] = "missing_file"
        return result

    cpu_size = cpu.stat().st_size
    gpu_size = gpu.stat().st_size
    result["cpu_size_bytes"] = cpu_size
    result["gpu_size_bytes"] = gpu_size
    result["size_match"] = cpu_size == gpu_size
    result["cpu_sha256"] = sha256_file(cpu)
    result["gpu_sha256"] = sha256_file(gpu)
    result["sha256_match"] = result["cpu_sha256"] == result["gpu_sha256"]

    if result["sha256_match"]:
        result["status"] = "PASS"
        result["reason"] = "byte_identical"
    else:
        result["reason"] = "content_mismatch"
        result["first_mismatch_offset"] = first_mismatch(cpu, gpu)
    return result


def append_history(iter_id: str, label: str, timestamp: str, arch: str, katnum: int, rows: list[dict[str, Any]]) -> None:
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
    git_head = capture(["git", "rev-parse", "HEAD"]).get("output", "").strip()
    with path.open("a", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        if not exists:
            writer.writeheader()
        for row in rows:
            writer.writerow(
                {
                    "iteration_id": iter_id,
                    "label": label,
                    "timestamp_utc": timestamp,
                    "arch": arch,
                    "param": row["param"],
                    "correctness_status": row["status"],
                    "ncu_status": "NOT_RUN_COMPARE_ONLY",
                    "katnum": katnum,
                    "git_head": git_head,
                }
            )


def write_summary(iter_dir: Path, summary: dict[str, Any]) -> None:
    lines = [
        f"# Iteration {summary['iteration_id']}",
        "",
        f"- Label: `{summary['label']}`",
        f"- UTC: `{summary['timestamp_utc']}`",
        f"- Mode: `compare-existing-only`",
        f"- ARCH metadata: `{summary['arch']}`",
        f"- KATNUM metadata: `{summary['katnum']}`",
        "- Action: `direct byte comparison of existing CPU/GPU_Optimised .bin files`",
        "- No CPU run, no GPU run, no make target, no nvcc, no ncu.",
        "",
        "## Results",
        "",
        "| Param | Correctness | CPU bytes | GPU bytes | SHA256 match | First mismatch offset |",
        "|---|---:|---:|---:|---:|---:|",
    ]
    for row in summary["results"]:
        lines.append(
            "| {param} | {status} | {cpu_size} | {gpu_size} | {sha_match} | {offset} |".format(
                param=row["param"],
                status=row["status"],
                cpu_size=row.get("cpu_size_bytes", ""),
                gpu_size=row.get("gpu_size_bytes", ""),
                sha_match=row.get("sha256_match", ""),
                offset=row.get("first_mismatch_offset", ""),
            )
        )
    lines.extend(
        [
            "",
            "## Files",
            "",
            "- `summary.json`",
            "- `compare_existing_outputs.json`",
            "- `device_git_context.json`",
            "- `bench/results/metrics_history.csv`",
        ]
    )
    write_text(iter_dir / "summary.md", "\n".join(lines) + "\n")


def maybe_commit_and_push(args: argparse.Namespace, iter_dir: Path) -> None:
    if not args.commit:
        return
    paths = [str(iter_dir.relative_to(ROOT)), "bench/results/metrics_history.csv"]
    subprocess.run(["git", "add", *paths], cwd=str(ROOT), check=False)
    subprocess.run(["git", "commit", "-m", f"bench: compare existing outputs {iter_dir.name}"], cwd=str(ROOT), check=False)
    if args.push:
        subprocess.run(["git", "push", "-u", "origin", "HEAD"], cwd=str(ROOT), check=False)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Compare existing CPU/GPU_Optimised output .bin files")
    parser.add_argument("--label", default="compare-existing")
    parser.add_argument("--params", default="all")
    parser.add_argument("--arch", default="sm_75", help="metadata only; no build is run")
    parser.add_argument("--katnum", type=int, default=50000, help="metadata only; no generation is run")
    parser.add_argument("--commit", action="store_true")
    parser.add_argument("--push", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    params = selected_params(args.params)
    timestamp = now_slug()
    label = safe_label(args.label)
    iter_id = f"{timestamp}_{label}"
    iter_dir = RESULTS_ROOT / iter_id
    iter_dir.mkdir(parents=True, exist_ok=True)

    results = [compare_param(param) for param in params]
    context = {
        "git_head": capture(["git", "rev-parse", "HEAD"]),
        "git_branch": capture(["git", "branch", "--show-current"]),
        "git_status": capture(["git", "status", "--short"]),
        "nvidia_smi": capture(["nvidia-smi", "-L"]),
        "nvcc_version": capture(["nvcc", "--version"]),
        "ncu_version": capture(["ncu", "--version"]),
    }
    summary = {
        "iteration_id": iter_id,
        "label": label,
        "timestamp_utc": timestamp,
        "mode": "compare-existing-only",
        "arch": args.arch,
        "katnum": args.katnum,
        "params": params,
        "results": results,
    }
    write_text(iter_dir / "compare_existing_outputs.json", json.dumps(results, indent=2))
    write_text(iter_dir / "device_git_context.json", json.dumps(context, indent=2))
    write_text(iter_dir / "summary.json", json.dumps(summary, indent=2))
    write_summary(iter_dir, summary)
    append_history(iter_id, label, timestamp, args.arch, args.katnum, results)

    maybe_commit_and_push(args, iter_dir)

    print(f"Summary: {iter_dir.relative_to(ROOT) / 'summary.md'}")
    failed = [row for row in results if row["status"] != "PASS"]
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
