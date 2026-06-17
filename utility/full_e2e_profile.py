#!/usr/bin/env python3
"""Run the full CPU/GPU validation and profiling flow in one place.

This utility performs the same end-to-end steps people currently run by hand:
- optional `make clean`
- `make output` to regenerate CPU/GPU result `.txt` files and errorstreams
- CPU vs GPU baseline compare
- CPU vs GPU optimised compare
- Nsight Compute report generation for baseline and optimised GPU builds
- copying CPU/GPU profile `.txt` files and Nsight `--log-file` `.txt` files
  into `full_profile_txt/CPU/`, `full_profile_txt/GPU_Baseline/`, and
  `full_profile_txt/GPU_Optimised/`

The `.ncu-rep` files remain in the project-local `profile/ncu-rep/` folders,
and the summary written under `full_profile_txt/summary/` lists their paths.
"""

from __future__ import annotations

import argparse
import os
import shlex
import shutil
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from uuid import uuid4


ROOT = Path(__file__).resolve().parent.parent
FULL_PROFILE_ROOT = ROOT / "full_profile_txt"
OWNERSHIP_BACKUP_ROOT = Path.home() / ".cache" / "cm_decrypt_root_owned_backup"
PARAMS = ["348864", "460896", "6688128", "6960119", "8192128"]
DEFAULT_KATNUM = 5
FULL_PROFILE_PROJECT_DIRS = {
    "CPU": FULL_PROFILE_ROOT / "CPU",
    "GPU_Baseline": FULL_PROFILE_ROOT / "GPU_Baseline",
    "GPU_Optimised": FULL_PROFILE_ROOT / "GPU_Optimised",
}


@dataclass
class StepResult:
    name: str
    cmd: list[str]
    log_path: Path
    returncode: int
    status: str


def detect_step_status(log_path: Path, returncode: int) -> str:
    """Classify a step as PASS/FAIL/SKIP from its log markers and exit code."""
    status = None
    try:
        for line in log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            if line.startswith("NCU_REPORT_STATUS="):
                status = line.split("=", 1)[1].strip()
    except OSError:
        status = None

    if status in {"PASS", "FAIL", "SKIP"}:
        return status

    return "PASS" if returncode == 0 else "FAIL"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Run full end-to-end validation and profiling for the CM workspace."
    )
    parser.add_argument(
        "--param",
        default="all",
        help="all or one of: 348864,460896,6688128,6960119,8192128",
    )
    parser.add_argument(
        "--katnum",
        type=int,
        help="Ciphertexts per run. If omitted, the script asks at runtime.",
    )
    parser.add_argument("--arch", default="sm_86", help="CUDA architecture, for example sm_86")
    parser.add_argument(
        "--ncu",
        default=shutil.which("ncu") or "/usr/local/cuda/bin/ncu",
        help="Path to Nsight Compute",
    )
    parser.add_argument(
        "--sudo",
        action="store_true",
        help="Allow generate_ncu_reports.py to use interactive sudo if profiling requires admin access",
    )
    parser.add_argument(
        "--skip-clean",
        action="store_true",
        help="Do not run `make clean` before the end-to-end flow",
    )
    parser.add_argument(
        "--skip-ncu",
        action="store_true",
        help="Skip Nsight Compute report generation",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the commands that would run without executing them",
    )
    args = parser.parse_args()

    if args.katnum is not None and args.katnum <= 0:
        parser.error("--katnum must be > 0")

    if args.param != "all" and args.param not in PARAMS:
        parser.error("--param must be `all` or one of: " + ",".join(PARAMS))

    return args


def selected_params(param_arg: str) -> list[str]:
    return PARAMS if param_arg == "all" else [param_arg]


