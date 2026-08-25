# Makefile for the Mirage Lambda Service.
#
# Phase 0: probe build targets + toolchain introspection.
# Phase 1: `make build` / `make test` drive dune for the pure common library.
# Phase 5/6: Mirage targets are added later.

OCAMLLIB  ?= $(shell opam var lib 2>/dev/null)
DUNE      ?= dune
OPAM      ?= opam

.PHONY: all build test clean probes env probes-unix probes-hvt lock

all: build

# ---- Phase 1+ : dune build / test for the common library and Unix worker ----
build:
	$(DUNE) build

test:
	$(DUNE) runtest

clean:
	$(DUNE) clean

# ---- Phase 0 : toolchain introspection (writes a pinned report) ----
env:
	@echo "# OCaml:   $$(ocaml -version)"
	@echo "# Dune:    $$($(DUNE) --version)"
	@echo "# Opam:    $$($(OPAM) --version)"
	@echo "# Switch:  $$($(OPAM) switch show)"
	@echo "# OCAMLLIB: $(OCAMLLIB)"

# ---- Phase 0 : QuickJS probes ----
# Unix probe: compile qjs/c/qjs_port_unix.c + qjs/test/probe.ml against the
# vendored QuickJS release and run the probe (see scripts/build-unix-probe.sh).
probes: probes-unix
probes-unix:
	./scripts/build-unix-probe.sh

probes-hvt:
	./scripts/build-hvt-probe.sh

# ---- Phase 5/6 : Mirage unikernel builds (added later) ----
# mirage-configure-control:
# 	mirage configure -t hvt --extra-repos ...
# mirage-build-control:
# 	dune build control/unikernel.hvt
