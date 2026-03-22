# GPU optimised orchestrator:
# - handles PARAM fan-out (single param or all),
# - forwards ARCH/KATNUM into per-param Makefiles,
# - provides compare/clean utilities.
PARAMS := 348864 460896 6688128 6960119 8192128
PARAM ?= all
ARCH ?= sm_86
KATNUM ?= 5
CPU_DIR ?= ../CPU
MAKEFLAGS += --no-print-directory

# Positional shorthand: make run 5 sm_75
ifneq ($(filter run compare output all,$(firstword $(MAKECMDGOALS))),)
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

.PHONY: all run output clean compare

# Build optimised GPU binaries.
all:
	@if [ "$(PARAM)" = "all" ]; then \
		for p in $(PARAMS); do \
			echo "===== Building param$$p (ARCH=$(ARCH), KATNUM=$(KATNUM)) ====="; \
			$(MAKE) -C param/param$$p all PARAM=$$p ARCH=$(ARCH) KATNUM=$(KATNUM); \
		done; \
	else \
		echo "===== Building param$(PARAM) (ARCH=$(ARCH), KATNUM=$(KATNUM)) ====="; \
		$(MAKE) -C param/param$(PARAM) all PARAM=$(PARAM) ARCH=$(ARCH) KATNUM=$(KATNUM); \
	fi

# Run optimised GPU binaries.
run:
	@if [ "$(PARAM)" = "all" ]; then \
		for p in $(PARAMS); do \
			echo "===== Running param$$p (ARCH=$(ARCH), KATNUM=$(KATNUM)) ====="; \
			$(MAKE) -C param/param$$p run PARAM=$$p ARCH=$(ARCH) KATNUM=$(KATNUM); \
		done; \
	else \
		echo "===== Running param$(PARAM) (ARCH=$(ARCH), KATNUM=$(KATNUM)) ====="; \
		$(MAKE) -C param/param$(PARAM) run PARAM=$(PARAM) ARCH=$(ARCH) KATNUM=$(KATNUM); \
	fi

# Force generation of `results/output/errorstream0_*.bin` in each parameter directory.
output:
	@if [ "$(PARAM)" = "all" ]; then \
		for p in $(PARAMS); do \
			echo "===== Output param$$p (ARCH=$(ARCH), KATNUM=$(KATNUM)) ====="; \
			$(MAKE) -C param/param$$p output PARAM=$$p ARCH=$(ARCH) KATNUM=$(KATNUM); \
		done; \
	else \
		echo "===== Output param$(PARAM) (ARCH=$(ARCH), KATNUM=$(KATNUM)) ====="; \
		$(MAKE) -C param/param$(PARAM) output PARAM=$(PARAM) ARCH=$(ARCH) KATNUM=$(KATNUM); \
	fi

# Remove build outputs, runtime output files, and profiler artifacts.
clean:
	@if [ "$(PARAM)" = "all" ]; then \
		for p in $(PARAMS); do \
			echo "===== Cleaning param$$p ====="; \
			$(MAKE) -C param/param$$p clean PARAM=$$p; \
		done; \
	else \
		echo "===== Cleaning param$(PARAM) ====="; \
		$(MAKE) -C param/param$(PARAM) clean PARAM=$(PARAM); \
	fi
	@rm -rf build/*
	@rm -f bin/decrypt_gpu_optimised_*
	@rm -f results/profile/*
	@rm -f results/output/*
	@rm -f results/profile/ncu-report-*.ncu-rep
	@rm -f profile/ncu-rep/*.ncu-rep
	@rm -f profile/logs/*
	@rm -f profile/csv/*

compare:
	@chmod +x compare_errorstreams.sh
	@./compare_errorstreams.sh $(PARAM) $(CPU_DIR)/results/output results/output
