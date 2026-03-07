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
    "clean",
    "compare",
    "compare-opt",
    "tri-compare",
    "ncu-reports",
    "ncu-reports-baseline",
    "ncu-reports-optimised",
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
]
# Supported values mapped to current project layout.
PARAMS = ["all", "348864", "460896", "6688128", "8192128"]
ARCHES = ["sm_86", "sm_75"]


class MakeGui(tk.Tk):
    """Main application window for running project automation commands."""

    def __init__(self):
        """Initialize window state, process handles, and UI widgets."""
        super().__init__()
        self.title("Unified CPU/GPU Runner")
        self.geometry("980x620")

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

        ttk.Label(top, text="Target").grid(row=0, column=0, sticky="w")
        self.target_var = tk.StringVar(value="run")
        self.target_cb = ttk.Combobox(top, textvariable=self.target_var, values=TARGETS, state="readonly", width=14)
        self.target_cb.grid(row=1, column=0, padx=(0, 10), sticky="w")

        ttk.Label(top, text="KATNUM").grid(row=0, column=1, sticky="w")
        self.kat_var = tk.StringVar(value="5")
        self.kat_entry = ttk.Entry(top, textvariable=self.kat_var, width=10)
        self.kat_entry.grid(row=1, column=1, padx=(0, 10), sticky="w")

        ttk.Label(top, text="ARCH").grid(row=0, column=2, sticky="w")
        self.arch_var = tk.StringVar(value="sm_86")
        self.arch_cb = ttk.Combobox(top, textvariable=self.arch_var, values=ARCHES, width=10)
        self.arch_cb.grid(row=1, column=2, padx=(0, 10), sticky="w")

        ttk.Label(top, text="PARAM").grid(row=0, column=3, sticky="w")
        self.param_var = tk.StringVar(value="all")
        self.param_cb = ttk.Combobox(top, textvariable=self.param_var, values=PARAMS, state="readonly", width=10)
        self.param_cb.grid(row=1, column=3, padx=(0, 10), sticky="w")

        self.run_btn = ttk.Button(top, text="Run", command=self.run_make)
        self.run_btn.grid(row=1, column=4, padx=(0, 8), sticky="w")

        self.stop_btn = ttk.Button(top, text="Stop", command=self.stop_make, state="disabled")
        self.stop_btn.grid(row=1, column=5, padx=(0, 8), sticky="w")

        self.clear_btn = ttk.Button(top, text="Clear Log", command=self.clear_log)
        self.clear_btn.grid(row=1, column=6, padx=(0, 8), sticky="w")

        self.status_var = tk.StringVar(value="Idle")
        status = ttk.Label(top, textvariable=self.status_var)
        status.grid(row=1, column=7, sticky="w")

        log_frame = ttk.Frame(self, padding=(10, 0, 10, 10))
        log_frame.pack(fill="both", expand=True)

        self.log = tk.Text(log_frame, wrap="none", font=("DejaVu Sans Mono", 10))
        self.log.pack(side="left", fill="both", expand=True)

        yscroll = ttk.Scrollbar(log_frame, orient="vertical", command=self.log.yview)
        yscroll.pack(side="right", fill="y")
        self.log.configure(yscrollcommand=yscroll.set)

        self._append(f"Working directory: {ROOT_DIR}\n")

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
        arch = self.arch_var.get().strip()
        param = self.param_var.get().strip()

        if not target:
            raise ValueError("Target is required")
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

        cmd = ["make", target, f"PARAM={param}"]

        if target in {
            "all", "run", "output",
            "cpu-all", "cpu-run",
            "gpu-all", "gpu-run", "gpu-output",
            "gpuopt-all", "gpuopt-run", "gpuopt-output",
        }:
            if not kat.isdigit() or int(kat) <= 0:
                raise ValueError("KATNUM must be a positive integer")
            cmd.append(f"KATNUM={kat}")

        if target in {
            "all", "run", "output",
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
