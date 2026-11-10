# tofuix --- OpenTofu infrastructure in Guile Scheme

GUIX ?= guix
GUIX_LOAD_FLAGS ?=
GUILE_AUTO_COMPILE ?= 0
export GUILE_AUTO_COMPILE
GUIX_REPL_FLAGS := -L modules -L . $(GUIX_LOAD_FLAGS)

UNIT_TESTS := $(sort $(wildcard tests/*-test.scm))
RUNTIME_TESTS := $(sort $(wildcard tests/runtime/*.scm))

.PHONY: check check-runtime

check:
	@set -eu; for test in $(UNIT_TESTS); do \
	  echo "RUN $$test"; \
	  $(GUIX) repl $(GUIX_REPL_FLAGS) "$$test"; \
	done
	@echo "All unit tests passed."

check-runtime:
	@set -eu; for test in $(RUNTIME_TESTS); do \
	  echo "RUN $$test"; \
	  $(GUIX) repl $(GUIX_REPL_FLAGS) "$$test"; \
	done
	@echo "All runtime checks passed."
