# Final 1M Benchmark Summary

This summary records the thesis-facing final benchmark result for the cleaned repository. Raw logs, output chunks, generated binaries, and profiler dumps are intentionally not tracked.

## Benchmark configuration

- Workload: 1,000,000 ciphertexts per parameter set
- Chunking: 20 chunks of 50,000 ciphertexts
- Implementations compared: CPU reference, naive GPU baseline, optimized GPU
- Correctness criterion: each naive GPU and optimized GPU output chunk matches the corresponding CPU reference chunk

## Correctness

| Parameter | CPU chunks | Naive GPU vs CPU | Optimized GPU vs CPU |
|---:|---:|:---:|:---:|
| 348864 | 20 | PASS | PASS |
| 460896 | 20 | PASS | PASS |
| 6688128 | 20 | PASS | PASS |
| 6960119 | 20 | PASS | PASS |
| 8192128 | 20 | PASS | PASS |

## Compute throughput

Throughput below is the cryptographic compute-path throughput. For GPU runs, this is computed from Syndrome + Berlekamp Massey + root-search kernel time.

| Parameter | CPU dec/s | Naive GPU kernel dec/s | Optimized GPU kernel dec/s | Optimized / Naive GPU |
|---:|---:|---:|---:|---:|
| 348864 | 257.52 | 42,742.62 | 2,353,583.57 | 55.06x |
| 460896 | 131.43 | 17,884.33 | 1,072,713.91 | 59.98x |
| 6688128 | 71.18 | 9,199.67 | 629,806.21 | 68.46x |
| 6960119 | 75.70 | 8,790.93 | 676,745.67 | 76.98x |
| 8192128 | 62.22 | 7,605.75 | 545,490.94 | 71.72x |
| Aggregate | 598.05 | 86,223.29 | 5,278,340.30 | 61.22x |

## Final optimized configuration

| Parameter | Root search | Multiplication | BM launch | Syndrome launch |
|---:|---|---|---|---|
| 348864 | Warp level root search | Baseline | Baseline | Baseline |
| 460896 | Warp level root search | mulmat group | Baseline | Baseline |
| 6688128 | Warp level root search | mulmat group | Block128 | Block512 |
| 6960119 | Warp level root search | mulmat group | Baseline | Block512 |
| 8192128 | Warp level root search | mulmat group | Baseline | Baseline |

## Interpretation

The optimized GPU implementation preserves the Classic McEliece decryption algorithm but changes the execution mapping and data layout. The main gain comes from expressing the root search as a warp level computation and reducing redundant finite-field multiplication work for the larger parameter sets.
