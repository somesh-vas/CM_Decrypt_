# CPU Decryption Documentation

## Purpose

`CPU/` is the easiest place to understand the decryption pipeline in this
workspace. Each parameter-specific executable:

1. reads one shared secret key and `KATNUM` ciphertexts from `kem/`
2. reconstructs the support and Goppa polynomial from the secret key
3. runs syndrome generation, Berlekamp-Massey, and root evaluation
4. writes one `errorstream0_<param>.bin` line per ciphertext
5. prints timing/profile output for that run

The CPU tree is the reference contract used by both GPU compare flows.

## Layout

- `Makefile`
  Top-level CPU orchestrator for build/run/clean across all parameters.
- `include/common/`
  Shared algorithm interfaces: finite-field helpers, Berlekamp-Massey, root
  evaluation, and input-loading helpers.
- `src/common/`
  Shared implementations used by the 13-bit families.
- `param/param*/include/common.h`
  Parameter constants such as `SYS_N`, `SYS_T`, ciphertext size, and `KATNUM`.
- `param/param*/src/Decrypt.c` or `decrypt.c`
  Runtime entry point, stage timing, and errorstream output.
- `param/param*/src/util.c`
  Test-vector loading, secret-key decoding, inverse-table precomputation, and
  syndrome construction.
- `param/param348864/src/gf.c`, `param/param348864/src/root.c`
  348864-specific finite-field and root routines.
- `results/output/`
  Generated `errorstream0_<param>.bin` files.
- `results/profile/`
  Generated timing/profile reports.

## Reading order

For a code walkthrough, read the files in this order:

1. `param/param6960119/src/decrypt.c`
2. `param/param6960119/src/util.c`
3. `src/common/bm.c`
4. `src/common/root_13.c`
5. `src/common/gf_13.c`
6. `Doc/CODE_MAP.md`

`6960119` is the cleanest starting point because its driver/util files already
split the flow into small helper functions with explicit names.

## Commands

Run from `CPU/`.

- `make all`
- `make run`
- `make run 5`
- `make run KATNUM=12`
- `make run KATNUM=12 PARAM=460896`
- `make run KATNUM=5 PARAM=6960119`
- `make clean`
- `make clean PARAM=460896`

## Inputs and outputs

Input files are read from `kem/test_vectors/Cipher_Sk/` at repository root:

- `ct_<param>.bin`
- `sk_<param>.bin`

Each ciphertext file must contain at least `KATNUM` ciphertexts. A simple way
to regenerate matching vectors is:

```bash
cd ../kem
CT_PER_SK=5 ./generate_all_vectors.sh
```

Generated files:

- `results/profile/*.txt`
- `results/output/errorstream0_<param>.bin`

## Notes for maintainers

- The per-parameter drivers are intentionally thin. Most algorithm work lives in
  `util.c`, `bm.c`, `root_13.c`, and `gf_13.c`.
- The CPU errorstream output format is the canonical compare target for both GPU
  projects.
- The parameter directories stay separate even when code is similar, because the
  build system and file names are parameter-specific.
