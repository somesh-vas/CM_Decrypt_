#!/usr/bin/env python3
"""Generate full Nsight Compute text reports directly from GPU binaries.

This helper runs `ncu` with the section set used in manual profiling, saves the
profiling progress stream separately, then imports the resulting `.ncu-rep`
into the human-readable `.txt` report format shown in the example files.

Example:
    python3 utility/generate_full_ncu_txt.py --project both --param all --katnum 50000 --arch sm_75
"""

from __future__ import annotations

import argparse
import os
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
        "txt_prefix": "baseline",
    },
    "optimised": {
        "dir": ROOT / "GPU_Optimised",
        "bin_prefix": "decrypt_gpu_optimised_",
        "txt_prefix": "optimised",
    },
}
SECTIONS = [
    "SpeedOfLight",
    "MemoryWorkloadAnalysis",
    "ComputeWorkloadAnalysis",
    "LaunchStats",
    "SchedulerStats",
    "WarpStateStats",
    "SourceCounters",
]
NVIDIA_PARAMS = Path("/proc/driver/nvidia/params")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate full Nsight Compute text reports from GPU binaries."
    )
    parser.add_argument("--project", choices=["baseline", "optimised", "both"], default="both")
    parser.add_argument("--param", default="all", help="all or one of: 348864,460896,6688128,6960119,8192128")
    parser.add_argument("--katnum", type=int, required=True, help="KATNUM compiled into the binary.")
    parser.add_argument("--arch", default="sm_86", help="CUDA architecture, for example sm_75 or sm_86.")
    parser.add_argument(
        "--ncu",
        default=shutil.which("ncu") or "/usr/local/cuda/bin/ncu",
        help="Path to the `ncu` executable.",
    )
    parser.add_argument("--skip-build", action="store_true", help="Reuse existing binaries instead of rebuilding.")
    parser.add_argument("--sudo", action="store_true", help="Allow interactive sudo if counters require admin access.")
    parser.add_argument(
        "--output-dir",
        type=Path,
        help="Directory for the generated `.txt` files. Defaults to each project's `profile/full_profile` directory.",
    )
    parser.add_argument(
        "--import-only",
        action="store_true",
        help="Skip profiling and regenerate the `.txt` report from an existing `.ncu-rep` file.",
    )
    parser.add_argument("--dry-run", action="store_true", help="Print commands and output paths without executing.")
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


def build_ncu_env() -> dict[str, str]:
    env = os.environ.copy()
    env.pop("PYTHONHOME", None)
    env.pop("PYTHONPATH", None)
    env["PYTHONNOUSERSITE"] = "1"
    env["PYTHONUTF8"] = "1"
    env["LANG"] = "C.UTF-8"
    env["LC_ALL"] = "C.UTF-8"
    return env


