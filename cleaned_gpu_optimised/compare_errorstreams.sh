#!/usr/bin/env bash
# Compare CPU and GPU optimised `errorstream0_<param>.bin` files.
# Exit code is 0 only when all requested comparisons match.
set -euo pipefail

# Always run relative to this script's directory.
cd "$(dirname "$0")"

# Supported parameter sets.
PARAMS=(348864 460896 6688128 6960119 8192128)
TARGET="${1:-all}"
CPU_DIR="${2:-../cleaned_variants/results/output}"
GPU_DIR="${3:-results/output}"

# Validate target argument early.
if [[ "$TARGET" != "all" && "$TARGET" != "348864" && "$TARGET" != "460896" && "$TARGET" != "6688128" && "$TARGET" != "6960119" && "$TARGET" != "8192128" ]]; then
    echo "Usage: $0 [all|348864|460896|6688128|6960119|8192128] [cpu_output_dir] [gpu_output_dir]"
    exit 2
fi

# Expand `all` into the full parameter list.
if [[ "$TARGET" == "all" ]]; then
    CHECK_PARAMS=("${PARAMS[@]}")
else
    CHECK_PARAMS=("$TARGET")
fi

# Aggregate status over all requested parameters.
fail=0
for p in "${CHECK_PARAMS[@]}"; do
    cpu_file="$CPU_DIR/errorstream0_${p}.bin"
    gpu_file="$GPU_DIR/errorstream0_${p}.bin"

    # Existence checks provide clearer diagnostics than direct cmp failures.
    if [[ ! -f "$cpu_file" ]]; then
        echo "[FAIL] param$p missing CPU file: $cpu_file"
        fail=1
        continue
    fi
    if [[ ! -f "$gpu_file" ]]; then
        echo "[FAIL] param$p missing GPU file: $gpu_file"
        fail=1
        continue
    fi

    if cmp -s "$cpu_file" "$gpu_file"; then
        echo "[PASS] param$p match"
    else
        echo "[FAIL] param$p mismatch"
        fail=1
    fi
done

# Uniform status line for Makefile automation.
if [[ $fail -eq 0 ]]; then
    echo "COMPARE_STATUS=PASS"
else
    echo "COMPARE_STATUS=FAIL"
    exit 1
fi
