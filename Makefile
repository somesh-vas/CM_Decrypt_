# Unified top-level orchestrator for CPU, GPU baseline, and GPU optimised trees.
# This file only delegates to sub-project Makefiles; build logic remains local there.
CPU_DIR := cleaned_variants
GPU_DIR := cleaned_gpu_baseline
GPU_OPT_DIR := cleaned_gpu_optimised

PARAM ?= all
KATNUM ?= 5
ARCH ?= sm_86
MAKEFLAGS += --no-print-directory

# Positional shorthand support:
#   make run 5
#   make run 5 sm_75
#   make output 10 sm_86 PARAM=460896
# Parsing is intentionally limited to top-level `all|run|output`.
ifneq ($(filter run output all,$(firstword $(MAKECMDGOALS))),)
ifneq ($(word 2,$(MAKECMDGOALS)),)
ifneq ($(filter sm_%,$(word 2,$(MAKECMDGOALS))),)
ARCH := $(word 2,$(MAKECMDGOALS))
$(eval $(word 2,$(MAKECMDGOALS)):;@:)
else
KATNUM := $(word 2,$(MAKECMDGOALS))
$(eval $(word 2,$(MAKECMDGOALS)):;@:)
endif
endif
ifneq ($(word 3,$(MAKECMDGOALS)),)
ifneq ($(filter sm_%,$(word 3,$(MAKECMDGOALS))),)
ARCH := $(word 3,$(MAKECMDGOALS))
$(eval $(word 3,$(MAKECMDGOALS)):;@:)
endif
endif
endif

.PHONY: all run output clean compare compare-opt cpu-all cpu-run cpu-clean gpu-all gpu-run gpu-output gpu-clean gpuopt-all gpuopt-run gpuopt-output gpuopt-clean

# Build every implementation for the selected PARAM.
all: cpu-all gpu-all gpuopt-all

# Run every implementation (no forced errorstream generation on GPUs).
run: cpu-run gpu-run gpuopt-run

# Generate outputs suitable for byte-level CPU/GPU comparison.
output: cpu-run gpu-output gpuopt-output

# Clean all sub-project artifacts.
clean: cpu-clean gpu-clean gpuopt-clean

# Compare CPU vs GPU baseline `errorstream0_*.bin`.
compare:
	@echo "===== Compare CPU vs GPU errorstreams ====="
	@$(MAKE) -C $(GPU_DIR) compare PARAM=$(PARAM)

# Compare CPU vs GPU optimised `errorstream0_*.bin`.
compare-opt:
	@echo "===== Compare CPU vs GPU-Optimised errorstreams ====="
	@$(MAKE) -C $(GPU_OPT_DIR) compare PARAM=$(PARAM)

cpu-all:
	@echo "===== CPU Build (PARAM=$(PARAM), KATNUM=$(KATNUM)) ====="
	@$(MAKE) -C $(CPU_DIR) all PARAM=$(PARAM) KATNUM=$(KATNUM)

cpu-run:
	@echo "===== CPU Run (PARAM=$(PARAM), KATNUM=$(KATNUM)) ====="
	@$(MAKE) -C $(CPU_DIR) run PARAM=$(PARAM) KATNUM=$(KATNUM)

cpu-clean:
	@echo "===== CPU Clean ====="
	@$(MAKE) -C $(CPU_DIR) clean PARAM=$(PARAM)

gpu-all:
	@echo "===== GPU Build (PARAM=$(PARAM), KATNUM=$(KATNUM), ARCH=$(ARCH)) ====="
	@$(MAKE) -C $(GPU_DIR) all PARAM=$(PARAM) KATNUM=$(KATNUM) ARCH=$(ARCH)

gpu-run:
	@echo "===== GPU Run (PARAM=$(PARAM), KATNUM=$(KATNUM), ARCH=$(ARCH)) ====="
	@$(MAKE) -C $(GPU_DIR) run PARAM=$(PARAM) KATNUM=$(KATNUM) ARCH=$(ARCH)

gpu-output:
	@echo "===== GPU Output (PARAM=$(PARAM), KATNUM=$(KATNUM), ARCH=$(ARCH)) ====="
	@$(MAKE) -C $(GPU_DIR) output PARAM=$(PARAM) KATNUM=$(KATNUM) ARCH=$(ARCH)

gpu-clean:
	@echo "===== GPU Clean ====="
	@$(MAKE) -C $(GPU_DIR) clean PARAM=$(PARAM)

gpuopt-all:
	@echo "===== GPU-Optimised Build (PARAM=$(PARAM), KATNUM=$(KATNUM), ARCH=$(ARCH)) ====="
	@$(MAKE) -C $(GPU_OPT_DIR) all PARAM=$(PARAM) KATNUM=$(KATNUM) ARCH=$(ARCH)

gpuopt-run:
	@echo "===== GPU-Optimised Run (PARAM=$(PARAM), KATNUM=$(KATNUM), ARCH=$(ARCH)) ====="
	@$(MAKE) -C $(GPU_OPT_DIR) run PARAM=$(PARAM) KATNUM=$(KATNUM) ARCH=$(ARCH)

gpuopt-output:
	@echo "===== GPU-Optimised Output (PARAM=$(PARAM), KATNUM=$(KATNUM), ARCH=$(ARCH)) ====="
	@$(MAKE) -C $(GPU_OPT_DIR) output PARAM=$(PARAM) KATNUM=$(KATNUM) ARCH=$(ARCH)

gpuopt-clean:
	@echo "===== GPU-Optimised Clean ====="
	@$(MAKE) -C $(GPU_OPT_DIR) clean PARAM=$(PARAM)