def resolve_katnum(katnum: int | None) -> int:
    if katnum is not None:
        return katnum

    if not sys.stdin.isatty():
        raise SystemExit(
            "KATNUM was not provided. Re-run with --katnum <n> or launch from an interactive terminal."
        )

    while True:
        raw = input(f"Enter KATNUM [{DEFAULT_KATNUM}]: ").strip()
        if not raw:
            return DEFAULT_KATNUM
        if raw.isdigit() and int(raw) > 0:
            return int(raw)
        print("Please enter a positive integer for KATNUM.")


def ensure_log_dir(path: Path, dry_run: bool) -> None:
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)


def run_cmd(
    name: str,
    cmd: list[str],
    log_path: Path,
    *,
    dry_run: bool,
) -> StepResult:
    ensure_log_dir(log_path, dry_run)
    print(f"$ {' '.join(shlex.quote(part) for part in cmd)}")

    if dry_run:
        return StepResult(name=name, cmd=cmd, log_path=log_path, returncode=0, status="PASS")

    with log_path.open("w", encoding="utf-8") as log_file:
        log_file.write(f"$ {' '.join(shlex.quote(part) for part in cmd)}\n\n")

        proc = subprocess.Popen(
            cmd,
            cwd=str(ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        assert proc.stdout is not None

        for line in proc.stdout:
            print(line, end="")
            log_file.write(line)

        rc = proc.wait()
        log_file.write(f"\n[exit code: {rc}]\n")

    return StepResult(
        name=name,
        cmd=cmd,
        log_path=log_path,
        returncode=rc,
        status=detect_step_status(log_path, rc),
    )


def mirror_txt_dir(src_dir: Path, dest_dir: Path, *, mirror_root: Path, dry_run: bool) -> list[Path]:
    copied: list[Path] = []
    if not src_dir.exists():
        return copied

    for src_file in sorted(src_dir.rglob("*.txt")):
        dest_file = dest_dir / src_file.relative_to(src_dir)
        copied.append(dest_file)
        if dry_run:
            continue
        ensure_mirror_dir_writable(dest_file.parent, mirror_root=mirror_root)
        shutil.copy2(src_file, dest_file)

    return copied


def ensure_mirror_dir_writable(dest_dir: Path, *, mirror_root: Path) -> None:
    """Repair stale empty unwritable directories so mirrored copies stay user-owned.

    Older runs left empty `full_profile_txt/.../profile/logs` directories behind
    as root-owned paths. Those block future copies even when the parent project
    mirror is user-owned. If the unwritable branch is empty, remove and recreate
    it as the current user; otherwise surface a clear error.
    """
    existing = dest_dir
    while existing != FULL_PROFILE_ROOT and not existing.exists():
        existing = existing.parent

    stale_paths: list[Path] = []
    current = existing
    while current != FULL_PROFILE_ROOT and current.exists() and not os.access(current, os.W_OK):
        if not current.is_dir():
            raise PermissionError(f"Mirror path is not writable: {current}")
        children = list(current.iterdir())
        allowed_child = stale_paths[-1] if stale_paths and stale_paths[-1].parent == current else None
        if children and not (allowed_child is not None and children == [allowed_child]):
            raise PermissionError(
                f"Mirror path is not writable and not empty: {current}. "
                "Move or delete the stale directory, then re-run the full-profile flow."
            )
        stale_paths.append(current)
        current = current.parent

    if stale_paths:
        mirror_root_path = mirror_root.resolve() if mirror_root.is_symlink() else mirror_root
        OWNERSHIP_BACKUP_ROOT.mkdir(parents=True, exist_ok=True)
        backup_path = OWNERSHIP_BACKUP_ROOT / f"{mirror_root_path.name}_{uuid4().hex}"
        mirror_root_path.rename(backup_path)
        mirror_root_path.mkdir(parents=True, exist_ok=True)

    dest_dir.mkdir(parents=True, exist_ok=True)


def collect_txt_artifacts(*, dry_run: bool) -> list[Path]:
    copied: list[Path] = []
    copied.extend(
        mirror_txt_dir(
            ROOT / "CPU" / "results" / "profile",
            FULL_PROFILE_PROJECT_DIRS["CPU"] / "results" / "profile",
            mirror_root=FULL_PROFILE_PROJECT_DIRS["CPU"],
            dry_run=dry_run,
        )
    )
    copied.extend(
        mirror_txt_dir(
            ROOT / "GPU_Baseline" / "results" / "profile",
            FULL_PROFILE_PROJECT_DIRS["GPU_Baseline"] / "results" / "profile",
            mirror_root=FULL_PROFILE_PROJECT_DIRS["GPU_Baseline"],
            dry_run=dry_run,
        )
    )
    copied.extend(
        mirror_txt_dir(
            ROOT / "GPU_Baseline" / "profile" / "logs",
            FULL_PROFILE_PROJECT_DIRS["GPU_Baseline"] / "profile" / "logs",
            mirror_root=FULL_PROFILE_PROJECT_DIRS["GPU_Baseline"],
            dry_run=dry_run,
        )
    )
    copied.extend(
        mirror_txt_dir(
            ROOT / "GPU_Optimised" / "results" / "profile",
            FULL_PROFILE_PROJECT_DIRS["GPU_Optimised"] / "results" / "profile",
            mirror_root=FULL_PROFILE_PROJECT_DIRS["GPU_Optimised"],
            dry_run=dry_run,
        )
    )
    copied.extend(
        mirror_txt_dir(
            ROOT / "GPU_Optimised" / "profile" / "logs",
            FULL_PROFILE_PROJECT_DIRS["GPU_Optimised"] / "profile" / "logs",
            mirror_root=FULL_PROFILE_PROJECT_DIRS["GPU_Optimised"],
            dry_run=dry_run,
        )
    )
    return copied


def expected_ncu_reports(params: list[str], katnum: int, arch: str) -> list[Path]:
    reports: list[Path] = []
    for project in ("baseline", "optimised"):
        report_dir = ROOT / ("GPU_Baseline" if project == "baseline" else "GPU_Optimised") / "profile" / "ncu-rep"
        for param in params:
            report_path = report_dir / f"Profile_{project}_{param}_KAT{katnum}_{arch}.ncu-rep"
            if report_path.exists():
                reports.append(report_path)
    return reports


def write_summary(
    args: argparse.Namespace,
    params: list[str],
    steps: list[StepResult],
    copied_files: list[Path],
    ncu_reports: list[Path],
    *,
    dry_run: bool,
) -> Path:
    summary_path = (
        FULL_PROFILE_ROOT
        / "summary"
        / f"full_e2e_{args.param}_KAT{args.katnum}_{args.arch}.txt"
    )
    if dry_run:
        return summary_path

    summary_path.parent.mkdir(parents=True, exist_ok=True)
    overall_ok = all(step.status != "FAIL" for step in steps)

    with summary_path.open("w", encoding="utf-8") as handle:
        handle.write("FULL_E2E_STATUS=" + ("PASS" if overall_ok else "FAIL") + "\n")
        handle.write(f"started_at_utc={datetime.now(timezone.utc).isoformat()}\n")
        handle.write(f"param={args.param}\n")
        handle.write(f"katnum={args.katnum}\n")
        handle.write(f"arch={args.arch}\n")
        handle.write(f"ncu_enabled={'no' if args.skip_ncu else 'yes'}\n")
        handle.write(f"clean_enabled={'no' if args.skip_clean else 'yes'}\n")
        handle.write("selected_params=" + ",".join(params) + "\n\n")

        handle.write("[steps]\n")
        for step in steps:
            handle.write(
                f"{step.name}: {step.status} rc={step.returncode} log={step.log_path.relative_to(ROOT)}\n"
            )

        handle.write("\n[copied_txt_files]\n")
        if copied_files:
            for path in copied_files:
                handle.write(f"{path.relative_to(ROOT)}\n")
        else:
            handle.write("(none)\n")

        handle.write("\n[ncu_reports]\n")
        if ncu_reports:
            for path in ncu_reports:
                handle.write(f"{path.relative_to(ROOT)}\n")
        else:
            handle.write("(none)\n")

    return summary_path


def main() -> int:
    args = parse_args()
    args.katnum = resolve_katnum(args.katnum)
    params = selected_params(args.param)

    compare_dir = FULL_PROFILE_ROOT / "compare"
    summary_dir = FULL_PROFILE_ROOT / "summary"
    steps: list[StepResult] = []

    if args.dry_run:
        print("Dry run only. No files will be modified.")

    if not args.skip_clean:
        steps.append(
            run_cmd(
                "clean",
                ["make", "clean", f"PARAM={args.param}"],
                summary_dir / f"clean_{args.param}.txt",
                dry_run=args.dry_run,
            )
        )

    output_step = run_cmd(
        "output",
        [
            "make",
            "output",
            f"PARAM={args.param}",
            f"KATNUM={args.katnum}",
            f"ARCH={args.arch}",
        ],
        summary_dir / f"output_{args.param}_KAT{args.katnum}_{args.arch}.txt",
        dry_run=args.dry_run,
    )
    steps.append(output_step)

    if output_step.returncode == 0:
        steps.append(
            run_cmd(
                "compare-baseline",
                ["make", "compare", f"PARAM={args.param}"],
                compare_dir / f"compare_baseline_{args.param}.txt",
                dry_run=args.dry_run,
            )
        )
        steps.append(
            run_cmd(
                "compare-optimised",
                ["make", "compare-opt", f"PARAM={args.param}"],
                compare_dir / f"compare_optimised_{args.param}.txt",
                dry_run=args.dry_run,
            )
        )

        if not args.skip_ncu:
            baseline_cmd = [
                "python3",
                "generate_ncu_reports.py",
                "--project",
                "baseline",
                "--param",
                args.param,
                "--katnum",
                str(args.katnum),
                "--arch",
                args.arch,
                "--ncu",
                args.ncu,
                "--skip-on-permission-error",
            ]
            if args.sudo:
                baseline_cmd.append("--sudo")

            optimised_cmd = [
                "python3",
                "generate_ncu_reports.py",
                "--project",
                "optimised",
                "--param",
                args.param,
                "--katnum",
                str(args.katnum),
                "--arch",
                args.arch,
                "--ncu",
                args.ncu,
                "--skip-on-permission-error",
            ]
            if args.sudo:
                optimised_cmd.append("--sudo")

            steps.append(
                run_cmd(
                    "ncu-baseline",
                    baseline_cmd,
                    summary_dir / f"ncu_baseline_{args.param}_KAT{args.katnum}_{args.arch}.txt",
                    dry_run=args.dry_run,
                )
            )
            steps.append(
                run_cmd(
                    "ncu-optimised",
                    optimised_cmd,
                    summary_dir / f"ncu_optimised_{args.param}_KAT{args.katnum}_{args.arch}.txt",
                    dry_run=args.dry_run,
                )
            )

    copied_files = collect_txt_artifacts(dry_run=args.dry_run)
    ncu_reports = [] if args.skip_ncu else expected_ncu_reports(params, args.katnum, args.arch)
    summary_path = write_summary(
        args,
        params,
        steps,
        copied_files,
        ncu_reports,
        dry_run=args.dry_run,
    )

    if args.dry_run:
        print(f"Dry run summary path: {summary_path}")
        return 0

    overall_ok = all(step.status != "FAIL" for step in steps)
    print(f"Summary written to: {summary_path}")
    print(f"Mirrored .txt artifacts under: {FULL_PROFILE_ROOT}")
    if ncu_reports:
        print("Generated .ncu-rep files:")
        for report in ncu_reports:
            print(f"  - {report}")

    return 0 if overall_ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
