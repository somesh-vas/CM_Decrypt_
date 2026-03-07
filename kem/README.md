# McEliece Test Vector Generation

This directory is organized as a single shared codebase for generating test vectors (`sk_*.bin`, `ct_*.bin`) across all enabled variants.

## Super Folder

All generated vectors are now stored under the super folder:

- `test_vectors/`
  - `Cipher_Sk/` (binary outputs)

## Renamed Variant Folders

The variant folders were standardized to a consistent naming scheme:

- `mceliece348864` -> `variant_348864`
- `mceliece460896c` -> `variant_460896c`
- `mceliece6688128c` -> `variant_6688128c`
- `mceliece8192128c` -> `variant_8192128c`

## Directory Layout

- `common/kat_kem_vectors.c`
: Shared test-vector generator (one keypair + many ciphertexts).

- `common/core/`
: Shared core sources/headers used by all variants.

- `variant_348864/`, `variant_460896c/`, `variant_6688128c/`, `variant_8192128c/`
: Variant-specific files (`params.h`, `gf.c`, `util.c`, `crypto_kem*.h`, `nist/rng.*`) and local build/run wrappers.

- `test_vectors/Cipher_Sk/`
: Generated output vectors.

## One-Command Generation

From this `kem/` directory:

```sh
./generate_all_vectors.sh
```

This builds and runs all variant folders and writes outputs to `test_vectors/Cipher_Sk/`.

## Configure Number of Ciphertexts Per Key

Set dynamically at runtime:

```sh
CT_PER_SK=100 ./generate_all_vectors.sh
```

## Reuse Existing Ciphertexts (No New Randomness)

If you already generated vectors (for example `CT_PER_SK=100`) and want `100*n`
ciphertexts without generating new random ciphertexts, use:

From repository root:

```sh
./utility/multiply_ct_bins.sh n kem/test_vectors/Cipher_Sk
```

From `kem/` directory:

```sh
../utility/multiply_ct_bins.sh n test_vectors/Cipher_Sk
```

Example (`n=3`): each `ct_*.bin` grows from `100` to `300` ciphertexts.
`sk_*.bin` files are not modified.

## Output Naming

Generated files are named by parameter set:

- `sk_348864.bin`, `ct_348864.bin`
- `sk_460896.bin`, `ct_460896.bin`
- `sk_6688128.bin`, `ct_6688128.bin`
- `sk_8192128.bin`, `ct_8192128.bin`
