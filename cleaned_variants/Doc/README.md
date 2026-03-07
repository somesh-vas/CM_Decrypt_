# Cleaned Variants Documentation

## Purpose
This directory contains restructured Classic McEliece decryption code for:
- `348864`
- `460896`
- `6688128`
- `8192128`

The layout separates:
- common code (`include/common`, `src/common`)
- parameter-specific code (`param/param*/`)
- generated artifacts (`bin`, `build`, `results`)

## Structure
- `Makefile`: top-level orchestrator for all params
- `run_all_variants.sh`: shell runner for all params
- `include/common/`: common headers
- `src/common/`: common C sources
- `param/param*/include/common.h`: parameter constants
- `param/param*/src/*.c`: parameter implementations
- `param/param*/Makefile`: parameter build/run rules
- `bin/`: generated executables
- `build/`: generated object files
- `results/profile/`: generated profile logs
- `results/output/`: generated error streams
- `Doc/CODE_MAP.md`: detailed code map and command reference

## Commands
Run from `cleaned_variants/`.

- `make all`: build all parameters
- `make run`: run all with default `KATNUM=5`
- `make run 5`: run all with positional `KATNUM`
- `make run KATNUM=12`: run all with explicit `KATNUM`
- `make run KATNUM=12 PARAM=460896`: run one parameter only
- `make clean`: clean all parameters
- `make clean PARAM=460896`: clean one parameter

## Input and output
Input files are read from `Cipher_Sk/` (relative to each param source path):
- `ct_<param>.bin`
- `sk_<param>.bin`

Generated files:
- `results/profile/*.txt`
- `results/output/errorstream0_<param>.bin`

## Quick start
```bash
cd cleaned_variants
make clean
make run 5
```
