# Unified top-level orchestrator for CPU, GPU baseline, and GPU optimised trees.
# This file only delegates to sub-project Makefiles; build logic remains local there.
CPU_DIR := CPU
GPU_DIR := GPU_Baseline
GPU_OPT_DIR := GPU_Optimised

PARAM ?= all
KATNUM ?= 5
ARCH ?= sm_86
SUDO ?= 0
SKIP_NCU ?= 0
KATNUM_SET_BY_USER := 0
MAKEFLAGS += --no-print-directory

# Positional shorthand support:
#   make run 5
#   make run 5 sm_75
#   make output 10 sm_86 PARAM=460896
#   make full-profile 10 sm_86 PARAM=460896
# Parsing is intentionally limited to top-level run-style targets.
ifneq ($(filter run output all full-profile,$(firstword $(MAKECMDGOALS))),)
ifneq ($(word 2,$(MAKECMDGOALS)),)
ifneq ($(filter sm_%,$(word 2,$(MAKECMDGOALS))),)
ARCH := $(word 2,$(MAKECMDGOALS))
$(eval $(word 2,$(MAKECMDGOALS)):;@:)
else
KATNUM := $(word 2,$(MAKECMDGOALS))
KATNUM_SET_BY_USER := 1
$(eval $(word 2,$(MAKECMDGOALS)):;@:)
endif
endif
ifneq ($(word 3,$(MAKECMDGOALS)),)
ifneq ($(filter sm_%,$(word 3,$(MAKECMDGOALS))),)
ARCH := $(word 3,$(MAKECMDGOALS))
$(eval $(word 3,$(MAKECMDGOALS)):;@:)
endif
endif

ifneq ($(filter command\ line environment environment\ override,$(origin KATNUM)),)
KATNUM_SET_BY_USER := 1
endif

FULL_PROFILE_KATNUM_DISPLAY := $(if $(filter 1,$(KATNUM_SET_BY_USER)),$(KATNUM),runtime-prompt)
endif

.PHONY: all run output clean full-clean all-full-clean compare compare-opt full-profile cpu-all cpu-run cpu-clean gpu-all gpu-run gpu-output gpu-clean gpuopt-all gpuopt-run gpuopt-output gpuopt-clean

# Build every implementation for the selected PARAM.
all: cpu-all gpu-all gpuopt-all

# Run every implementation (no forced errorstream generation on GPUs).
run: cpu-run gpu-run gpuopt-run

# Generate outputs suitable for byte-level CPU/GPU comparison.
output: cpu-run gpu-output gpuopt-output

# Clean all sub-project artifacts.
clean: cpu-clean gpu-clean gpuopt-clean

# Clean all generated profiling artifacts, including imported full-profile text
# reports and the mirrored `full_profile_txt/` tree.
full-clean: clean
	@echo "===== Full Profile Artifact Clean ====="
	@rm -f Decrypt_kernels_full_profile.txt
	@rm -rf $(GPU_DIR)/profile/full_profile/*
	@rm -rf $(GPU_OPT_DIR)/profile/full_profile/*
	@rm -rf full_profile_txt/*

all-full-clean: full-clean

# Compare CPU vs GPU baseline `errorstream0_*.bin`.
compare:
	@echo "===== Compare CPU vs GPU errorstreams ====="
	@$(MAKE) -C $(GPU_DIR) compare PARAM=$(PARAM)

# Compare CPU vs GPU optimised `errorstream0_*.bin`.
compare-opt:
	@echo "===== Compare CPU vs GPU-Optimised errorstreams ====="
	@$(MAKE) -C $(GPU_OPT_DIR) compare PARAM=$(PARAM)

# Full end-to-end validation, compare, NCU generation, and `.txt` collection.
full-profile:
	@echo "===== Full E2E Profile (PARAM=$(PARAM), KATNUM=$(FULL_PROFILE_KATNUM_DISPLAY), ARCH=$(ARCH)) ====="
	@extra_args=""; \
	if [ "$(KATNUM_SET_BY_USER)" = "1" ]; then \
		extra_args="$$extra_args --katnum $(KATNUM)"; \
	fi; \
	if [ "$(SKIP_NCU)" = "1" ]; then \
		extra_args="$$extra_args --skip-ncu"; \
	fi; \
	if [ "$(SUDO)" = "1" ]; then \
		extra_args="$$extra_args --sudo"; \
	fi; \
	python3 utility/full_e2e_profile.py --param $(PARAM) --arch $(ARCH) $$extra_args

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