def can_passwordless_sudo() -> bool:
    rc = subprocess.run(
        ["sudo", "-n", "true"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return rc.returncode == 0


def profiling_counters_restricted() -> bool:
    try:
        for line in NVIDIA_PARAMS.read_text(errors="ignore").splitlines():
            if line.startswith("RmProfilingAdminOnly:"):
                return line.split(":", 1)[1].strip() == "1"
    except OSError:
        return False
    return False


def print_cmd(cmd: list[str], cwd: Path) -> None:
    print(f"$ (cd {shlex.quote(str(cwd))} && {' '.join(shlex.quote(part) for part in cmd)})")


def run_streaming(cmd: list[str], cwd: Path, env: dict[str, str]) -> tuple[int, str]:
    proc = subprocess.Popen(
        cmd,
        cwd=str(cwd),
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )
    assert proc.stdout is not None

    chunks: list[str] = []
    for line in proc.stdout:
        print(line, end="")
        chunks.append(line)

    return proc.wait(), "".join(chunks)


def maybe_build_binary(project_name: str, param: str, katnum: int, arch: str, *, skip_build: bool, dry_run: bool) -> Path:
    info = PROJECTS[project_name]
    project_dir = info["dir"]
    param_dir = project_dir / "param" / f"param{param}"
    binary_path = project_dir / "bin" / f"{info['bin_prefix']}{param}"

    if skip_build:
        if not binary_path.exists():
            raise FileNotFoundError(
                f"Binary not found for {project_name} param{param}: {binary_path}. Re-run without --skip-build."
            )
        return binary_path

    build_cmd = [
        "make",
        "all",
        f"ARCH={arch}",
        f"KATNUM={katnum}",
        "WRITE_ERRORSTREAM=0",
    ]
    print_cmd(build_cmd, param_dir)
    if not dry_run:
        rc, _ = run_streaming(build_cmd, param_dir, build_ncu_env())
        if rc != 0:
            raise RuntimeError(f"Build failed for {project_name} param{param}")

    return binary_path


def default_output_dir(project_name: str) -> Path:
    return PROJECTS[project_name]["dir"] / "profile" / "full_profile"


def report_paths(project_name: str, param: str, katnum: int, arch: str, output_dir: Path | None) -> tuple[Path, Path, Path]:
    info = PROJECTS[project_name]
    out_dir = output_dir if output_dir is not None else default_output_dir(project_name)
    out_dir.mkdir(parents=True, exist_ok=True)
    txt_path = out_dir / f"{info['txt_prefix']}_{param}_full_profile_KAT{katnum}_{arch}.txt"
    progress_path = out_dir / f"{info['txt_prefix']}_{param}_full_profile_KAT{katnum}_{arch}_progress.txt"
    rep_base = out_dir / f"{info['txt_prefix']}_{param}_full_profile_KAT{katnum}_{arch}"
    return txt_path, progress_path, rep_base


def build_ncu_cmd(ncu_path: str, binary_name: str, rep_base: Path) -> list[str]:
    cmd = [
        ncu_path,
        "--set",
        "full",
        "--force-overwrite",
    ]
    for section in SECTIONS:
        cmd.extend(["--section", section])
    cmd.extend(["-o", str(rep_base), str(Path("..") / ".." / "bin" / binary_name)])
    return cmd


def build_import_cmd(ncu_path: str, rep_file: Path) -> list[str]:
    return [
        ncu_path,
        "--import",
        str(rep_file),
    ]


def wrap_with_sudo_if_needed(cmd: list[str], *, use_sudo: bool) -> list[str]:
    if not profiling_counters_restricted() or os.geteuid() == 0:
        return cmd

    if can_passwordless_sudo():
        return ["sudo", "-n", "--preserve-env=PATH", *cmd]

    if use_sudo:
        return ["sudo", "--preserve-env=PATH", *cmd]

    raise PermissionError(
        "Nsight Compute cannot access GPU performance counters on this machine. "
        "Re-run with --sudo or enable non-root profiling."
    )


def run_one(
    project_name: str,
    param: str,
    katnum: int,
    arch: str,
    *,
    ncu_path: str,
    skip_build: bool,
    use_sudo: bool,
    output_dir: Path | None,
    import_only: bool,
    dry_run: bool,
) -> int:
    info = PROJECTS[project_name]
    project_dir = info["dir"]
    param_dir = project_dir / "param" / f"param{param}"
    txt_path, progress_path, rep_base = report_paths(project_name, param, katnum, arch, output_dir)
    rep_file = Path(str(rep_base) + ".ncu-rep")
    binary_path = project_dir / "bin" / f"{info['bin_prefix']}{param}"

    if not import_only:
        binary_path = maybe_build_binary(
            project_name,
            param,
            katnum,
            arch,
            skip_build=skip_build,
            dry_run=dry_run,
        )

    print(f"===== {project_name} param{param} (ARCH={arch}, KATNUM={katnum}) =====")
    if not import_only:
        print(f"[INFO] binary: {binary_path}")
    print(f"[INFO] text:   {txt_path}")
    print(f"[INFO] rep:    {rep_file}")
    print(f"[INFO] log:    {progress_path}")

    if not import_only:
        ncu_cmd = build_ncu_cmd(ncu_path, binary_path.name, rep_base)
        try:
            final_cmd = wrap_with_sudo_if_needed(ncu_cmd, use_sudo=use_sudo)
        except PermissionError as exc:
            print(f"[FAIL] {exc}")
            return 1

        print_cmd(final_cmd, param_dir)
        if dry_run:
            return 0

        rc, output_text = run_streaming(final_cmd, param_dir, build_ncu_env())
        progress_path.write_text(output_text, encoding="utf-8")
        if rc != 0:
            print(f"[FAIL] ncu failed for {project_name} param{param}")
            return 1

        if not rep_file.exists():
            print(f"[FAIL] report file missing after profiling: {rep_file}")
            return 1
    elif dry_run:
        return 0
    elif not rep_file.exists():
        print(f"[FAIL] missing existing report for --import-only: {rep_file}")
        return 1

    import_cmd = build_import_cmd(ncu_path, rep_file)
    print_cmd(import_cmd, ROOT)
    import_rc, import_text = run_streaming(import_cmd, ROOT, build_ncu_env())
    txt_path.write_text(import_text, encoding="utf-8")
    if import_rc != 0:
        print(f"[FAIL] ncu import failed for {project_name} param{param}")
        return 1

    print(f"[PASS] wrote {txt_path}")
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
                    ncu_path=args.ncu,
                    skip_build=args.skip_build,
                    use_sudo=args.sudo,
                    output_dir=args.output_dir,
                    import_only=args.import_only,
                    dry_run=args.dry_run,
                )
            except (FileNotFoundError, RuntimeError) as exc:
                print(f"[FAIL] {exc}")
                failures = 1

    return failures


if __name__ == "__main__":
    raise SystemExit(main())
