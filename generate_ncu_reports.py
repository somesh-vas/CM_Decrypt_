#!/usr/bin/env python3
"""Generate Nsight Compute reports for the GPU projects.

This script is intentionally orchestration-only:
- builds the requested parameter set via project Makefiles,
- runs `ncu` in each parameter directory,
- writes `.ncu-rep` files under `profile/ncu-rep/`,
- writes detailed imported text reports under `profile/logs/`,
- writes raw profiler progress logs under `profile/logs/`.
"""

import argparse
import os
import shlex
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
        "dir": ROOT / "GPU_Baseline",
        "bin_prefix": "decrypt_gpu_baseline_",
    },
    "optimised": {
        "dir": ROOT / "GPU_Optimised",
        "bin_prefix": "decrypt_gpu_optimised_",
    },
}

NVIDIA_PARAMS = Path("/proc/driver/nvidia/params")
PROFILE_RESULT_PASS = "PASS"
PROFILE_RESULT_FAIL = "FAIL"
PROFILE_RESULT_SKIP = "SKIP"


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


def run_cmd_to_file(cmd, output_file, cwd=None, env=None):
    """Run a command, stream stdout/stderr, and persist it to a file."""
    output_file.parent.mkdir(parents=True, exist_ok=True)
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
    with output_file.open("w", encoding="utf-8") as handle:
        for line in proc.stdout:
            print(line, end="")
            handle.write(line)
    return proc.wait()


def can_passwordless_sudo():
    """Return True when `sudo -n` can be used without prompting."""
    rc = subprocess.run(
        ["sudo", "-n", "true"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )
    return rc.returncode == 0


def profiling_counters_restricted():
    """Return True when the NVIDIA driver restricts profiling to admin users."""
    try:
        for line in NVIDIA_PARAMS.read_text(errors="ignore").splitlines():
            if line.startswith("RmProfilingAdminOnly:"):
                return line.split(":", 1)[1].strip() == "1"
    except OSError:
        return False

    return False


def print_permission_guidance(show_sudo_flag=False, *, label="FAIL"):
    """Explain how to enable Nsight Compute on systems with restricted counters."""
    print(f"[{label}] Nsight Compute cannot access GPU performance counters on this machine.")
    print("Cause: NVIDIA driver parameter `RmProfilingAdminOnly` is set to `1`.")
    print("Fix options:")
    if show_sudo_flag:
        print("  1. Re-run this script with `--sudo` so it can prompt for your sudo password.")
        print("     Example: python3 generate_ncu_reports.py --project optimised --param all --katnum 5 --arch sm_86 --sudo")
        print("  2. Run the profiling command as root/admin.")
        print("  3. Ask an admin to enable non-root profiling by setting:")
    else:
        print("  1. Run the profiling command as root/admin.")
        print("  2. Ask an admin to enable non-root profiling by setting:")
    print("     NVreg_RestrictProfilingToAdminUsers=0")
    print("Typical admin steps on Linux:")
    print("  sudo sh -c 'echo options nvidia NVreg_RestrictProfilingToAdminUsers=0 > /etc/modprobe.d/nvidia-profiler.conf'")
    print("  sudo update-initramfs -u")
    print("  sudo reboot")


def permission_result(show_sudo_flag=False, *, skip_on_permission_error=False):
    """Return the profile result for a restricted-counter environment."""
    label = "SKIP" if skip_on_permission_error else "FAIL"
    print_permission_guidance(show_sudo_flag=show_sudo_flag, label=label)
    if skip_on_permission_error:
        print("NCU_SKIP_REASON=restricted-counters")
        return PROFILE_RESULT_SKIP
    return PROFILE_RESULT_FAIL


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


def resolve_writable_output_path(preferred_path, fallback_suffix):
    """Return a writable output path, falling back when an existing file is not writable."""
    if not preferred_path.exists() or os.access(preferred_path, os.W_OK):
        return preferred_path

    return preferred_path.with_name(f"{preferred_path.stem}{fallback_suffix}{preferred_path.suffix}")


def render_report_text(ncu_path, rep_file, txt_file):
    """Import an `.ncu-rep` file and write a readable per-kernel text report."""
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
    return run_cmd_to_file(cmd, txt_file, cwd=ROOT, env=build_ncu_env())


def build_sudo_ncu_cmd(ncu_cmd, owned_outputs, *, non_interactive):
    """Wrap an `ncu` command so root-created artifacts are handed back to the user."""
    quoted_cmd = " ".join(shlex.quote(part) for part in ncu_cmd)
    quoted_outputs = " ".join(shlex.quote(str(path)) for path in owned_outputs)
    shell_cmd = (
        f"{quoted_cmd}; rc=$?; "
        'if [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then '
        f"chown " + '"${SUDO_UID}:${SUDO_GID}" ' + f"{quoted_outputs} 2>/dev/null || true; "
        "fi; "
        "exit $rc"
    )

    sudo_cmd = ["sudo"]
    if non_interactive:
        sudo_cmd.append("-n")
    sudo_cmd.extend(["--preserve-env=PATH", "bash", "-lc", shell_cmd])
    return sudo_cmd


def profile_one(
    project_name,
    param,
    katnum,
    arch,
    ncu_path,
    use_sudo=False,
    skip_on_permission_error=False,
):
    """Build and profile one `(project, param)` pair.

    Args:
        project_name: `baseline` or `optimised`.
        param: McEliece parameter string (for example `460896`).
        katnum: Number of KAT iterations passed to Makefiles.
        arch: CUDA arch code such as `sm_86`.
        ncu_path: Absolute/relative path to `ncu`.

    Returns:
        str: `PASS`, `FAIL`, or `SKIP`.
    """
    pinfo = PROJECTS[project_name]
    pdir = pinfo["dir"]
    bin_name = f"{pinfo['bin_prefix']}{param}"

    # Output locations are project-local to keep baseline/optimised isolated.
    ncu_rep_dir = pdir / "profile" / "ncu-rep"
    ncu_log_dir = pdir / "profile" / "logs"
    ncu_rep_dir.mkdir(parents=True, exist_ok=True)
    ncu_log_dir.mkdir(parents=True, exist_ok=True)

    rep_base = ncu_rep_dir / f"Profile_{project_name}_{param}_KAT{katnum}_{arch}"
    rep_file = Path(str(rep_base) + ".ncu-rep")
    preferred_log_file = ncu_log_dir / f"Profile_{project_name}_{param}_KAT{katnum}_{arch}.txt"
    preferred_progress_log_file = ncu_log_dir / f"Profile_{project_name}_{param}_KAT{katnum}_{arch}_progress.txt"
    log_file = resolve_writable_output_path(preferred_log_file, "_details")
    progress_log_file = resolve_writable_output_path(preferred_progress_log_file, "_alt")

    print(f"===== {project_name} param{param} (ARCH={arch}, KATNUM={katnum}) =====")
    if log_file != preferred_log_file:
        print(f"[INFO] detailed text report fallback: {log_file}")
    if progress_log_file != preferred_progress_log_file:
        print(f"[INFO] progress log fallback: {progress_log_file}")

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
        return PROFILE_RESULT_FAIL

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
        str(progress_log_file),
        str(exe_rel),
    ]

    if profiling_counters_restricted():
        if os.geteuid() == 0:
            pass
        elif can_passwordless_sudo():
            ncu_cmd = build_sudo_ncu_cmd(
                ncu_cmd,
                [rep_file, progress_log_file],
                non_interactive=True,
            )
        elif use_sudo:
            ncu_cmd = build_sudo_ncu_cmd(
                ncu_cmd,
                [rep_file, progress_log_file],
                non_interactive=False,
            )
        else:
            return permission_result(
                show_sudo_flag=True,
                skip_on_permission_error=skip_on_permission_error,
            )

    rc = run_cmd(ncu_cmd, cwd=run_dir, env=build_ncu_env())
    if rc != 0:
        if progress_log_file.exists():
            log_text = progress_log_file.read_text(errors="ignore")
            if "ERR_NVGPUCTRPERM" in log_text:
                return permission_result(
                    skip_on_permission_error=skip_on_permission_error,
                )
        print(f"[FAIL] ncu run failed for {project_name} param{param}")
        return PROFILE_RESULT_FAIL

    if rep_file.exists():
        render_rc = render_report_text(ncu_path, rep_file, log_file)
        if render_rc != 0:
            print(f"[FAIL] text report generation failed for {project_name} param{param}")
            print(f"[PASS] report:   {rep_file}")
            print(f"[PASS] progress: {progress_log_file}")
            return PROFILE_RESULT_FAIL

        print(f"[PASS] report: {rep_file}")
        print(f"[PASS] text:   {log_file}")
        print(f"[PASS] progress: {progress_log_file}")
        return PROFILE_RESULT_PASS

    print(f"[FAIL] report missing: {rep_file}")
    if progress_log_file.exists():
        try:
            tail = progress_log_file.read_text(errors="ignore").splitlines()[-8:]
            print("--- log tail ---")
            for line in tail:
                print(line)
        except Exception:
            # Best-effort debug output; missing tail is non-fatal.
            pass
    return PROFILE_RESULT_FAIL


