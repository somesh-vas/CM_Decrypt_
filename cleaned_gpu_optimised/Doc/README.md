# Cleaned GPU Optimised

Restructured GPU optimised variants in the same layout/pattern as `cleaned_gpu_baseline`.

## Commands
Run from `cleaned_gpu_optimised/`:
- `make all`
- `make run`
- `make output`
- `make clean`
- `make compare`

Supports dynamic values:
- `make run 5 sm_75 PARAM=460896`
- `make output 2 sm_86 PARAM=8192128`

## Behavior
- `run`: profile text only (`results/profile/*.txt`)
- `output`: generates `results/output/errorstream0_*.bin`
- `compare`: read-only CPU-vs-GPU errorstream comparison
