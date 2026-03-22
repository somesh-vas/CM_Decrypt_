# Classical McEliece Decryption Workspace

This repository is a unified workspace for generating Classic McEliece test
vectors and validating decryption across three execution paths:

- `CPU/`: CPU reference-style decryption drivers and profiling
- `GPU_Baseline/`: correctness-first CUDA decryption and compare helpers
- `GPU_Optimised/`: faster CUDA variants that still emit CPU-comparable output

All three paths consume the same ciphertext and secret-key fixtures generated
from `kem/`, which makes byte-for-byte CPU/GPU comparison straightforward.

## Why this repo exists

The workspace is organized around reproducible decryption experiments:

- generate one shared test-vector set per parameter family
- run CPU and GPU implementations against identical inputs
- compare emitted error streams instead of relying on console output
- keep profile artifacts in predictable locations for later analysis

That setup makes it easier to benchmark, validate, and extend the code than
running each implementation in isolation.

## Supported parameter sets

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

### `6960119` note

`6960119` is fully wired through:

- KEM vector generation
- CPU decryption
- GPU baseline decryption
- GPU optimised decryption
- compare scripts and top-level Make orchestration

Inside `GPU_Optimised/`, `6960119` intentionally uses a correctness-first CUDA
path that mirrors the verified baseline flow. The earlier bit-packed
specialisation assumed parameter sizes that fit more cleanly into the packed
layout, so this variant stays closer to the CPU/baseline algorithm for safety.

## Repository map

### Main directories

- `kem/`
  Builds shared input vectors under `kem/test_vectors/Cipher_Sk/`.
- `CPU/`
  CPU binaries, error streams, timing reports, and CPU code-reading docs.
- `GPU_Baseline/`
  Baseline CUDA binaries, error streams, profiling output, and compare tools.
- `GPU_Optimised/`
  Optimised CUDA implementations with the same input/output contract.
- `utility/`
  Helper scripts for vector multiplication, full profiling, and environment
  reporting.

### Documentation entry points

- `README_UNIFIED.md`
  Top-level Makefile command reference.
- `kem/README.md`
  Test-vector generation workflow.
- `CPU/Doc/README.md`
  CPU architecture and run flow.
- `CPU/Doc/CODE_MAP.md`
  CPU file-by-file code map.
- `GPU_Baseline/Doc/README.md`
  Baseline CUDA architecture and workflow.
- `GPU_Baseline/Doc/CODE_MAP.md`
  Baseline CUDA file-by-file code map.
- `GPU_Optimised/Doc/README.md`
  Optimised CUDA architecture and workflow.
- `GPU_Optimised/Doc/CODE_MAP.md`
  Optimised CUDA file-by-file code map.

## Code reading guide

If you are new to the codebase, this order is the fastest way to understand it:

1. Start at the root `Makefile` to see how CPU, GPU baseline, and GPU optimised
   runs are orchestrated.
2. Read `CPU/Doc/CODE_MAP.md` for the simplest end-to-end decoding path.
3. Read `GPU_Baseline/Doc/CODE_MAP.md` to see how the same stages are mapped to
   CUDA kernels and batch processing.
4. Read `GPU_Optimised/Doc/CODE_MAP.md` to understand the packed/warp-oriented
   optimisations layered on top of the same algorithmic stages.
5. Use `kem/README.md` and `kem/generate_all_vectors.sh` when you need to
   regenerate or scale the shared input vectors.

The maintained, workspace-specific code is concentrated in the CPU/GPU trees,
their docs, the root Makefiles, and the helper scripts. The `kem/common` and
`kem/variant_*` internals are primarily the reference/vector-generation side of
the project.

## Data flow

Every implementation follows the same high-level pipeline:

1. `kem/` generates one secret key and one ciphertext batch for each parameter.
2. CPU and GPU projects load the matching `ct_<param>.bin` and `sk_<param>.bin`
   files.
3. Each implementation reconstructs the support/Goppa state from the secret key.
4. Each ciphertext runs through the same logical stages:
   syndrome generation, Berlekamp-Massey, and root/Chien evaluation.
