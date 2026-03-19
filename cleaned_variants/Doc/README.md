# Cleaned Variants Documentation

## Purpose
This directory contains restructured Classic McEliece decryption code for:
- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

The layout separates:
- common code (`include/common`, `src/common`)
- parameter-specific code (`param/param*/`)
- generated artifacts (`bin`, `build`, `results`)

`6960119` follows the same CPU flow as the other 13-bit families, but it uses
its own constants (`SYS_N=6960`, `SYS_T=119`, `crypto_kem_CIPHERTEXTBYTES=194`)
and therefore needs its own `ct_6960119.bin` / `sk_6960119.bin` inputs.

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
- `make run KATNUM=5 PARAM=6960119`: run the new 6960119 parameter only
- `make clean`: clean all parameters
- `make clean PARAM=460896`: clean one parameter

## Input and output
Input files are read from `kem/test_vectors/Cipher_Sk/` (repository root):
- `ct_<param>.bin`
- `sk_<param>.bin`

Each `ct_<param>.bin` must contain at least `KATNUM` ciphertexts. A simple way
to regenerate matching vectors is:

```bash
cd ../kem
CT_PER_SK=5 ./generate_all_vectors.sh
```

Generated files:
- `results/profile/*.txt`
- `results/output/errorstream0_<param>.bin`

## Quick start
```bash
cd cleaned_variants
make clean
make run 5
```
