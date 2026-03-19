# Unified CPU + GPU Workflow

This workspace now has one master `Makefile` at repository root to control both:
- `cleaned_variants` (CPU)
- `cleaned_gpu_baseline` (GPU baseline)
- `cleaned_gpu_optimised` (GPU optimised)

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

## Notes

- `make run` keeps GPU errorstream generation disabled.
- `make output` enables GPU errorstream generation and writes `errorstream0_*.bin`.
- `make compare` is read-only and compares existing CPU/GPU `errorstream0_*.bin` files.
- `make compare-opt` is read-only and compares existing CPU/GPU-optimised `errorstream0_*.bin` files.
- `6960119` is fully wired through KEM, CPU, GPU baseline, and GPU optimised.

## GUI Runner

You can run the same operations from a local GUI:

```bash
cd <repo-root>
python3 gui_runner.py
```

In the GUI, choose:
- `Target` (`all/run/output/clean/compare` and CPU/GPU-specific targets)
- `KATNUM`
- `ARCH`
- `PARAM`

Then click `Run` to execute the command and stream logs live.
