#!/usr/bin/env python3
"""Generate full-profile GPU timing text files by running the built binaries.

This helper runs the selected GPU baseline/optimised binaries from the correct
`param/paramXXXX` directory so project-relative input paths continue to work.
For each run it writes:

- the project-native timing output under `results/profile/`
- a normalized copy under `profile/full_profile/`

Example:
    python3 utility/generate_full_profile_txt.py --project both --param all --katnum 50000 --arch sm_75
"""

from __future__ import annotations

import argparse
import shlex
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PARAMS = ["348864", "460896", "6688128", "6960119", "8192128"]
PROJECTS = {
    "baseline": {
        "dir": ROOT / "GPU_Baseline",
        "bin_prefix": "decrypt_gpu_baseline_",
        "profile_prefix": "Profile_GPU_baseline_",
        "full_profile_prefix": "full_profile_baseline_",
    },
    "optimised": {
        "dir": ROOT / "GPU_Optimised",
        "bin_prefix": "decrypt_gpu_optimised_",
        "profile_prefix": "Profile_GPU_optimised_",
        "full_profile_prefix": "full_profile_optimised_",
    },
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate full_profile_*.txt files by running the GPU binaries."
    )
    parser.add_argument(
        "--project",
        choices=["baseline", "optimised", "both"],
        default="both",
        help="Which GPU project(s) to run.",
    )
    parser.add_argument(
        "--param",
        default="all",
        help="all or one of: 348864,460896,6688128,6960119,8192128",
    )
    parser.add_argument("--katnum", type=int, required=True, help="KATNUM compiled into the binary.")
    parser.add_argument("--arch", default="sm_86", help="CUDA architecture, for example sm_75 or sm_86.")
    parser.add_argument(
        "--skip-build",
        action="store_true",
        help="Reuse existing binaries instead of rebuilding them first.",
    )
    parser.add_argument(
        "--write-errorstream",
        action="store_true",
        help="Build/run with WRITE_ERRORSTREAM=1 instead of timing-only mode.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the commands and output paths without executing them.",
    )
    args = parser.parse_args()

    if args.param != "all" and args.param not in PARAMS:
        parser.error("--param must be `all` or one of: " + ",".join(PARAMS))
    if args.katnum <= 0:
        parser.error("--katnum must be > 0")

    return args


def selected_projects(project_arg: str) -> list[str]:
    return ["baseline", "optimised"] if project_arg == "both" else [project_arg]


def selected_params(param_arg: str) -> list[str]:
    return PARAMS if param_arg == "all" else [param_arg]


def print_cmd(cmd: list[str], cwd: Path) -> None:
    print(f"$ (cd {shlex.quote(str(cwd))} && {' '.join(shlex.quote(part) for part in cmd)})")


def run_streaming(cmd: list[str], cwd: Path) -> tuple[int, str]:
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None

    output_chunks: list[str] = []
    for line in proc.stdout:
        print(line, end="")
        output_chunks.append(line)

    return proc.wait(), "".join(output_chunks)


def ensure_binary(project_name: str, param: str, katnum: int, arch: str, *, skip_build: bool, write_errorstream: bool, dry_run: bool) -> Path:
    info = PROJECTS[project_name]
    project_dir = info["dir"]
    param_dir = project_dir / "param" / f"param{param}"
    binary_path = project_dir / "bin" / f"{info['bin_prefix']}{param}"

    if skip_build:
        if not binary_path.exists():
            raise FileNotFoundError(
                f"Binary not found for {project_name} param{param}: {binary_path}. "
                "Re-run without --skip-build."
            )
        return binary_path

    build_cmd = [
        "make",
        "clean",
        "all",
        f"ARCH={arch}",
        f"KATNUM={katnum}",
        f"WRITE_ERRORSTREAM={1 if write_errorstream else 0}",
    ]
    print_cmd(build_cmd, param_dir)
    if not dry_run:
        rc, _ = run_streaming(build_cmd, param_dir)
        if rc != 0:
            raise RuntimeError(f"Build failed for {project_name} param{param}")

    return binary_path


def profile_paths(project_name: str, param: str, katnum: int, arch: str) -> tuple[Path, Path, Path]:
    info = PROJECTS[project_name]
    project_dir = info["dir"]
    native_profile = project_dir / "results" / "profile" / f"{info['profile_prefix']}{param}.txt"
    full_profile_dir = project_dir / "profile" / "full_profile"
    full_profile = full_profile_dir / f"{info['full_profile_prefix']}{param}_KAT{katnum}_{arch}.txt"
    run_log = full_profile_dir / f"{info['full_profile_prefix']}{param}_KAT{katnum}_{arch}_stdout.txt"
    return native_profile, full_profile, run_log


def run_one(project_name: str, param: str, katnum: int, arch: str, *, skip_build: bool, write_errorstream: bool, dry_run: bool) -> int:
    info = PROJECTS[project_name]
    project_dir = info["dir"]
    param_dir = project_dir / "param" / f"param{param}"
    binary_path = ensure_binary(
        project_name,
        param,
        katnum,
        arch,
        skip_build=skip_build,
        write_errorstream=write_errorstream,
        dry_run=dry_run,
    )

    native_profile, full_profile, run_log = profile_paths(project_name, param, katnum, arch)
    full_profile.parent.mkdir(parents=True, exist_ok=True)

    print(f"===== {project_name} param{param} (ARCH={arch}, KATNUM={katnum}) =====")
    print(f"[INFO] native profile: {native_profile}")
    print(f"[INFO] full profile:   {full_profile}")

    run_cmd = [str(Path("..") / ".." / "bin" / binary_path.name)]
    print_cmd(run_cmd, param_dir)
    if dry_run:
        return 0

    if native_profile.exists():
        native_profile.unlink()

    rc, stdout_text = run_streaming(run_cmd, param_dir)
    run_log.write_text(stdout_text, encoding="utf-8")
    if rc != 0:
        print(f"[FAIL] binary run failed for {project_name} param{param}")
        return 1

    profile_text = ""
    if native_profile.exists():
        profile_text = native_profile.read_text(encoding="utf-8", errors="ignore").strip()

    if not profile_text:
        profile_text = stdout_text.strip()

    if not profile_text:
        print(f"[FAIL] no profile text was produced for {project_name} param{param}")
        return 1

    full_profile.write_text(profile_text + "\n", encoding="utf-8")
    print(f"[PASS] wrote {full_profile}")
    return 0


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    args = parse_args()
    failures = 0

    for project_name in selected_projects(args.project):
        for param in selected_params(args.param):
            try:
                failures |= run_one(
                    project_name,
                    param,
                    args.katnum,
                    args.arch,
                    skip_build=args.skip_build,
                    write_errorstream=args.write_errorstream,
                    dry_run=args.dry_run,
                )
            except (FileNotFoundError, RuntimeError) as exc:
                print(f"[FAIL] {exc}")
                failures = 1

    return failures


if __name__ == "__main__":
    raise SystemExit(main())