def main():
    """CLI entry point."""
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(line_buffering=True)

    parser = argparse.ArgumentParser(description="Generate Nsight Compute .ncu-rep files")
    parser.add_argument("--project", choices=["baseline", "optimised", "both"], default="both")
    parser.add_argument("--param", default="all", help="all or one of: 348864,460896,6688128,6960119,8192128")
    parser.add_argument("--katnum", type=int, default=5)
    parser.add_argument("--arch", default="sm_86")
    parser.add_argument("--ncu", default=shutil.which("ncu") or "/usr/local/cuda/bin/ncu")
    parser.add_argument("--sudo", action="store_true", help="allow an interactive sudo prompt when profiling requires admin access")
    parser.add_argument(
        "--skip-on-permission-error",
        action="store_true",
        help="exit successfully with `NCU_REPORT_STATUS=SKIP` when GPU counters require admin access",
    )
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

    if profiling_counters_restricted() and os.geteuid() != 0 and not can_passwordless_sudo() and not args.sudo:
        result = permission_result(
            show_sudo_flag=True,
            skip_on_permission_error=args.skip_on_permission_error,
        )
        print(f"NCU_REPORT_STATUS={result}")
        return 0 if result == PROFILE_RESULT_SKIP else 1

    overall_result = PROFILE_RESULT_PASS
    for project in projects:
        for param in params:
            result = profile_one(
                project,
                param,
                args.katnum,
                args.arch,
                args.ncu,
                use_sudo=args.sudo,
                skip_on_permission_error=args.skip_on_permission_error,
            )
            if result == PROFILE_RESULT_FAIL:
                overall_result = PROFILE_RESULT_FAIL
            elif result == PROFILE_RESULT_SKIP and overall_result == PROFILE_RESULT_PASS:
                overall_result = PROFILE_RESULT_SKIP

    if overall_result == PROFILE_RESULT_PASS:
        print(f"NCU_REPORT_STATUS={PROFILE_RESULT_PASS}")
        return 0

    print(f"NCU_REPORT_STATUS={overall_result}")
    return 0 if overall_result == PROFILE_RESULT_SKIP else 1


if __name__ == "__main__":
    raise SystemExit(main())
