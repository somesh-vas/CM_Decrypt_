#!/usr/bin/env python3
"""Tkinter UI for invoking project Make targets with runtime parameters.

The GUI wraps the root Makefile and supports CPU/GPU/GPU-optimised flows,
including multi-step compare workflows used during validation.
"""

import os
import queue
import subprocess
import threading
import tkinter as tk
from tkinter import ttk

ROOT_DIR = os.path.dirname(os.path.abspath(__file__))

# Root Makefile targets exposed in the GUI.
TARGETS = [
    "all",
    "run",
    "output",
    "full-profile",
    "clean",
    "compare",
    "compare-opt",
    "tri-compare",
    "ncu-reports",
    "ncu-reports-baseline",
    "ncu-reports-optimised",
    "render-ncu-txt",
    "render-ncu-txt-baseline",
    "render-ncu-txt-optimised",
    "cpu-all",
    "cpu-run",
    "cpu-clean",
    "gpu-all",
    "gpu-run",
    "gpu-output",
    "gpu-clean",
    "gpuopt-all",
    "gpuopt-run",
    "gpuopt-output",
    "gpuopt-clean",
    "kem-vectors",
    "multiply-kem-vectors",
    "clear-test-vectors",
    "clear-results",
]
# Supported values mapped to current project layout.
PARAMS = ["all", "348864", "460896", "6688128", "6960119", "8192128"]
ARCHES = ["sm_86", "sm_75"]


