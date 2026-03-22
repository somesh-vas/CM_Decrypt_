# GPU Baseline Code Map

## End-to-end flow

Each GPU baseline executable follows the same host/device sequence:

1. host globals are populated from `sk_<param>.bin` and `ct_<param>.bin`
2. `InitializeC()` copies support/inverse tables to device-visible memory
3. batched ciphertexts are copied to the GPU
4. CUDA kernels run:
   - syndrome generation
   - Berlekamp-Massey
   - Chien/root search
5. optional error vectors are copied back and written to
   `results/output/errorstream0_<param>.bin`
6. timing summaries are written to `results/profile/`

## File responsibilities

### Top level

- `GPU_Baseline/Makefile`
  Fans out build/run/output/clean/compare commands to parameter directories.
- `GPU_Baseline/compare_errorstreams.sh`
  Compares CPU and GPU baseline errorstream files.

### Shared interfaces

- `GPU_Baseline/include/common/gf.h`
  Host-side finite-field helpers reused by the parameter directories.
- `GPU_Baseline/include/common/root.h`
  Host-side support generation, root evaluation, and utility function
  declarations.
- `GPU_Baseline/src/common/gf_13.c`
  13-bit finite-field implementation shared by non-348864 families.
- `GPU_Baseline/src/common/root_13.c`
  13-bit support/root implementation shared by non-348864 families.

### Parameter directories

- `param/param*/include/common.h`
  Parameter constants and runtime macros such as `KATNUM` and `BATCH_SIZE`.
- `param/param*/include/decrypt.h`
  Host/device globals plus inline device-side finite-field helpers.
- `param/param*/src/host/util.c`
  Reads vectors, reconstructs support/Goppa state, and precomputes inverse
  powers used by the syndrome kernel.
- `param/param*/src/cuda/Decrypt.cu` or `decrypt.cu`
  CUDA kernels, batch orchestration, wall/event timing, and optional
  errorstream output.
- `param/param348864/src/host/gf.c`
  `348864` finite-field implementation.
- `param/param348864/src/host/root.c`
  `348864` support/root implementation.

## Stage-level ownership

### Stage 1: host-side setup

- `initialisation(...)` in `src/host/util.c`
  Loads the shared secret key and ciphertext batch.
- `compute_inverses()` in `src/host/util.c`
  Builds the host-side `inverse_elements[bit][power]` table.
- `InitializeC()` in `include/decrypt.h`
  Copies support points and inverse tables into device-accessible memory.

### Stage 2: syndrome generation

- `SyndromeKernel` / `syndrome_kernel`
  Assigns one block or block-row to each syndrome coefficient/ciphertext pair
  and reduces the bit contributions with warp/shared-memory cooperation.

### Stage 3: locator recovery

- `berlekampMasseyKernel` / `berlekamp_massey_kernel`
  Runs one Berlekamp-Massey state machine per ciphertext in the current batch.

### Stage 4: root/Chien evaluation

- `chien_search_kernel`
  Evaluates the locator polynomial over the support set and writes one error
  flag per codeword position.

### Stage 5: output and validation

- `decrypt(...)` / `decrypt_all(...)`
  Handles batch looping, host/device copies, timing aggregation, and optional
  errorstream emission.
- `compare_errorstreams.sh`
  Validates the final output against the CPU reference files.

## Reading order

1. `param/param6960119/src/cuda/decrypt.cu`
2. `param/param6960119/src/host/util.c`
3. `param/param348864/src/cuda/Decrypt.cu`
4. `compare_errorstreams.sh`

`6960119` is the clearest top-level baseline implementation. `348864` is the
best place to look when you need to understand the older legacy-style files.
