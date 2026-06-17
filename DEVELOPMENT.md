# Development Guide

This repository is organized for a final thesis review of Classic McEliece
decryption on CPU and CUDA. The source layout stays explicit and
parameter-specialized so the validated CPU, baseline GPU, and optimized GPU
states are easy to inspect.

## Source Layout

- `CPU/`: CPU reference implementation and per-parameter drivers.
- `GPU_Baseline/`: naive GPU baseline implementation.
- `GPU_Optimised/`: optimized GPU implementation.
- `kem/`: vector-generation code and Classic McEliece KEM support.
- `utility/`: local helper scripts for environment, profiling, and vector workflows.
- `bench/tools/`: maintained final benchmark and parsing tools.

The duplicated per-parameter CUDA files are intentional. They preserve the
validated implementation state for each parameter family and avoid a late
cross-parameter refactor of benchmark-critical code.

## Final Benchmark Tools

The final 1,000,000-ciphertext workflow is represented by:

- `bench/tools/run_final_defense_1m_manual.sh`
- `bench/tools/compare_final_defense_chunks.py`
- `bench/tools/parse_final_defense_manual_results.py`

These scripts are the maintained benchmark tools for final review. Older
experiment-only parsers and sweep utilities are not part of the professor-facing
repository.

## Final Metrics

The tracked final metric artifact is:

- `bench/results/final_1m_summary.md`

Only lightweight 1M summaries should be tracked. Raw logs, profiles, generated
output streams, large generated files, and transient run markers should remain
local. Historical 500k result material is not part of the final repository.

## Generated Artifact Policy

Do not commit generated binaries, object files, executable build outputs, raw
logs, profiler reports, output streams, local exports, or build directories.
If a generated artifact was previously tracked, remove it from the Git index
with `git rm --cached` so the local copy remains available.

## Reproducibility Notes

- Generate vectors through `kem/` before running CPU or GPU decryption.
- Use the root `Makefile` for normal CPU/GPU runs and comparisons.
- Use the final 1M benchmark tools only when reproducing final thesis metrics.
- Do not change cryptographic algorithms or output formats during cleanup.