class MakeGui(tk.Tk):
    """Main application window for running project automation commands."""

    TILE_BG = "#f3f4f6"
    TILE_FG = "#1f2933"
    TILE_BORDER = "#c7d0d9"
    TILE_SELECTED_BG = "#1f4b7a"
    TILE_SELECTED_FG = "#ffffff"
    TILE_SELECTED_BORDER = "#163a5e"

    def __init__(self):
        """Initialize window state, process handles, and UI widgets."""
        super().__init__()
        self.title("Unified CPU/GPU Runner")
        self.geometry("1120x760")

        # `self.proc` tracks the currently-running subprocess (if any).
        self.proc = None
        # Worker thread pushes output lines into this queue for the UI thread.
        self.out_q = queue.Queue()

        self._build_ui()
        self.after(100, self._drain_queue)

    def _build_ui(self):
        """Create input controls, action buttons, and live log view."""
        top = ttk.Frame(self, padding=10)
        top.pack(fill="x")

        inputs = ttk.LabelFrame(top, text="Runtime Settings", padding=10)
        inputs.pack(fill="x")

        ttk.Label(inputs, text="KATNUM").grid(row=0, column=0, sticky="w")
        self.kat_var = tk.StringVar(value="5")
        self.kat_entry = ttk.Entry(inputs, textvariable=self.kat_var, width=10)
        self.kat_entry.grid(row=1, column=0, padx=(0, 12), sticky="w")

        ttk.Label(inputs, text="CT_PER_SK").grid(row=0, column=1, sticky="w")
        self.ct_per_sk_var = tk.StringVar(value="100")
        self.ct_per_sk_entry = ttk.Entry(inputs, textvariable=self.ct_per_sk_var, width=10)
        self.ct_per_sk_entry.grid(row=1, column=1, padx=(0, 12), sticky="w")

        ttk.Label(inputs, text="CT_MULT").grid(row=0, column=2, sticky="w")
        self.ct_mult_var = tk.StringVar(value="2")
        self.ct_mult_entry = ttk.Entry(inputs, textvariable=self.ct_mult_var, width=10)
        self.ct_mult_entry.grid(row=1, column=2, padx=(0, 12), sticky="w")

        self.ncu_overwrite_var = tk.BooleanVar(value=False)
        self.ncu_overwrite_check = ttk.Checkbutton(
            inputs,
            text="Overwrite imported NCU TXT",
            variable=self.ncu_overwrite_var,
        )
        self.ncu_overwrite_check.grid(row=0, column=3, rowspan=2, padx=(0, 12), sticky="w")

        self.run_btn = ttk.Button(inputs, text="Run", command=self.run_make)
        self.run_btn.grid(row=1, column=4, padx=(8, 8), sticky="w")

        self.stop_btn = ttk.Button(inputs, text="Stop", command=self.stop_make, state="disabled")
        self.stop_btn.grid(row=1, column=5, padx=(0, 8), sticky="w")

        self.clear_btn = ttk.Button(inputs, text="Clear Log", command=self.clear_log)
        self.clear_btn.grid(row=1, column=6, padx=(0, 12), sticky="w")

        self.status_var = tk.StringVar(value="Idle")
        ttk.Label(inputs, text="Status").grid(row=0, column=7, sticky="w")
        ttk.Label(inputs, textvariable=self.status_var).grid(row=1, column=7, sticky="w")
        inputs.columnconfigure(8, weight=1)

        self.target_var = tk.StringVar(value="run")
        self.param_var = tk.StringVar(value="all")
        self.arch_var = tk.StringVar(value="sm_86")

        self._create_tile_group(
            top,
            title="Target",
            variable=self.target_var,
            options=TARGETS,
            columns=4,
            wraplength=180,
        ).pack(fill="x", pady=(10, 0))

        selector_row = ttk.Frame(top)
        selector_row.pack(fill="x", pady=(10, 0))

        self._create_tile_group(
            selector_row,
            title="Parameter Set",
            variable=self.param_var,
            options=PARAMS,
            columns=3,
            wraplength=100,
        ).pack(side="left", fill="both", expand=True, padx=(0, 10))

        self._create_tile_group(
            selector_row,
            title="GPU Architecture",
            variable=self.arch_var,
            options=ARCHES,
            columns=2,
            wraplength=100,
        ).pack(side="left", fill="y")

        log_frame = ttk.Frame(self, padding=(10, 0, 10, 10))
        log_frame.pack(fill="both", expand=True)

        self.log = tk.Text(log_frame, wrap="none", font=("DejaVu Sans Mono", 10))
        self.log.pack(side="left", fill="both", expand=True)

        yscroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        yscroll.pack(side="right", fill="y")
        self.log.configure(yscrollcommand=yscroll.set)

        self._append(f"Working directory: {ROOT_DIR}\n")

    def _create_tile_group(self, parent, title, variable, options, columns, wraplength):
        """Render a group of selectable options as tile buttons."""
        frame = ttk.LabelFrame(parent, text=title, padding=10)
        buttons = []

        for index, option in enumerate(options):
            row, column = divmod(index, columns)
            button = tk.Button(
                frame,
                text=option,
                relief="solid",
                bd=1,
                padx=12,
                pady=10,
                justify="center",
                wraplength=wraplength,
                cursor="hand2",
                command=lambda value=option, selected=variable: selected.set(value),
            )
            button.grid(row=row, column=column, padx=4, pady=4, sticky="nsew")
            frame.columnconfigure(column, weight=1)
            buttons.append((option, button))

        variable.trace_add("write", lambda *_args: self._refresh_tile_group(buttons, variable.get()))
        self._refresh_tile_group(buttons, variable.get())
        return frame

    def _refresh_tile_group(self, buttons, selected_value):
        """Update tile styling to reflect the currently selected option."""
        for option, button in buttons:
            is_selected = option == selected_value
            button.configure(
                bg=self.TILE_SELECTED_BG if is_selected else self.TILE_BG,
                fg=self.TILE_SELECTED_FG if is_selected else self.TILE_FG,
                activebackground=self.TILE_SELECTED_BG if is_selected else self.TILE_BG,
                activeforeground=self.TILE_SELECTED_FG if is_selected else self.TILE_FG,
                highlightbackground=self.TILE_SELECTED_BORDER if is_selected else self.TILE_BORDER,
                highlightcolor=self.TILE_SELECTED_BORDER if is_selected else self.TILE_BORDER,
                highlightthickness=1,
            )

    def _append(self, msg: str):
        """Append text to the log and keep the latest output visible."""
        self.log.insert("end", msg)
        self.log.see("end")

    def clear_log(self):
        """Clear the entire log output widget."""
        self.log.delete("1.0", "end")

    def _build_cmds(self):
        """Translate UI values into one or more concrete Make commands.

        Returns:
            list[list[str]]: command sequence to execute.
        Raises:
            ValueError: if required fields are invalid/missing.
        """
        target = self.target_var.get().strip()
        kat = self.kat_var.get().strip()
        ct_per_sk = self.ct_per_sk_var.get().strip()
        ct_mult = self.ct_mult_var.get().strip()
        arch = self.arch_var.get().strip()
        param = self.param_var.get().strip()

        if not target:
            raise ValueError("Target is required")
        if target == "kem-vectors":
            if not ct_per_sk.isdigit() or int(ct_per_sk) <= 0:
                raise ValueError("CT_PER_SK must be a positive integer")
            return [[
                "bash",
                "-lc",
                f"cd kem && CT_PER_SK={ct_per_sk} ./generate_all_vectors.sh",
            ]]
        if target == "multiply-kem-vectors":
            if not ct_mult.isdigit() or int(ct_mult) <= 0:
                raise ValueError("CT_MULT must be a positive integer")
            return [[
                "bash",
                "-lc",
                f"./utility/multiply_ct_bins.sh {ct_mult} kem/test_vectors/Cipher_Sk",
            ]]
        if target == "clear-test-vectors":
            return [[
                "bash",
                "-lc",
                "count=$(find kem/test_vectors -type f | wc -l); "
                "find kem/test_vectors -type f -print -delete; "
                "echo \"[+] Removed ${count} test vector file(s) from kem/test_vectors\"",
            ]]
        if target == "clear-results":
            return [[
                "bash",
                "-lc",
                "set -eu; "
                "cpu_count=$(find CPU/results -type f 2>/dev/null | wc -l); "
                "gpu_base_count=$(find GPU_Baseline/results GPU_Baseline/profile -type f 2>/dev/null | wc -l); "
                "gpu_opt_count=$(find GPU_Optimised/results GPU_Optimised/profile -type f 2>/dev/null | wc -l); "
                "full_profile_count=$(find full_profile_txt -type f 2>/dev/null | wc -l); "
                "make clean PARAM=all; "
                "find CPU/results -type f -print -delete 2>/dev/null || true; "
                "find full_profile_txt -type f -print -delete 2>/dev/null || true; "
                "echo \"[+] Removed ${cpu_count} CPU result file(s)\"; "
                "echo \"[+] Removed ${gpu_base_count} GPU baseline result file(s)\"; "
                "echo \"[+] Removed ${gpu_opt_count} GPU optimised result file(s)\"; "
                "echo \"[+] Removed ${full_profile_count} copied full-profile file(s)\"",
            ]]
        if not param:
            raise ValueError("PARAM is required")

        if target in {"ncu-reports", "ncu-reports-baseline", "ncu-reports-optimised"}:
            if not kat.isdigit() or int(kat) <= 0:
                raise ValueError("KATNUM must be a positive integer")
            if not arch:
                raise ValueError("ARCH is required for NCU report generation")

            if target == "ncu-reports-baseline":
                project = "baseline"
            elif target == "ncu-reports-optimised":
                project = "optimised"
            else:
                project = "both"

            return [[
                "python3",
                "generate_ncu_reports.py",
                "--project", project,
                "--param", param,
                "--katnum", kat,
                "--arch", arch,
            ]]

        if target in {"render-ncu-txt", "render-ncu-txt-baseline", "render-ncu-txt-optimised"}:
            if not kat.isdigit() or int(kat) <= 0:
                raise ValueError("KATNUM must be a positive integer")
            if not arch:
                raise ValueError("ARCH is required for NCU text import")

            if target == "render-ncu-txt-baseline":
                project = "baseline"
            elif target == "render-ncu-txt-optimised":
                project = "optimised"
            else:
                project = "both"

            cmd = [
                "python3",
                "utility/render_ncu_rep_txt.py",
                "--project", project,
                "--param", param,
                "--katnum", kat,
                "--arch", arch,
            ]
            if self.ncu_overwrite_var.get():
                cmd.append("--overwrite")
            return [cmd]

        cmd = ["make", target, f"PARAM={param}"]

        if target in {
            "all", "run", "output", "full-profile",
            "cpu-all", "cpu-run",
            "gpu-all", "gpu-run", "gpu-output",
            "gpuopt-all", "gpuopt-run", "gpuopt-output",
        }:
            if not kat.isdigit() or int(kat) <= 0:
                raise ValueError("KATNUM must be a positive integer")
            cmd.append(f"KATNUM={kat}")

        if target in {
            "all", "run", "output", "full-profile",
            "gpu-all", "gpu-run", "gpu-output",
            "gpuopt-all", "gpuopt-run", "gpuopt-output",
        }:
            if not arch:
                raise ValueError("ARCH is required for GPU-capable targets")
            cmd.append(f"ARCH={arch}")

        if target == "tri-compare":
            return [
                ["make", "clean", f"PARAM={param}"],
                ["make", "output", f"KATNUM={kat}", f"ARCH={arch}", f"PARAM={param}"],
                ["make", "compare", f"PARAM={param}"],
                ["make", "compare-opt", f"PARAM={param}"],
            ]

        return [cmd]

    def run_make(self):
        """Launch command execution in a background thread."""
        if self.proc is not None:
            return
        try:
            cmds = self._build_cmds()
        except ValueError as e:
            self.status_var.set(f"Input error: {e}")
            return

        self.status_var.set("Running...")
        self.run_btn.config(state="disabled")
        self.stop_btn.config(state="normal")
        for cmd in cmds:
            self._append("\n$ " + " ".join(cmd) + "\n")

        def worker():
            """Execute queued commands serially and stream output safely."""
            try:
                rc = 0
                for cmd in cmds:
                    self.proc = subprocess.Popen(
                        cmd,
                        cwd=ROOT_DIR,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.STDOUT,
                        text=True,
                        bufsize=1,
                    )
                    assert self.proc.stdout is not None
                    for line in self.proc.stdout:
                        self.out_q.put(line)
                    rc = self.proc.wait()
                    if rc != 0:
                        break
                self.out_q.put(f"\n[exit code: {rc}]\n")
                self.out_q.put(("__DONE__", rc))
            except Exception as exc:
                self.out_q.put(f"\n[error] {exc}\n")
                self.out_q.put(("__DONE__", 1))

        threading.Thread(target=worker, daemon=True).start()

    def stop_make(self):
        """Request termination of the currently running process."""
        if self.proc is not None:
            self.proc.terminate()
            self.status_var.set("Stopping...")

    def _drain_queue(self):
        """Consume worker output queue and refresh status/buttons."""
        try:
            while True:
                item = self.out_q.get_nowait()
                if isinstance(item, tuple) and item[0] == "__DONE__":
                    rc = item[1]
                    self.proc = None
                    self.run_btn.config(state="normal")
                    self.stop_btn.config(state="disabled")
                    self.status_var.set("Success" if rc == 0 else "Failed")
                else:
                    self._append(str(item))
        except queue.Empty:
            pass
        self.after(100, self._drain_queue)


if __name__ == "__main__":
    app = MakeGui()
    app.mainloop()
