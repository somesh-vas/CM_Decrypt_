# CPU orchestrator:
# - fans out build/run/clean commands to parameter directories
# - keeps the CPU tree interface aligned with the root Makefile
PARAMS := 348864 460896 6688128 6960119 8192128
KATNUM ?= 5
PARAM ?= all
MAKEFLAGS += --no-print-directory

# Positional shorthand:
#   make run 5
ifneq ($(filter run,$(firstword $(MAKECMDGOALS))),)
ifneq ($(word 2,$(MAKECMDGOALS)),)
KATNUM := $(word 2,$(MAKECMDGOALS))
$(eval $(KATNUM):;@:)
endif
endif

.PHONY: all clean run

# Build one or all CPU parameter families.
all:
	@for p in $(PARAMS); do \
		$(MAKE) -C param/param$$p all PARAM=$$p; \
	done

# Run one or all CPU parameter families and emit timing/errorstream output.
run:
	@if [ "$(PARAM)" = "all" ]; then \
		for p in $(PARAMS); do \
			$(MAKE) -C param/param$$p run PARAM=$$p KATNUM=$(KATNUM); \
		done; \
	else \
		$(MAKE) -C param/param$(PARAM) run PARAM=$(PARAM) KATNUM=$(KATNUM); \
	fi

# Remove CPU build artifacts and generated outputs.
clean:
	@if [ "$(PARAM)" = "all" ]; then \
		for p in $(PARAMS); do \
			$(MAKE) -C param/param$$p clean PARAM=$$p; \
		done; \
	else \
		$(MAKE) -C param/param$(PARAM) clean PARAM=$(PARAM); \
	fi
	@rm -rf build/*
	@rm -f bin/decrypt_*
