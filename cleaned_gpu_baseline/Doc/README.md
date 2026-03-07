# Cleaned GPU Baseline

## Purpose
Restructured GPU baseline variants with centralized build/output layout and dynamic top-level control.

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
- `make clean`
- `make clean PARAM=8192128`

Override architecture if needed:
- `make all ARCH=sm_86`

## Input files
Each param reads:
- `../../../../Cipher_Sk/ct_<param>.bin`
- `../../../../Cipher_Sk/sk_<param>.bin`

## Outputs
Profiles are written to:
- `results/profile/Profile_GPU_baseline_<param>.txt`
