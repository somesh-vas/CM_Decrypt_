# Cleaned GPU Optimised

Restructured GPU optimised variants in the same layout/pattern as `cleaned_gpu_baseline`.

## Supported parameters

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

## Prerequisite vectors

Each run consumes `kem/test_vectors/Cipher_Sk/ct_<param>.bin` and
`kem/test_vectors/Cipher_Sk/sk_<param>.bin`. Generate enough ciphertexts for
your runtime `KATNUM` before launching the GPU code:

```bash
cd ../kem
CT_PER_SK=5 ./generate_all_vectors.sh
```

## Commands
Run from `cleaned_gpu_optimised/`:
- `make all`
- `make run`
- `make output`
- `make clean`
- `make compare`

Supports dynamic values:
- `make run 5 sm_75 PARAM=460896`
- `make run 5 sm_86 PARAM=6960119`
- `make output 2 sm_86 PARAM=8192128`
- `make output 5 sm_86 PARAM=6960119`
- `make compare PARAM=6960119`

## Behavior
- `run`: profile text only (`results/profile/*.txt`)
- `output`: generates `results/output/errorstream0_*.bin`
- `compare`: read-only CPU-vs-GPU-optimised errorstream comparison

## 6960119 note

`param6960119` is intentionally implemented with the verified baseline-style
CUDA pipeline inside this tree. The original bit-packed optimised kernel shape
assumed parameter sizes that fit cleanly into 32-bit error-vector packing,
which `SYS_N=6960` does not. This version prioritizes correctness and still
integrates cleanly with the optimised build/run/compare workflow.
