# Iteration 20260518T123819Z_baseline-existing-gpu-sm75-rtx3090ti-nonroot

- Label: `baseline-existing-gpu-sm75-rtx3090ti-nonroot`
- UTC: `20260518T123819Z`
- ARCH: `sm_75`
- KATNUM: `50000`
- Params: `348864,460896,6688128,6960119,8192128`
- Correctness mode: `GPU_Optimised output compared against existing CPU errorstream; CPU is not rerun`
- NCU mode: `non-root, optimised-only, text artifacts only`

## Results

| Param | Correctness | NCU | Throughput ct/s | Kernel ct/s | Chien ms | Chien % kernel | Chien regs/thread | Chien occupancy % |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| 348864 | PASS | SKIP |  |  |  |  |  |  |
| 460896 | PASS | SKIP |  |  |  |  |  |  |
| 6688128 | PASS | SKIP |  |  |  |  |  |  |
| 6960119 | PASS | SKIP | 74569.15 | 281761.57 | 126.980 | 71.56 |  |  |
| 8192128 | PASS | SKIP |  |  |  |  |  |  |

## Files to inspect

- `codex_change.md`
- `summary.json`
- `preflight_reference_files.json`
- `profiles/param*/metrics.json`
- `logs/param*/01_gpuopt_output_only.log`
- `logs/param*/02_compare_optimised_vs_existing_cpu.log`
- `logs/param*/03_ncu_optimised.log`, when NCU is enabled
- `device/device_report.txt` and `device/device_summary.json`
