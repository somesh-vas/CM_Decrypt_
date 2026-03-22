# GPU Optimised Code Map

## End-to-end flow

The optimised tree preserves the same observable behaviour as the baseline tree:

1. host code loads the shared vectors and reconstructs the same secret-key state
2. support and inverse tables are copied to device-side memory or constant
   memory
3. batched ciphertexts are processed by specialised CUDA kernels
4. results are converted back into CPU-compatible errorstream files
5. compare scripts validate those files against CPU output

What changes is the internal representation used to make those stages faster.

## File responsibilities

### Top level

- `GPU_Optimised/Makefile`
  Fans out build/run/output/clean/compare commands to parameter directories.
- `GPU_Optimised/compare_errorstreams.sh`
  Compares CPU and GPU optimised errorstream files.

### Shared interfaces

- `GPU_Optimised/include/common/gf.h`
  Host-side finite-field helpers reused by the parameter directories.
- `GPU_Optimised/include/common/root.h`
  Host-side support generation, root evaluation, and utility declarations.
- `GPU_Optimised/src/common/gf_13.c`
  13-bit finite-field implementation shared by non-348864 families.
- `GPU_Optimised/src/common/root_13.c`
  13-bit support/root implementation shared by non-348864 families.

### Parameter directories

- `param/param*/include/common.h`
  Parameter constants and runtime macros such as `BATCH_SIZE`.
- `param/param*/include/decrypt.h`
  Host/device globals, constant-memory tables, and inline device-side helpers.
- `param/param*/src/host/util.c`
  Vector loading plus support/inverse-table precomputation.
- `param/param*/src/cuda/Decrypt.cu` or `decrypt.cu`
  Optimised CUDA kernels and batch orchestration.
- `param/param348864/src/host/gf.c`
  `348864` finite-field implementation.
- `param/param348864/src/host/root.c`
  `348864` support/root implementation.

## Stage-level ownership

### Stage 1: host-side setup

- `initialisation(...)`
  Loads the secret key and ciphertext batch from `kem/test_vectors/Cipher_Sk/`.
- `compute_inverses()`
  Builds the support-point power table reused by the syndrome stage.
- `InitializeC()`
  Uploads support points, inverse lookup tables, and per-kernel constant-memory
  helpers.

### Stage 2: optimised syndrome generation

- `SyndromeKernel`
  Unpacks ciphertext bytes into a bit array in shared memory and then performs a
  column-wise XOR reduction against the precomputed inverse table.

### Stage 3: packed Berlekamp-Massey

- `berlekampMasseyKernel`
  Stores state in packed/shared-memory form and uses warp reductions to compute
  discrepancies with lower memory traffic than the baseline path.

### Stage 4: warp-oriented Chien evaluation

- `warp_chien_search_kernel`
  Evaluates the locator polynomial across support positions using warp-local
  work distribution and bit-packed error output.

### Stage 5: output and validation

- `decrypt(...)`
  Handles batch-level memory movement, kernel launch configuration, unpacking of
  bit-packed error data, and optional errorstream output.
- `compare_errorstreams.sh`
  Validates the final output against CPU reference files.

## Reading order

1. `param/param6960119/src/cuda/decrypt.cu`
2. `param/param348864/include/decrypt.h`
3. `param/param348864/src/cuda/Decrypt.cu`
4. `compare_errorstreams.sh`

`6960119` is the simplest correctness-first implementation inside this tree.
`348864` is the best example of the packed/shared-memory optimisation strategy.
