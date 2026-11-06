# Thin wrapper over run.sh.
#
# Every target delegates, so there is exactly one implementation of each step
# and `make test` and `./run.sh test` can never disagree. The brief asks for a
# Makefile; the credential handling belongs in shell, where it is readable.
#
# .PHONY because these are actions, not files. Without it, a file named
# "test" in the repo would make `make test` decide there was nothing to do.

.PHONY: help check schema seed reset test demo shell

help:
	@./run.sh --help || true

check:  ; @./run.sh check
schema: ; @./run.sh schema
seed:   ; @./run.sh seed
reset:  ; @./run.sh reset
test:   ; @./run.sh test
demo:   ; @./run.sh demo
shell:  ; @./run.sh shell
