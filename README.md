# Classic McEliece Decryption CPU/GPU Project

This repository contains a Classic McEliece decryption workspace with three
implementations that share the same test vectors:

- `CPU/`: CPU reference implementation.
- `GPU_Baseline/`: naive CUDA baseline implementation.
- `GPU_Optimised/`: optimized CUDA implementation.

The project goal is to validate correctness across CPU and GPU decryption paths
and report final 1,000,000-ciphertext benchmark metrics for thesis review.

## Supported Parameter Sets

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

## Repository Structure

- `Makefile`: top-level build, run, and comparison entry point.
- `CPU/`: CPU source, parameter-specific builds, and local run targets.
- `GPU_Baseline/`: baseline CUDA source and comparison helper.
- `GPU_Optimised/`: optimized CUDA source and comparison helper.
- `kem/`: Classic McEliece KEM code used to generate ciphertext and secret-key fixtures.
- `utility/`: helper scripts for environment and profiling workflows.
- `bench/tools/`: final 1M benchmark and parsing tools.
- `bench/results/`: lightweight final benchmark summaries and cleanup audit reports.

Generated binaries, raw output streams, build directories, logs, profiler
reports, and local export folders are intentionally excluded from Git.

## Prerequisites

- `gcc`
- `make`
- `bash`
- OpenSSL development libraries
- `libkeccak`
- CUDA toolkit with `nvcc` for GPU builds

Set the CUDA architecture with `ARCH=sm_75`, `ARCH=sm_86`, or another value
appropriate for the target GPU.

## Generate Test Vectors

Generate shared ciphertext and secret-key inputs before running CPU or GPU
decryption. Choose `CT_PER_SK` at least as large as the `KATNUM` used later.

```bash
cd kem
CT_PER_SK=1000 ./generate_all_vectors.sh
cd ..
```

## Run CPU Reference

```bash
make cpu-run PARAM=6960119 KATNUM=1000
```

## Run Naive GPU Baseline

```bash
make gpu-output PARAM=6960119 KATNUM=1000 ARCH=sm_86
```

## Run Optimized GPU

```bash
make gpuopt-output PARAM=6960119 KATNUM=1000 ARCH=sm_86
```

## Compare Outputs

Compare the GPU output streams against the CPU reference output:

```bash
make compare PARAM=6960119
make compare-opt PARAM=6960119
```

A successful comparison prints:

```text
COMPARE_STATUS=PASS
```

## Reproduce Final 1M Benchmark

The final manual benchmark driver is:

```bash
bench/tools/run_final_defense_1m_manual.sh
```

This script expects the required vectors and CUDA environment to already be
available. It is retained for reproducibility, but benchmark outputs are not
regenerated as part of repository cleanup.

## Final Metrics

Lightweight final 1,000,000-ciphertext results are kept under:

```text
bench/results/final-1m-benchmark_20260521_214553/
bench/results/final-defense-1m-manual_20260526T083846Z/
```

These folders keep summary, metrics, and comparison files only. Raw logs,
profiles, generated binaries, and output streams are excluded from Git.
