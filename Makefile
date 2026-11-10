# tofuix --- OpenTofu infrastructure in Guile Scheme

GUILE ?= guile
GUILE_FLAGS ?= --no-auto-compile -L modules -L .

TESTS = $(sort $(wildcard tests/*-test.scm))

.PHONY: check

check:
	@status=0; \
	for test in $(TESTS); do \
	  echo "RUN $$test"; \
	  $(GUILE) $(GUILE_FLAGS) $$test || status=1; \
	done; \
	if [ $$status -eq 0 ]; then echo "All tests passed."; \
	else echo "Some tests failed."; fi; \
	exit $$status
