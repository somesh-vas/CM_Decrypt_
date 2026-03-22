# GPU Baseline Documentation

## Purpose

`GPU_Baseline/` maps the same logical decryption stages used by `CPU/` onto a
straightforward CUDA pipeline:

1. host code loads the shared vectors and reconstructs secret-key state
2. ciphertexts are processed in batches on the GPU
3. dedicated kernels run syndrome generation, Berlekamp-Massey, and Chien/root
   search
4. optional error streams are copied back and written in CPU-compatible format
5. timing summaries are written to `results/profile/`

This tree is the correctness-first CUDA implementation in the workspace.

## Supported parameters

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

## Layout

- `Makefile`
  Orchestrates build/run/output/compare across all supported parameters.
- `include/common/`
  Shared finite-field and root-function interfaces used by the host side.
- `param/param*/include/common.h`
  Parameter constants and CUDA build-time settings such as `BATCH_SIZE`.
- `param/param*/include/decrypt.h`
  Shared host/device globals plus device-side finite-field helpers.
- `param/param*/src/host/util.c`
  Test-vector loading, support reconstruction, inverse-table generation, and
  CPU-side syndrome helper.
- `param/param*/src/cuda/Decrypt.cu` or `decrypt.cu`
  CUDA kernels, batch orchestration, timing collection, and optional
  errorstream emission.
- `compare_errorstreams.sh`
  Byte-level CPU-vs-GPU comparison helper.
- `results/output/`
  Generated `errorstream0_<param>.bin` files.
- `results/profile/`
  Human-readable timing summaries.

## Reading order

1. `param/param6960119/src/cuda/decrypt.cu`
2. `param/param6960119/src/host/util.c`
3. `include/common/root.h`
4. `Doc/CODE_MAP.md`

`6960119` is the easiest baseline CUDA entry point to read because it uses a
clear helper structure and keeps the runtime reporting compact.

## Commands

Run from `GPU_Baseline/`.

- `make all`
- `make all PARAM=460896`
- `make run`
- `make run PARAM=460896`
- `make output PARAM=6960119 KATNUM=5`
- `make compare PARAM=6960119`
- `make clean`
- `make clean PARAM=8192128`

Override architecture if needed:

- `make all ARCH=sm_86`

## Prerequisite vectors

Before running a parameter, generate matching vectors in `kem/` so that
`ct_<param>.bin` contains at least `KATNUM` ciphertexts:

```bash
cd ../kem
CT_PER_SK=5 ./generate_all_vectors.sh
```

## Outputs

Profiles are written to:

- `results/profile/Profile_GPU_baseline_<param>.txt`

`make output` also writes:

- `results/output/errorstream0_<param>.bin`

That file can then be compared against CPU output with:

```bash
make compare PARAM=<param>
```

## Notes for maintainers

- The baseline kernels are intentionally direct translations of the CPU stages.
- Comments in the CUDA files focus on data layout, kernel ownership, and batch
  boundaries so the CPU/GPU relationship stays easy to follow.
- Compare scripts treat the CPU output as the correctness source of truth.
