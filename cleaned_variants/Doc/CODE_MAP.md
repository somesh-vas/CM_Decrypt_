# Code Map

## High-level flow
1. `Decrypt.c` parses `KATNUM`, allocates ciphertext buffer, calls `initialisation(...)`, then runs the decode loop.
2. `util.c` loads `ct_<param>.bin` and `sk_<param>.bin` from `Cipher_Sk/`, initializes support/polynomial data, and precomputes inverses.
3. For each ciphertext, `Decrypt.c` runs:
   - `synd(...)` for syndrome generation
   - `bm(...)` from common `bm.c` for locator polynomial
   - `root(...)` for error-location evaluation
4. Error positions are appended to `results/output/errorstream0_<param>.bin`.
5. Timing/profile output is written to `results/profile/*.txt`.

## Directory responsibilities
- `Makefile` (top-level): orchestrates build/run/clean for one or all parameters.
- `run_all_variants.sh`: shell wrapper to run all parameters with one `KATNUM`.
- `include/common/`: shared algorithm headers (`bm.h`, `gf.h`, `root.h`).
- `src/common/`: shared implementation (`bm.c`).
- `param/param*/include/common.h`: parameter constants (`SYS_N`, `SYS_T`, byte sizes, macros).
- `param/param*/src/Decrypt.c`: runtime driver and profiling output.
- `param/param*/src/util.c`: input loading and inverse table setup.
- `param/param*/src/gf.c`: finite-field operations for that parameter family.
- `param/param*/src/root.c`: root-finding implementation.
- `results/output/`: generated error streams.
- `results/profile/`: generated timing/profile logs.
- `bin/`: built executables (`decrypt_<param>`).
- `build/`: intermediate object files.

## Build command reference
Run from `cleaned_variants/`.

- Build all: `make all`
- Run all (default `KATNUM=5`): `make run`
- Run all with positional KATNUM: `make run 10`
- Run all with explicit var: `make run KATNUM=10`
- Run single parameter: `make run KATNUM=10 PARAM=460896`
- Clean all: `make clean`
- Clean one parameter: `make clean PARAM=8192128`

## Required input files
The following files must exist in `kem/test_vectors/Cipher_Sk/`:
- `ct_348864.bin`, `sk_348864.bin`
- `ct_460896.bin`, `sk_460896.bin`
- `ct_6688128.bin`, `sk_6688128.bin`
- `ct_6960119.bin`, `sk_6960119.bin`
- `ct_8192128.bin`, `sk_8192128.bin`

Each ciphertext file must contain at least `KATNUM` ciphertexts. Regenerate
them from `kem/` with `CT_PER_SK=<KATNUM> ./generate_all_vectors.sh` when the
runtime count changes.

## Notes for maintainers
- `param460896`, `param6688128`, `param6960119`, `param8192128` share the same 13-bit field style but keep independent source copies in this layout.
- `param6960119` stays on the same CPU algorithm path; its special handling is
  only needed on the GPU-optimised side because `SYS_N=6960` is not 32-bit aligned.
- Top-level make is intentionally quiet (`@` + `--no-print-directory`) to avoid recipe noise.
- Positional `make run 5` support is implemented by converting the second goal into `KATNUM`.
