# CPU Code Map

## End-to-end flow

Every CPU executable follows the same sequence:

1. `main()` in `param/param*/src/Decrypt.c` or `decrypt.c`
   parses `KATNUM`, allocates the ciphertext buffer, and calls
   `initialisation(...)`.
2. `initialisation(...)` in `param/param*/src/util.c`
   reads `ct_<param>.bin` and `sk_<param>.bin`, then reconstructs:
   - the Goppa polynomial `g`
   - the support set `L`
3. `compute_inverses()` in `util.c`
   precomputes support-point powers used during syndrome generation.
4. For each ciphertext, the driver calls:
   - `synd(...)`
   - `bm(...)`
   - `root(...)`
5. The driver converts zero-valued root images into set bits in the error
   vector and writes one line to `results/output/errorstream0_<param>.bin`.

## File responsibilities

### Top level

- `CPU/Makefile`
  Fans out build/run/clean commands to all parameter subdirectories.

### Shared interfaces

- `CPU/include/common/bm.h`
  Berlekamp-Massey interface.
- `CPU/include/common/gf.h`
  Finite-field load/store/arithmetic helpers.
- `CPU/include/common/root.h`
  Support generation, Benes permutation helpers, root evaluation, and
  CPU-side input-loading helpers.

### Shared implementations

- `CPU/src/common/bm.c`
  Constant-time Berlekamp-Massey over the syndrome sequence.
- `CPU/src/common/gf_13.c`
  13-bit family finite-field arithmetic and byte packing helpers.
- `CPU/src/common/root_13.c`
  Support generation, Benes network permutation, polynomial evaluation, and
  root lookup across the support set.

### Parameter directories

- `CPU/param/param*/include/common.h`
  Compile-time constants for that Classic McEliece parameter family.
- `CPU/param/param*/src/Decrypt.c`
  Runtime driver, timing collection, and errorstream output.
- `CPU/param/param*/src/util.c`
  Shared vector loading plus inverse-table precomputation.
- `CPU/param/param348864/src/gf.c`
  `348864` finite-field implementation.
- `CPU/param/param348864/src/root.c`
  `348864` support/root implementation.

## Stage-level ownership

### Stage 1: input loading

- `initialisation(...)`
  Reads the test-vector files, extracts the secret-key payload after the
  metadata prefix, decodes the Goppa polynomial, and calls `support_gen(...)`.

### Stage 2: syndrome preparation

- `compute_inverses()`
  Builds `inverse_elements[bit][power]`, which lets `synd(...)` reuse the same
  secret-key-derived table for every ciphertext in the batch.
- `synd(...)`
  Walks the ciphertext bitstream and XOR-accumulates the corresponding prebuilt
  table rows into `2 * SYS_T` syndrome coefficients.

### Stage 3: locator recovery

- `bm(...)`
  Consumes the syndrome sequence and returns the error-locator polynomial.

### Stage 4: root evaluation

- `root(...)`
  Evaluates the locator polynomial at every support point.
- driver code in `Decrypt.c`
  Converts zero-valued evaluations into a packed error vector and writes the
  error positions in text form.

## Build command reference

Run from `CPU/`.

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
