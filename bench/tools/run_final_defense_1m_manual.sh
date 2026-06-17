#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE=""
PARAM=""
KATNUM="1000000"
CHUNK_SIZE="50000"
ARCH="sm_75"
SPLIT_OUTPUT="1"
TRIALS="1"
DIAG="$ROOT/bench/results/final-defense-1m-manual"
PROFILE_PATH=""
OUTPUT_DIR=""
GPU_COMMON_FLAGS='-O3 --use_fast_math -Xcompiler "-Wall,-Wextra,-mcmodel=medium"'
GPU_CFLAGS='-std=c11 -O3 -Wall -Wextra -mcmodel=medium $(CPP_DEFS)'

usage() {
  cat <<'EOF'
Usage: run_final_defense_1m_manual.sh --state cpu|gpu-baseline|gpu-optimized --param <param> [options]
Options:
  --katnum <N>        default 1000000
  --chunk-size <N>    default 50000
  --arch sm_75        default sm_75
  --split-output 0|1  default 1
  --trials <N>        default 1
  --diag <path>       log root
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --state) STATE="$2"; shift 2 ;;
    --param) PARAM="$2"; shift 2 ;;
    --katnum) KATNUM="$2"; shift 2 ;;
    --chunk-size) CHUNK_SIZE="$2"; shift 2 ;;
    --arch) ARCH="$2"; shift 2 ;;
    --split-output) SPLIT_OUTPUT="$2"; shift 2 ;;
    --trials) TRIALS="$2"; shift 2 ;;
    --diag) DIAG="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$STATE" ] || [ -z "$PARAM" ]; then
  usage >&2
  exit 2
fi

case "$STATE" in
  cpu)
    WORKDIR="$ROOT/CPU/param/param$PARAM"
    BUILD_CMD=(make clean all KATNUM="$KATNUM")
    RUN_CMD=("$ROOT/CPU/bin/decrypt_$PARAM" "$KATNUM")
    OUTPUT_DIR="$ROOT/CPU/results/output"
    ;;
  gpu-baseline)
    WORKDIR="$ROOT/GPU_Baseline/param/param$PARAM"
    BUILD_CMD=(make clean all ARCH="$ARCH" KATNUM="$KATNUM" WRITE_ERRORSTREAM=1 COMMON_FLAGS="$GPU_COMMON_FLAGS" CFLAGS="$GPU_CFLAGS")
    RUN_CMD=("$ROOT/GPU_Baseline/bin/decrypt_gpu_baseline_$PARAM")
    PROFILE_PATH="$ROOT/GPU_Baseline/results/profile/Profile_GPU_baseline_$PARAM.txt"
    OUTPUT_DIR="$ROOT/GPU_Baseline/results/output"
    ;;
  gpu-optimized|gpu-optimised)
    WORKDIR="$ROOT/GPU_Optimised/param/param$PARAM"
    BUILD_CMD=(make clean all ARCH="$ARCH" KATNUM="$KATNUM" WRITE_ERRORSTREAM=1 COMMON_FLAGS="$GPU_COMMON_FLAGS" CFLAGS="$GPU_CFLAGS")
    RUN_CMD=("$ROOT/GPU_Optimised/bin/decrypt_gpu_optimised_$PARAM")
    PROFILE_PATH="$ROOT/GPU_Optimised/results/profile/Profile_GPU_optimised_$PARAM.txt"
    OUTPUT_DIR="$ROOT/GPU_Optimised/results/output"
    ;;
  *) echo "unknown --state: $STATE" >&2; exit 2 ;;
esac

mkdir -p "$DIAG/logs"
echo "state=$STATE param=$PARAM katnum=$KATNUM chunk_size=$CHUNK_SIZE arch=$ARCH split_output=$SPLIT_OUTPUT trials=$TRIALS"
echo "NOTE: this script does not delete previous result files."

profile_total_from_file() {
  local path="$1"
  awk '
    /ciphertexts processed[[:space:]]*:/ {
      for (i = 1; i <= NF; ++i) {
        if ($i ~ /^[0-9]+$/) total = $i
      }
    }
    /TIMING SUMMARY/ {
      if (match($0, /total=[0-9]+/)) {
        text = substr($0, RSTART, RLENGTH)
        sub("total=", "", text)
        total = text
      }
    }
    END {
      if (total != "") print total
    }
  ' "$path"
}

verify_profile_total() {
  local log="$1"
  local total=""

  if [[ "$STATE" == "cpu" ]]; then
    total="$(profile_total_from_file "$log")"
  elif [[ -n "$PROFILE_PATH" && -f "$PROFILE_PATH" ]]; then
    total="$(profile_total_from_file "$PROFILE_PATH")"
  fi

  if [[ -z "$total" ]]; then
    echo "ERROR: could not read profile total for $STATE param=$PARAM" >&2
    return 1
  fi
  if [[ "$total" != "$KATNUM" ]]; then
    echo "ERROR: profile total mismatch for $STATE param=$PARAM: requested $KATNUM, profile reported $total" >&2
    return 1
  fi
  echo "profile total verified: $total"
}

for trial in $(seq 1 "$TRIALS"); do
  LOG="$DIAG/logs/${STATE}_param${PARAM}_trial${trial}.log"
  {
    echo "===== build command ====="
    printf 'cd %q &&' "$WORKDIR"; printf ' %q' "${BUILD_CMD[@]}"; echo
    (cd "$WORKDIR" && "${BUILD_CMD[@]}")
    echo "===== run command ====="
    printf 'cd %q && CM_ERRORSTREAM_SPLIT_CHUNKS=%q CM_ERRORSTREAM_SPLIT_CHUNK_SIZE=%q' "$WORKDIR" "$SPLIT_OUTPUT" "$CHUNK_SIZE"
    printf ' %q' "${RUN_CMD[@]}"; echo
    (cd "$WORKDIR" && CM_ERRORSTREAM_SPLIT_CHUNKS="$SPLIT_OUTPUT" CM_ERRORSTREAM_SPLIT_CHUNK_SIZE="$CHUNK_SIZE" "${RUN_CMD[@]}")
  } >"$LOG" 2>&1
  verify_profile_total "$LOG" | tee -a "$LOG"
  echo "trial $trial log: $LOG"
done
