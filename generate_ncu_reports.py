#!/usr/bin/env python3
"""Generate Nsight Compute reports for the cleaned GPU projects.

This script is intentionally orchestration-only:
- builds the requested parameter set via project Makefiles,
- runs `ncu` in each parameter directory,
- writes `.ncu-rep` files under `profile/ncu-rep/`,
- writes profiler logs under `profile/logs/`.
"""

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

# Repository root where this script lives.
ROOT = Path(__file__).resolve().parent

# Supported McEliece parameter sets in this workspace.
PARAMS = ["348864", "460896", "6688128", "6960119", "8192128"]

# Project metadata used to resolve build directory and binary name.
PROJECTS = {
    "baseline": {
        "dir": ROOT / "cleaned_gpu_baseline",
        "bin_prefix": "decrypt_gpu_baseline_",
    },
    "optimised": {
        "dir": ROOT / "cleaned_gpu_optimised",
        "bin_prefix": "decrypt_gpu_optimised_",
    },
}


def run_cmd(cmd, cwd=None, env=None):
    """Run a command and stream combined stdout/stderr to the terminal.

    Returns:
        int: process exit code.
    """
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None
    for line in proc.stdout:
        print(line, end="")
    return proc.wait()


def build_ncu_env():
    """Return a clean environment for Nsight Compute runs.

    Some CUDA/Nsight setups are sensitive to inherited Python runtime
    variables; this keeps execution deterministic across shells.
    """
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PYTHONNOUSERSITE"] = "1"
    env["PYTHONUTF8"] = "1"
    env["LANG"] = "C.UTF-8"
    env["LC_ALL"] = "C.UTF-8"
    return env


def profile_one(project_name, param, katnum, arch, ncu_path):
    """Build and profile one `(project, param)` pair.

    Args:
        project_name: `baseline` or `optimised`.
        param: McEliece parameter string (for example `460896`).
        katnum: Number of KAT iterations passed to Makefiles.
        arch: CUDA arch code such as `sm_86`.
        ncu_path: Absolute/relative path to `ncu`.

    Returns:
        int: 0 on success, 1 on failure.
    """
    pinfo = PROJECTS[project_name]
    pdir = pinfo["dir"]
    bin_name = f"{pinfo['bin_prefix']}{param}"

    # Output locations are project-local to keep baseline/optimised isolated.
    ncu_rep_dir = pdir / "profile" / "ncu-rep"
    ncu_log_dir = pdir / "profile" / "logs"
    ncu_rep_dir.mkdir(parents=True, exist_ok=True)
    ncu_log_dir.mkdir(parents=True, exist_ok=True)

    print(f"===== {project_name} param{param} (ARCH={arch}, KATNUM={katnum}) =====")

    # Build first so profiling always runs against current binaries.
    rc = run_cmd(
        [
            "make",
            "all",
            f"PARAM={param}",
            f"KATNUM={katnum}",
            f"ARCH={arch}",
        ],
        cwd=pdir,
    )
    if rc != 0:
        print(f"[FAIL] build failed for {project_name} param{param}")
        return 1

    rep_base = ncu_rep_dir / f"Profile_{project_name}_{param}_KAT{katnum}_{arch}"
    rep_file = Path(str(rep_base) + ".ncu-rep")
    log_file = ncu_log_dir / f"Profile_{project_name}_{param}_KAT{katnum}_{arch}.txt"

    # Run from param directory so project-relative runtime paths still work.
    run_dir = pdir / "param" / f"param{param}"
    exe_rel = Path("..") / ".." / "bin" / bin_name

    ncu_cmd = [
        ncu_path,
        "--target-processes",
        "all",
        "--set",
        "full",
        "--force-overwrite",
        "--export",
        str(rep_base),
        "--log-file",
        str(log_file),
        str(exe_rel),
    ]

    rc = run_cmd(ncu_cmd, cwd=run_dir, env=build_ncu_env())
    if rc != 0:
        print(f"[FAIL] ncu run failed for {project_name} param{param}")
        return 1

    if rep_file.exists():
        print(f"[PASS] report: {rep_file}")
        print(f"[PASS] log:    {log_file}")
        return 0

    print(f"[FAIL] report missing: {rep_file}")
    if log_file.exists():
        try:
            tail = log_file.read_text(errors="ignore").splitlines()[-8:]
            print("--- log tail ---")
            for line in tail:
                print(line)
        except Exception:
            # Best-effort debug output; missing tail is non-fatal.
            pass
    return 1


def main():
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Generate Nsight Compute .ncu-rep files")
    parser.add_argument("--project", choices=["baseline", "optimised", "both"], default="both")
    parser.add_argument("--param", default="all", help="all or one of: 348864,460896,6688128,6960119,8192128")
    parser.add_argument("--katnum", type=int, default=5)
    parser.add_argument("--arch", default="sm_86")
    parser.add_argument("--ncu", default=shutil.which("ncu") or "/usr/local/cuda/bin/ncu")
    args = parser.parse_args()

    if args.katnum <= 0:
        print("KATNUM must be > 0", file=sys.stderr)
        return 2

    if args.param == "all":
        params = PARAMS
    elif args.param in PARAMS:
        params = [args.param]
    else:
        print("Invalid --param. Use all or one of: 348864,460896,6688128,6960119,8192128", file=sys.stderr)
        return 2

    if args.project == "both":
        projects = ["baseline", "optimised"]
    else:
        projects = [args.project]

    fail = 0
    for project in projects:
        for param in params:
            fail |= profile_one(project, param, args.katnum, args.arch, args.ncu)

    if fail == 0:
        print("NCU_REPORT_STATUS=PASS")
        return 0

    print("NCU_REPORT_STATUS=FAIL")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
