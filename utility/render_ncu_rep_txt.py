#!/usr/bin/env python3
"""Render human-readable `.txt` reports from existing Nsight Compute `.ncu-rep` files.

Examples:
    python3 utility/render_ncu_rep_txt.py
    python3 utility/render_ncu_rep_txt.py --project baseline --param 6688128
    python3 utility/render_ncu_rep_txt.py \
        GPU_Baseline/profile/ncu-rep/Profile_baseline_6688128_KAT10_sm_86.ncu-rep
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PARAMS = ["348864", "460896", "6688128", "6960119", "8192128"]
PROJECTS = {
    "baseline": {
        "rep_dir": ROOT / "GPU_Baseline" / "profile" / "ncu-rep",
        "log_dir": ROOT / "GPU_Baseline" / "profile" / "logs",
    },
    "optimised": {
        "rep_dir": ROOT / "GPU_Optimised" / "profile" / "ncu-rep",
        "log_dir": ROOT / "GPU_Optimised" / "profile" / "logs",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Render detailed text reports from existing Nsight Compute `.ncu-rep` files."
    )
    parser.add_argument(
        "paths",
        nargs="*",
        help="Specific `.ncu-rep` files or directories to scan. If omitted, scan project profile/ncu-rep folders.",
    )
    parser.add_argument(
        "--project",
        choices=["baseline", "optimised", "both"],
        default="both",
        help="Project scope when scanning default folders.",
    )
    parser.add_argument(
        "--param",
        default="all",
        help="Optional parameter filter when scanning default folders.",
    )
    parser.add_argument(
        "--katnum",
        type=int,
        help="Optional KATNUM filter when scanning default folders.",
    )
    parser.add_argument(
        "--arch",
        help="Optional architecture filter when scanning default folders, for example sm_86.",
    )
    parser.add_argument(
        "--ncu",
        default=shutil.which("ncu") or "/usr/local/cuda/bin/ncu",
        help="Path to the `ncu` executable.",
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Write all rendered `.txt` files into this directory instead of the project log directories.",
    )
    parser.add_argument(
        "--name-suffix",
        default="",
        help="Suffix appended before `.txt` in the preferred output filename, for example `_full_profile`.",
    )
    parser.add_argument(
        "--suffix",
        default="_details",
        help="Suffix appended before `.txt` when not overwriting the preferred output name.",
    )
    parser.add_argument(
        "--overwrite",
        action="store_true",
        help="Overwrite the preferred `<report>.txt` when it is writable.",
    )
    args = parser.parse_args()

    if args.param != "all" and args.param not in PARAMS:
        parser.error("--param must be `all` or one of: " + ",".join(PARAMS))

    if args.katnum is not None and args.katnum <= 0:
        parser.error("--katnum must be > 0")

    return args


def scan_default_reports(args: argparse.Namespace) -> list[Path]:
    if args.project == "both":
        projects = ("baseline", "optimised")
    else:
        projects = (args.project,)

    reports: list[Path] = []
    for project in projects:
        rep_dir = PROJECTS[project]["rep_dir"]
        if not rep_dir.exists():
            continue
        for rep_file in sorted(rep_dir.glob("*.ncu-rep")):
            stem = rep_file.stem
            if args.param != "all" and f"_{args.param}_" not in stem:
                continue
            if args.katnum is not None and f"_KAT{args.katnum}_" not in stem:
                continue
            if args.arch and f"_{args.arch}" not in stem:
                continue
            reports.append(rep_file)
    return reports


def expand_report_paths(paths: list[str]) -> list[Path]:
    reports: list[Path] = []
    for raw_path in paths:
        path = Path(raw_path)
        if path.is_dir():
            reports.extend(sorted(path.rglob("*.ncu-rep")))
        elif path.is_file() and path.suffix == ".ncu-rep":
            reports.append(path)
        else:
            raise FileNotFoundError(f"Not a `.ncu-rep` file or directory: {path}")
    return reports


def build_ncu_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PYTHONNOUSERSITE"] = "1"
    env["PYTHONUTF8"] = "1"
    env["LANG"] = "C.UTF-8"
    env["LC_ALL"] = "C.UTF-8"
    return env


def default_output_dir_for(rep_file: Path) -> Path:
    resolved = rep_file.resolve()
    for project_info in PROJECTS.values():
        rep_dir = project_info["rep_dir"].resolve()
        if resolved.parent == rep_dir:
            return project_info["log_dir"]
    return rep_file.parent


def resolve_output_path(rep_file: Path, args: argparse.Namespace) -> Path:
    output_dir = args.output_dir if args.output_dir is not None else default_output_dir_for(rep_file)
    output_dir.mkdir(parents=True, exist_ok=True)

    preferred = output_dir / f"{rep_file.stem}{args.name_suffix}.txt"
    if args.overwrite and (not preferred.exists() or os.access(preferred, os.W_OK)):
        return preferred

    if not preferred.exists():
        return preferred

    return output_dir / f"{rep_file.stem}{args.suffix}.txt"


def render_report(ncu_path: str, rep_file: Path, output_file: Path) -> int:
    cmd = [
        ncu_path,
        "--import",
        str(rep_file),
        "--page",
        "details",
        "--print-details",
        "all",
        "--print-summary",
        "per-kernel",
        "--print-rule-details",
        "--print-metric-name",
        "label-name",
        "--print-units",
        "base",
        "--print-fp",
    ]

    proc = subprocess.Popen(
        cmd,
        cwd=str(ROOT),
        env=build_ncu_env(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None

    with output_file.open("w", encoding="utf-8") as handle:
        for line in proc.stdout:
            print(line, end="")
            handle.write(line)

    return proc.wait()


def main() -> int:
    args = parse_args()

    try:
        reports = expand_report_paths(args.paths) if args.paths else scan_default_reports(args)
    except FileNotFoundError as exc:
        print(str(exc), file=sys.stderr)
        return 2

    unique_reports = sorted({report.resolve() for report in reports})
    if not unique_reports:
        print("No `.ncu-rep` files matched the requested selection.", file=sys.stderr)
        return 1

    if not shutil.which(args.ncu) and not Path(args.ncu).exists():
        print(f"`ncu` not found: {args.ncu}", file=sys.stderr)
        return 1

    failures = 0
    for rep_file in unique_reports:
        output_file = resolve_output_path(rep_file, args)
        print(f"===== Importing {rep_file} =====")
        print(f"[INFO] output: {output_file}")
        rc = render_report(args.ncu, rep_file, output_file)
        if rc != 0:
            print(f"[FAIL] import failed for {rep_file}")
            failures = 1
        else:
            print(f"[PASS] text report: {output_file}")

    return failures


if __name__ == "__main__":
    raise SystemExit(main())
