#!/usr/bin/env bash
#
# mayhem/build.sh — build the microscheme compiler: a sanitized, coverage-instrumented raw
# fuzz target plus a completely separate, NORMAL-flags "oracle" build used by mayhem/test.sh.
#
# microscheme is a plain-C AVR Scheme compiler: `make hexify` generates the embedded
# src/*_hex.c blobs (needs xxd, installed in mayhem/Dockerfile), then the compiler is a
# single `cc src/*.c` link (upstream's own `make build` hard-codes gcc; same sources, our
# flags). There is no LLVMFuzzerTestOneInput entry point — see mayhem/Mayhemfile for why
# this is a raw executable (file-input, process-per-input) target, not a libFuzzer harness.
# Consequently there is no separate "$STANDALONE_FUZZ_MAIN *-standalone" reproducer either:
# the raw fuzz binary (/mayhem/microscheme) already IS its own single-input, run-once
# reproducer (that convention is specific to LLVMFuzzerTestOneInput-style harnesses).
#
# The fuzz build renames upstream's `main` (-Dmain=microscheme_original_main) and links in
# mayhem/microscheme_wrapper_main.c, which chdir("/tmp")s before calling the original — see
# that file's header for why (a Mayhemfile-level `cwd:` on this raw process-per-input target
# was crashing mayhem-fuzz itself, restart-loop rc 254, confirmed against the fleet pattern).
# The oracle build is untouched: upstream's real `main`, no rename, no chdir.
#
#   /mayhem/microscheme         — the fuzz target: $SANITIZER_FLAGS + DWARF-3
#   /mayhem/microscheme-oracle  — the functional-test build: NORMAL flags (test.sh only RUNS this)
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) so an explicit empty --build-arg SANITIZER_FLAGS builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${SRC:=/mayhem}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS

cd "$SRC"

# Always ensure the fuzz binary carries SanitizerCoverage instrumentation, even for an
# explicit no-sanitizer override build (mirrors cc65/qcbor's build.sh convention) — without
# this, $SANITIZER_FLAGS carries no coverage flags and Mayhem records 0 edges even though
# the target builds and runs fine.
case "$SANITIZER_FLAGS" in
  *fuzzer-no-link*) ;;
  *) SANITIZER_FLAGS="$SANITIZER_FLAGS -fsanitize=fuzzer-no-link" ;;
esac

# 1) Generate the hexified embedded sources exactly as upstream does (idempotent: `make
#    hexify` only regenerates src/assembly_hex.c + src/microscheme_hex.c from src/*.s and
#    src/*.ms, so a re-run on an already-built tree is a harmless repeat, not a failure).
make -C "$SRC" hexify

# 2) Fuzz target: the whole compiler built with sanitizers + DWARF-3, with upstream's `main`
#    renamed (-Dmain=microscheme_original_main; exactly one `main` exists, in src/main.c) and
#    mayhem/microscheme_wrapper_main.c supplying the real entry point, which chdir("/tmp")s
#    before calling into the original -- see that file's header for why (Mayhemfile `cwd:` on a
#    raw process-per-input cmd triggers a mayhem-fuzz restart loop on this Mayhem version; the
#    chdir has to happen inside the binary instead). The rename must NOT apply to the wrapper's
#    own `main` (it needs to stay the real entry point), so it is compiled in a separate step,
#    exactly like chaos's chaos_watchdog_main.c / -Dmain=chaos_original_main precedent.
mkdir -p build-fuzz
( cd build-fuzz
  $CC -c -std=gnu99 -Wall -Wextra $SANITIZER_FLAGS $DEBUG_FLAGS -Dmain=microscheme_original_main \
      "$SRC"/src/*.c
  $CC -c -std=gnu99 -Wall -Wextra $SANITIZER_FLAGS $DEBUG_FLAGS \
      -o microscheme_wrapper_main.o "$SRC"/mayhem/microscheme_wrapper_main.c
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS -o /mayhem/microscheme ./*.o )

# 3) Oracle build with the project's NORMAL flags, dynamically linked (so verify-repo's
#    LD_PRELOAD sabotage shim can neuter it — SPEC §6.3 anti-reward-hack). test.sh only RUNS
#    this; it never compiles.
$CC -std=gnu99 -O2 -o /mayhem/microscheme-oracle "$SRC"/src/*.c

# Sanity: both binaries dynamically linked (plain clang default; asserted so a toolchain
# change can't silently produce a static binary Mayhem/gdb triage can't use) and the fuzz
# binary carries DWARF <= 3.
for t in /mayhem/microscheme /mayhem/microscheme-oracle; do
  file "$t" | grep -q 'dynamically linked' || {
    echo "FATAL: $t is not dynamically linked" >&2; exit 1; }
done

echo "build.sh complete:"
ls -la /mayhem/microscheme /mayhem/microscheme-oracle
