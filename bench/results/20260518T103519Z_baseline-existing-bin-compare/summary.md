# Iteration 20260518T103519Z_baseline-existing-bin-compare

- Label: `baseline-existing-bin-compare`
- UTC: `20260518T103519Z`
- Mode: `compare-existing-only`
- ARCH metadata: `sm_75`
- KATNUM metadata: `50000`
- Action: `direct byte comparison of existing CPU/GPU_Optimised .bin files`
- No CPU run, no GPU run, no make target, no nvcc, no ncu.

## Results

| Param | Correctness | CPU bytes | GPU bytes | SHA256 match | First mismatch offset |
|---|---:|---:|---:|---:|---:|
| 348864 | FAIL | 13018700 | 13000000 | False | 13001 |
| 460896 | FAIL | 13096250 | 12911000 | False | 12912 |
| 6688128 | FAIL | 25580200 | 25532000 | False | 25533 |
| 6960119 | FAIL | 24749550 | 24744000 | False | 24745 |
| 8192128 | FAIL | 31174700 | 31162000 | False | 31163 |

## Files

- `summary.json`
- `compare_existing_outputs.json`
- `device_git_context.json`
- `bench/results/metrics_history.csv`
