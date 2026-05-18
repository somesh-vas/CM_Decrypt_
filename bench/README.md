# CM_Decrypt_ optimization iteration harness

This folder defines the repeatable loop for Codex-driven GPU optimization.

## Locked workflow assumptions

```text
Remote system: yes
Root/sudo: no sudo, no root assumptions
GPU: NVIDIA GeForce RTX 3090 Ti, CC 8.6, 84 SMs
nvcc: CUDA 12.8, V12.8.61
ncu: Nsight Compute 2025.1.0.0
Compile target for comparison: ARCH=sm_75
Default params: all supported params
Default KATNUM: 50000
Correctness oracle: existing CPU errorstream0_<param>.bin files
Input vectors: kem/test_vectors/Cipher_Sk/ct_<param>.bin and sk_<param>.bin
```

Important: an optimization iteration must **not regenerate CPU outputs**. CPU/reference outputs are treated as stable and already generated. The runner only rebuilds/runs `GPU_Optimised`, then compares its output against existing CPU errorstreams.

## What one iteration does

`bench/run_iteration.py` creates a timestamped directory under `bench/results/` and saves:

- `codex_change.md` — what Codex changed or attempted.
- `git/` — current HEAD, branch, status, and diff.
- `device/device_report.txt` and `device/device_summary.json` — GPU/driver/CUDA/Nsight information.
- `preflight_reference_files.json` — confirms existing CPU outputs and KEM vectors are present.
- `outputs/` — CPU reference and GPU-Optimised errorstreams used for comparison.
- `profiles/` — GPU-Optimised timing summaries and Nsight Compute text logs.
- `profiles/param*/metrics.json` — parsed per-param metrics.
- `summary.md` and `summary.json` — per-param pass/fail and throughput metrics.
- `bench/results/metrics_history.csv` — append-only trend table across all iterations.

The runner copies only text/JSON/CSV artifacts into `bench/results/`. Heavy `.ncu-rep` files stay in project-local profiling folders and are not copied into benchmark results.

## Correctness gate

For each parameter, correctness uses:

```bash
make gpuopt-output PARAM=<param> KATNUM=50000 ARCH=sm_75
make compare-opt PARAM=<param>
```

It deliberately does **not** run:

```bash
make output ...
make cpu-run ...
```

because those can regenerate expensive CPU/reference outputs.

## Profiling gate

If correctness passes, the runner profiles only the optimized GPU implementation:

```bash
python3 generate_ncu_reports.py \
  --project optimised \
  --param <param> \
  --katnum 50000 \
  --arch sm_75 \
  --skip-on-permission-error
```

Your direct NCU smoke command is:

```bash
ncu --target-processes all --set full ./GPU_Optimised/bin/decrypt_gpu_optimised_348864 2>&1 | head -80 > test.txt
```

The attached smoke text showed Nsight Compute successfully connected and profiled `SyndromeKernel`, `berlekampMasseyKernel`, and `warp_chien_search_kernel`; there was no `ERR_NVGPUCTRPERM` permission block. It also printed `Error opening optimised GPU test vectors: No such file or directory`, so the harness records vector presence and runs project commands from repo root to avoid path mistakes.

## Run the default all-parameter loop

From repo root, after Codex makes a code change:

```bash
python3 bench/run_iteration.py \
  --label <short-change-name> \
  --codex-note "<describe exactly what Codex changed>" \
  --params all \
  --arch sm_75 \
  --katnum 50000 \
  --commit --push
```

For a faster local smoke pass without Nsight Compute:

```bash
python3 bench/run_iteration.py \
  --label smoke-test \
  --params 348864,6960119 \
  --arch sm_75 \
  --katnum 50000 \
  --skip-ncu
```

## Commit behavior

Recommended branch strategy:

```text
Code changes: PR branch
Benchmark results: same PR branch under bench/results/
```

By default, the runner uses:

```text
--commit-mode all
--failure-action commit-and-revert
```

That means:

- If correctness/profiling passes, it commits code changes and benchmark artifacts together.
- If correctness fails, it creates a failure commit with logs, then reverts failed code while preserving the failure logs/history.

## Success metrics

Primary gate:

```text
Correctness must pass for every selected parameter.
```

Secondary metric:

```text
Total GPU-Optimised decryptions/sec.
```

Diagnostic metrics:

```text
Chien search ms
Chien percentage of kernel time
registers/thread
achieved occupancy
compute throughput
memory throughput
```

## Analysis loop

After each run, point me to:

1. `bench/results/<iteration>/summary.md`
2. `bench/results/<iteration>/codex_change.md`
3. `bench/results/<iteration>/profiles/param*/metrics.json`
4. `bench/results/metrics_history.csv`
5. Any relevant `logs/param*/03_ncu_optimised.log`

I will compare the current iteration against previous rows and decide whether to keep, revert, or refine the change.
