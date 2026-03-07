#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

PARAM="${1:-348864}"
KATNUM="${2:-5}"
ARCH="${3:-sm_86}"

case "$PARAM" in
  348864|460896|6688128|8192128) ;;
  *)
    echo "Usage: $0 [348864|460896|6688128|8192128] [KATNUM] [sm_75|sm_86|...]"
    exit 2
    ;;
esac

TARGET="../../bin/decrypt_gpu_baseline_${PARAM}"
NCU="$(command -v ncu || echo '/usr/local/cuda/bin/ncu')"
ROOT_DIR="$(pwd)"

mkdir -p profile/ncu-rep profile/logs profile/csv

KERNELS=(
  "SyndromeKernel"
  "berlekampMasseyKernel"
  "chien_search_kernel"
)

METRICS="gpu__time_duration.sum,\
sm__throughput.avg.pct_of_peak_sustained_active,\
smsp__inst_executed_per_cycle_avg,\
sm__warps_active.avg.pct_of_peak_sustained_active,\
sm__inst_issued.avg.pct_of_peak_sustained_active,\
sm__sass_average_branch_targets_threads_uniform,\
launch__occupancy_limit_active_warps_pct,\
launch__registers_per_thread,\
launch__shared_mem_per_block,\
dram__throughput.avg.pct_of_peak_sustained_active,\
l1tex__t_sectors_pipe_lsu_mem_global_op_ld.sum,\
lts__t_sectors.avg.pct_hit,\
warp__active_threads_per_warp_avg"

ncu_clean() {
  env -u PYTHONHOME -u PYTHONPATH \
      PYTHONNOUSERSITE=1 \
      PYTHONUTF8=1 \
      LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      "$NCU" "$@"
}

# Build binary first with requested settings (no errorstream output)
make -C "param/param${PARAM}" all ARCH="$ARCH" KATNUM="$KATNUM" WRITE_ERRORSTREAM=0 >/dev/null

# Run from param dir so relative input/profile paths in code remain valid
cd "param/param${PARAM}"

for KERNEL in "${KERNELS[@]}"; do
  LABEL="$(echo "$KERNEL" | sed 's/Kernel//g' | tr '[:upper:]' '[:lower:]')"

  echo "---- Profiling $KERNEL (param${PARAM}, KATNUM=${KATNUM}, ARCH=${ARCH})"

  ncu_clean \
    --target-processes all \
    --kernel-name-base function \
    --kernel-name "$KERNEL" \
    --launch-skip 0 \
    --launch-count 1 \
    --metrics "$METRICS" \
    --csv \
    --replay-mode kernel \
    --force-overwrite \
    --export "${ROOT_DIR}/profile/ncu-rep/${KERNEL}_${PARAM}_KAT${KATNUM}_${ARCH}" \
    --log-file "${ROOT_DIR}/profile/logs/${LABEL}_${PARAM}_KAT${KATNUM}_${ARCH}.txt" \
    "$TARGET" \
    > "${ROOT_DIR}/profile/csv/${LABEL}_${PARAM}_KAT${KATNUM}_${ARCH}.csv" || true

done

echo "Done: profile/ncu-rep, profile/logs, profile/csv"
