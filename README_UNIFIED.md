# Unified CPU + GPU Baseline Workflow

This workspace now has one master `Makefile` at repository root to control both:
- `cleaned_variants` (CPU)
- `cleaned_gpu_baseline` (GPU baseline)
- `cleaned_gpu_optimised` (GPU optimised)

## Main commands (run from `rewritten_sources_cleaned/`)

- `make all [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make run [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make output [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make clean [PARAM=<id|all>]`
- `make compare [PARAM=<id|all>]`
- `make compare-opt [PARAM=<id|all>]`

Examples:
- `make all 2 sm_75`
- `make run 1 sm_86 PARAM=460896`
- `make output 1 sm_75 PARAM=8192128`
- `make compare PARAM=6688128`
- `make compare-opt PARAM=6688128`

## Notes

- `make run` keeps GPU errorstream generation disabled.
- `make output` enables GPU errorstream generation and writes `errorstream0_*.bin`.
- `make compare` is read-only and compares existing CPU/GPU `errorstream0_*.bin` files.
- `make compare-opt` is read-only and compares existing CPU/GPU-optimised `errorstream0_*.bin` files.

## GUI Runner

You can run the same operations from a local GUI:

```bash
cd rewritten_sources_cleaned
python3 gui_runner.py
```

In the GUI, choose:
- `Target` (`all/run/output/clean/compare` and CPU/GPU-specific targets)
- `KATNUM`
- `ARCH`
- `PARAM`

Then click `Run` to execute the command and stream logs live.
