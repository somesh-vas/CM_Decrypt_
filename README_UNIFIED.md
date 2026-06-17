# Unified CPU + GPU Workflow

This workspace now has one master `Makefile` at repository root to control both:
- `CPU` (CPU)
- `GPU_Baseline` (GPU baseline)
- `GPU_Optimised` (GPU optimised)

## Supported parameters

- `348864`
- `460896`
- `6688128`
- `6960119`
- `8192128`

## Prerequisite vectors

All CPU/GPU runs consume ciphertext and secret-key vectors from
`kem/test_vectors/Cipher_Sk/`.

Make sure each `ct_<param>.bin` contains at least `KATNUM` ciphertexts.
For example, to prepare five ciphertexts per key for every enabled variant:

```bash
cd <repo-root>/kem
CT_PER_SK=5 ./generate_all_vectors.sh
```

## Main commands (run from the repository root)

- `make all [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make run [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make output [KATNUM] [sm_75|sm_86] [PARAM=<id|all>]`
- `make clean [PARAM=<id|all>]`
- `make compare [PARAM=<id|all>]`
- `make compare-opt [PARAM=<id|all>]`
- `make full-profile [PARAM=<id|all>] [KATNUM=<n>] [ARCH=<sm_xx>]`

Examples:
- `make all 2 sm_75`
- `make run 1 sm_86 PARAM=460896`
- `make run 5 sm_86 PARAM=6960119`
- `make output 1 sm_75 PARAM=8192128`
- `make output 5 sm_86 PARAM=6960119`
- `make compare PARAM=6688128`
- `make compare PARAM=6960119`
- `make compare-opt PARAM=6688128`
- `make compare-opt PARAM=6960119`
- `make full-profile PARAM=6960119 KATNUM=5 ARCH=sm_86`
- `make full-profile PARAM=6960119 ARCH=sm_86`  # prompts for `KATNUM` at runtime
- `make full-profile PARAM=6960119 KATNUM=5 ARCH=sm_86 SUDO=1`
- `make full-profile PARAM=6960119 KATNUM=5 ARCH=sm_86 SKIP_NCU=1`

## Notes

- `make run` keeps GPU errorstream generation disabled.
- `make output` enables GPU errorstream generation and writes `errorstream0_*.bin`.
- `make compare` is read-only and compares existing CPU/GPU `errorstream0_*.bin` files.
- `make compare-opt` is read-only and compares existing CPU/GPU-optimised `errorstream0_*.bin` files.
- `make full-profile` runs `clean -> output -> compare -> compare-opt -> NCU reports`, then mirrors generated `.txt` files into `full_profile_txt/`.
- If Nsight Compute cannot access GPU counters because `RmProfilingAdminOnly=1`, `make full-profile` now records the NCU steps as `SKIP` and still completes successfully.
- If `KATNUM` is omitted for `make full-profile` or `utility/full_e2e_profile.py`, it is requested interactively at runtime.
- `SUDO=1` forwards `--sudo` to the full-profile utility so Nsight Compute can prompt for admin access when profiling is restricted.
- `SKIP_NCU=1` runs the end-to-end validation without generating `.ncu-rep` files.
- `6960119` is fully wired through KEM, CPU, GPU baseline, and GPU optimised.

## GUI Runner

You can run the same operations from a local GUI:

```bash
cd <repo-root>
python3 gui_runner.py
```

In the GUI, choose:
- `Target` (`all/run/output/clean/compare`, Nsight report generation, Nsight `.ncu-rep` to `.txt` import, and CPU/GPU-specific targets)
- `KATNUM`
- `ARCH`
- `PARAM`
- `Overwrite imported NCU TXT` when you want the GUI to replace a writable `<report>.txt` instead of creating `*_details.txt`

Then click `Run` to execute the command and stream logs live.
