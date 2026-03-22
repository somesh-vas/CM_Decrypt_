# GPU Optimised Documentation

## Purpose

`GPU_Optimised/` keeps the same external contract as `GPU_Baseline/` while
changing the internal CUDA strategy to reduce overhead:

1. host code still loads the same vectors and reconstructs the same secret-key
   state
2. syndrome generation uses a more cache- and layout-aware CUDA path
3. Berlekamp-Massey uses packed/shared-memory state to reduce traffic
4. Chien evaluation uses warp-oriented bit-packed output where appropriate
5. the final errorstream still matches the CPU format for compare runs

This makes `GPU_Optimised/` the performance-focused tree, but not a different
algorithm.

## Supported parameters

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

## Layout

- `Makefile`
  Orchestrates build/run/output/compare across the optimised CUDA variants.
- `include/common/`
  Shared host-side interfaces reused by parameter directories.
- `param/param*/include/common.h`
  Parameter constants and CUDA batch settings.
- `param/param*/include/decrypt.h`
  Host/device globals, lookup tables, and device-side GF helpers.
- `param/param*/src/host/util.c`
  Vector loading and support/inverse precomputation.
- `param/param*/src/cuda/Decrypt.cu` or `decrypt.cu`
  Optimised CUDA kernels plus batch orchestration and output handling.
- `compare_errorstreams.sh`
  CPU-vs-GPU-optimised compare helper.
- `results/output/`
  Generated `errorstream0_<param>.bin` files.
- `results/profile/`
  Human-readable timing summaries.

## Reading order

1. `param/param6960119/src/cuda/decrypt.cu`
2. `param/param348864/src/cuda/Decrypt.cu`
3. `param/param348864/include/decrypt.h`
4. `Doc/CODE_MAP.md`

`6960119` is the best entry point for correctness-first behaviour inside this
tree. `348864` is the best example of the packed/warp-oriented optimised path.

## Commands

Run from `GPU_Optimised/`.

- `make all`
- `make run`
- `make output`
- `make clean`
- `make compare`

Supports dynamic values:

- `make run 5 sm_75 PARAM=460896`
- `make run 5 sm_86 PARAM=6960119`
- `make output 2 sm_86 PARAM=8192128`
- `make output 5 sm_86 PARAM=6960119`
- `make compare PARAM=6960119`

## Behavior

- `run`
  Writes profile text only.
- `output`
  Writes profile text and `results/output/errorstream0_<param>.bin`.
- `compare`
  Performs a read-only CPU-vs-GPU-optimised errorstream comparison.

## `6960119` note

`param6960119` is intentionally implemented with the verified baseline-style
CUDA pipeline inside this tree. The older bit-packed specialisation assumed a
layout that fit the other parameter families more naturally, while
`SYS_N = 6960` is not a safe drop-in for that strategy.

## Notes for maintainers

- The optimised code should always be read relative to the baseline code, since
  both trees implement the same logical decode stages.
- The most useful comments in the CUDA files describe layout transforms, packed
  representations, and which level of parallelism owns each stage.
