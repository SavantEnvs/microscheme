#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for the microscheme compiler.
#
# Upstream ships NO functional test suite (its `make check` is cppcheck + clang-format lint
# only), so this is an AUTHORED known-answer oracle: it compiles every shipped example
# program with the oracle build (/mayhem/microscheme-oracle, built by build.sh with normal
# flags) and asserts EXACT OUTPUT, not just exit status:
#   * each example compiles for MEGA, emits a substantial .s (>10 KB) containing real
#     generated code (procedure-return labels, AVR `LDI` instructions) and the model
#     header (`.EQU` block);
#   * KAT: compiling examples/helloworld.ms for MEGA is fully deterministic (no
#     timestamps/addresses in the output — verified by hand) and must reproduce an EXACT
#     sha256 digest of the generated assembly, and must contain an EXACT expected line
#     (model-specific `_ms_stack` constant);
#   * KAT: the SAME source compiled for UNO must reproduce a DIFFERENT exact digest and a
#     different exact `_ms_stack` line (`__stack` vs `0x2000`) — proves the model flag
#     actually reaches codegen, not just "some .s got written";
#   * negative: syntactically-invalid / unbound-variable programs must FAIL (non-zero
#     exit, no .s produced).
# A sabotaged compiler that just exit(0)s produces no assembly and fails every assertion
# (verify-repo's LD_PRELOAD sabotage shim proves this mechanically).
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${SRC:=/mayhem}"
cd "$SRC"

MSC=/mayhem/microscheme-oracle
if [ ! -x "$MSC" ]; then
  echo "FATAL: $MSC missing — mayhem/build.sh must build the oracle binary" >&2
  exit 1
fi

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# Known-answer constants, computed by hand once against this commit's oracle build
# (clang -std=gnu99 -O2, matching mayhem/build.sh exactly) and pinned here. A neutered or
# behaviorally-changed compiler cannot reproduce these.
KAT_MEGA_SHA256=0cec57d0f32a5461b4eb488028fc2cf5b63a2d517d6d20d9a8deb223d2aa8ad8
KAT_UNO_SHA256=61ed52d7778e3b27a83a5911cdfe2284e1512f2d0eb57e7cb3914a0b3a3bc5ae
KAT_MEGA_STACK_LINE=$'.EQU\t_ms_stack,\t0x2000'
KAT_UNO_STACK_LINE=$'.EQU\t_ms_stack,\t__stack'

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "PASS: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1" >&2; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
cp "$SRC"/examples/*.ms "$WORK"/
cp -r "$SRC"/libraries "$WORK"/libraries
cd "$WORK"

# 1) every shipped example compiles for MEGA and emits real assembly
for ex in *.ms; do
  b="${ex%.ms}"
  rm -f "$b.s"
  if "$MSC" -m MEGA "$ex" >/dev/null 2>&1 \
     && [ -s "$b.s" ] \
     && [ "$(wc -c < "$b.s")" -gt 10000 ] \
     && grep -q 'proc_ret' "$b.s" \
     && grep -q '^[[:space:]]*LDI ' "$b.s" \
     && grep -q '^\.EQU' "$b.s"; then
    ok "compile $ex (MEGA): assembly emitted + structural markers"
  else
    bad "compile $ex (MEGA)"
  fi
done

# 2) KAT: helloworld.ms compiled for MEGA must reproduce an EXACT known digest and an
#    EXACT known line (grep -qxF = whole-line, fixed-string match — no pattern drift).
rm -f helloworld.s
"$MSC" -m MEGA helloworld.ms >/dev/null 2>&1
if [ -s helloworld.s ] \
   && [ "$(sha256sum helloworld.s | cut -d' ' -f1)" = "$KAT_MEGA_SHA256" ] \
   && grep -qxF "$KAT_MEGA_STACK_LINE" helloworld.s; then
  ok "KAT MEGA: helloworld.ms -> exact sha256 $KAT_MEGA_SHA256 + exact _ms_stack line"
else
  bad "KAT MEGA: helloworld.ms exact-output mismatch"
fi
mv -f helloworld.s hw-mega.s 2>/dev/null

# 3) KAT: the SAME source compiled for UNO must reproduce a DIFFERENT exact digest and a
#    DIFFERENT exact _ms_stack line — proves -m actually reaches codegen.
"$MSC" -m UNO helloworld.ms >/dev/null 2>&1
if [ -s helloworld.s ] \
   && [ "$(sha256sum helloworld.s | cut -d' ' -f1)" = "$KAT_UNO_SHA256" ] \
   && grep -qxF "$KAT_UNO_STACK_LINE" helloworld.s \
   && ! cmp -s hw-mega.s helloworld.s; then
  ok "KAT UNO: helloworld.ms -> exact sha256 $KAT_UNO_SHA256 + exact _ms_stack line, differs from MEGA"
else
  bad "KAT UNO: helloworld.ms exact-output mismatch"
fi

# 4) negative: invalid programs must be rejected (non-zero exit, no output)
printf '(define (f x) (' > bad-syntax.ms
if "$MSC" -m MEGA bad-syntax.ms >/dev/null 2>&1 || [ -e bad-syntax.s ]; then
  bad "negative: unterminated form accepted"
else
  ok "negative: unterminated form rejected"
fi

printf '(f-undefined-proc 1 2)' > bad-unbound.ms
if "$MSC" -m MEGA bad-unbound.ms >/dev/null 2>&1 || [ -e bad-unbound.s ]; then
  bad "negative: unbound identifier accepted"
else
  ok "negative: unbound identifier rejected"
fi

emit_ctrf "authored-kat" "$PASS" "$FAIL"
