# Cleaned GPU Baseline

## Purpose
Restructured GPU baseline variants with centralized build/output layout and dynamic top-level control.

## Supported parameters

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

## Structure
- `Makefile`: run/build/clean one or all parameters
- `include/common/`: shared headers
- `param/param*/`: parameter-specific CUDA+host sources and Makefile
- `bin/`: generated executables (`decrypt_gpu_baseline_<param>`)
- `build/`: object files grouped by parameter
- `results/profile/`: timing/profile outputs
- `run_all_variants.sh`: convenience runner

## Commands
Run from `cleaned_gpu_baseline/`:
- `make all` (all params, default `ARCH=sm_86`)
- `make all PARAM=460896`
- `make run` (all params)
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

## Input files
Each param reads:
- `kem/test_vectors/Cipher_Sk/ct_<param>.bin`
- `kem/test_vectors/Cipher_Sk/sk_<param>.bin`

## Outputs
Profiles are written to:
- `results/profile/Profile_GPU_baseline_<param>.txt`

`make output` also writes `results/output/errorstream0_<param>.bin`, which can
be compared against the CPU output with `make compare PARAM=<param>`.
