# CM_Decrypt_ optimization iteration harness

This folder defines the repeatable loop for Codex-driven GPU optimization.

Default target for this workflow:

```text
ARCH=sm_75
params=348864,6960119
correctness oracle=CPU errorstream output
profile source=existing make full-profile / Nsight Compute flow
```

## What one iteration does

`bench/run_iteration.py` creates a timestamped directory under `bench/results/` and saves:

- `codex_change.md` — what Codex changed or attempted.
- `git/` — current HEAD, branch, status, and diff.
- `device/device_report.txt` and `device/device_summary.json` — GPU/driver/CUDA/Nsight information.
- `outputs/` — CPU and GPU-Optimised errorstreams used for correctness comparison.
- `profiles/` — copied wall-time profile summaries and, when enabled, Nsight Compute text/`.ncu-rep` artifacts.
- `summary.md` and `summary.json` — per-param pass/fail and throughput metrics.
- `bench/results/metrics_history.csv` — append-only trend table across all iterations.

Correctness is checked before profiling. By default, profiling is skipped for a parameter if CPU-vs-GPU correctness fails.

## Run the default two-parameter loop

From repo root, after Codex makes a code change:

```bash
python3 bench/run_iteration.py \
  --label ballot-pack-v1 \
  --codex-note-file bench/iteration_note.md \
  --params 348864,6960119 \
  --arch sm_75 \
  --correctness-katnum 5 \
  --profile-katnum 50000 \
  --commit --push
```

For a faster dry profiling pass without Nsight Compute:

```bash
python3 bench/run_iteration.py \
  --label smoke-test \
  --params 348864,6960119 \
  --arch sm_75 \
  --correctness-katnum 5 \
  --profile-katnum 5000 \
  --skip-ncu
```

If Nsight Compute counters require admin access:

```bash
python3 bench/run_iteration.py --label ncu-run --sudo
```

## Commit behavior

`--commit --push` saves the iteration artifacts and `metrics_history.csv` to GitHub.

By default, only benchmark artifacts are committed. Use `--commit-mode all` only when you intentionally want to commit Codex source changes together with the benchmark artifacts.

## Analysis loop

After each run, share or point me to:

1. `bench/results/<iteration>/summary.md`
2. `bench/results/<iteration>/codex_change.md`
3. `bench/results/<iteration>/profiles/param*/metrics.json`
4. Nsight text under `bench/results/<iteration>/profiles/param*/ncu/`, when available
5. `bench/results/metrics_history.csv`

I will compare the current iteration against previous rows and decide whether to keep, revert, or refine the change.