5. The resulting error positions are written to `errorstream0_<param>.bin`.
6. Compare helpers check whether the GPU output matches the CPU output exactly.

This makes the correctness contract simple: if the compare target passes, the
GPU path matched the CPU error locations for that parameter and `KATNUM`.

## Prerequisites

### Required build tools

- `gcc`
- `make`
- `bash`
- `libcrypto` / OpenSSL
- `libkeccak`

### GPU requirements

- `nvcc`
- CUDA runtime libraries
- a CUDA-capable GPU

### Optional tooling

- `ncu` for Nsight Compute profiling

## Quick start

Generate shared vectors first. `CT_PER_SK` should be greater than or equal to
the runtime `KATNUM` you plan to use later.

```bash
cd kem
CT_PER_SK=5 ./generate_all_vectors.sh
```

Run the `6960119` validation flow from the repository root:

```bash
make cpu-run KATNUM=5 PARAM=6960119
make gpu-output KATNUM=5 ARCH=sm_86 PARAM=6960119
make gpuopt-output KATNUM=5 ARCH=sm_86 PARAM=6960119
make compare PARAM=6960119
make compare-opt PARAM=6960119
```

Expected success signal:

```text
COMPARE_STATUS=PASS
```

## Project-local workflows

If you prefer to drive each project directly, the equivalent commands are:

```bash
cd CPU
make run KATNUM=5 PARAM=6960119

cd ../GPU_Baseline
make output KATNUM=5 PARAM=6960119

cd ../GPU_Optimised
make output KATNUM=5 PARAM=6960119
```

## Top-level Makefile usage

The root Makefile provides a unified entry point for the repository.

### Common targets

- `make all [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make run [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make output [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make clean [PARAM=<id|all>]`
- `make compare [PARAM=<id|all>]`
- `make compare-opt [PARAM=<id|all>]`
- `make full-profile [PARAM=<id|all>] [KATNUM=<n>] [ARCH=<sm_xx>]`

### Examples

```bash
make run 5 sm_86 PARAM=6960119
make output 5 sm_86 PARAM=6960119
make compare PARAM=6960119
make compare-opt PARAM=6960119
make full-profile PARAM=6960119 KATNUM=5 ARCH=sm_86
```

If Nsight Compute is blocked by admin-only GPU counters (`RmProfilingAdminOnly=1`),
`make full-profile` now finishes with the profiling steps marked as `SKIP`.
Use `SUDO=1` if you want the run to prompt for elevated profiling access, or
`SKIP_NCU=1` to disable Nsight Compute entirely.

## NCU report import

Existing Nsight Compute `.ncu-rep` files can be converted into readable
kernel-level `.txt` reports without rerunning profiling:

```bash
python3 utility/render_ncu_rep_txt.py --project baseline --param 6688128 --katnum 10 --arch sm_86
```

The same import flow is also available in `python3 gui_runner.py` through the
`render-ncu-txt*` targets.

## Output locations

### Shared input vectors

- `kem/test_vectors/Cipher_Sk/ct_<param>.bin`
- `kem/test_vectors/Cipher_Sk/sk_<param>.bin`

### CPU output

- `CPU/results/output/errorstream0_<param>.bin`
- `CPU/results/profile/Profile_CM_<param>.txt`

### GPU baseline output

- `GPU_Baseline/results/output/errorstream0_<param>.bin`
- `GPU_Baseline/results/profile/Profile_GPU_baseline_<param>.txt`

### GPU optimised output

- `GPU_Optimised/results/output/errorstream0_<param>.bin`
- `GPU_Optimised/results/profile/Profile_GPU_optimised_<param>.txt`

## Development notes

- Vector generation and runtime execution are intentionally decoupled.
- The docs under each project directory are meant to mirror the code layout, so
  they are the best place to start when a source file name is unfamiliar.
- The inline comments added in the maintained CPU/GPU code focus on stage
  boundaries, data ownership, and memory layout rather than repeating obvious C
  syntax.
