#!/usr/bin/env bash
# tests/standardize/run.sh — offline test harness for scripts/standardize.sh.
#
# Runs a case matrix against a shadow `gh` (tests/standardize/bin/gh) so
# nothing here ever makes a live GitHub call. See tests/standardize/README.md
# for the stub contract and fixture provenance.
#
# bash 3.2 compatible (no `declare -A`, `local -n`, `mapfile`, `${var^^}`,
# `[[ -v ]]`, `&>>`).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DIR="$SCRIPT_DIR/bin"
FIXTURES_ROOT="$SCRIPT_DIR/fixtures"
STANDARDIZE="$REPO_ROOT/scripts/standardize.sh"
ORG=agentcontextdistributionprotocol
BASH32=/bin/bash

export PATH="$BIN_DIR:$PATH"

pass_count=0
fail_count=0

pass() {
  pass_count=$((pass_count + 1))
  echo "PASS: $1"
}

fail() {
  fail_count=$((fail_count + 1))
  echo "FAIL: $1 -- $2"
}

new_log() {
  mktemp "${TMPDIR:-/tmp}/gh-log.XXXXXX"
}

# Number of mutating calls (-X/--method PATCH|PUT|POST|DELETE) recorded in a log.
count_mutations() {
  grep -Ec -- '(^| )(-X|--method) (PATCH|PUT|POST|DELETE)( |$)' "$1" 2>/dev/null
}

assert_zero_mutations() {
  logf="$1"
  name="$2"
  n="$(count_mutations "$logf")"
  if [ "$n" -eq 0 ]; then
    pass "$name (zero mutating calls)"
  else
    fail "$name" "expected zero mutating calls in $logf, found $n"
  fi
}

# --- guard against vacuous green: command -v gh MUST resolve inside bin/ ---
resolved_gh="$(command -v gh || true)"
if [ "$resolved_gh" != "$BIN_DIR/gh" ]; then
  echo "FATAL: command -v gh resolved to '$resolved_gh', expected '$BIN_DIR/gh'" >&2
  exit 1
fi
echo "PATH guard OK: command -v gh -> $resolved_gh"
echo

# =====================================================================
# Direct fixture-serving cases: exercise the gh stub against each fixture
# dir with plain `gh api` calls, independent of standardize.sh. These
# prove the harness itself (parsing, --jq application, loud failure on
# missing/invalid fixtures) before any script ever depends on it.
# =====================================================================

echo "== fixture-serving cases =="

# --- 1. registry-rs-drift: live has the 4th check the table doesn't declare ---
FX="$FIXTURES_ROOT/registry-rs-drift"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs" --jq .default_branch)"
[ "$out" = "main" ] && pass "registry-rs-drift: default_branch" || fail "registry-rs-drift: default_branch" "got '$out'"
n="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs/branches/main" --jq '.protection.required_status_checks.contexts | length')"
[ "$n" = "4" ] && pass "registry-rs-drift: live has 4 contexts" || fail "registry-rs-drift: live has 4 contexts" "got '$n'"
has="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs/branches/main" --jq '.protection.required_status_checks.contexts | index("conformance (spec fixtures)") != null')"
[ "$has" = "true" ] && pass "registry-rs-drift: live includes conformance check" || fail "registry-rs-drift: live includes conformance check" "got '$has'"
assert_zero_mutations "$LOG" "registry-rs-drift: fixture-serving is read-only"

# --- 2. registry-rs-insync: same fixture, reserved for Phase 2's post-fix assertion ---
FX="$FIXTURES_ROOT/registry-rs-insync"
LOG="$(new_log)"
n="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs/branches/main" --jq '.protection.required_status_checks.contexts | length')"
[ "$n" = "4" ] && pass "registry-rs-insync: fixture serves 4 contexts" || fail "registry-rs-insync: fixture serves 4 contexts" "got '$n'"
assert_zero_mutations "$LOG" "registry-rs-insync: fixture-serving is read-only"

# --- 3. control-plane-reorder: same 3 checks, different order (false-positive trap) ---
FX="$FIXTURES_ROOT/control-plane-reorder"
LOG="$(new_log)"
declared='["lint + tsc + jest (unit, coverage-gated)","jest integration (Postgres)","docker build (no push)"]'
live="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-control-plane/branches/main" --jq '.protection.required_status_checks.contexts')"
same_set="$(jq -n --argjson a "$live" --argjson b "$declared" '(($a | sort) == ($b | sort))')"
diff_order="$(jq -n --argjson a "$live" --argjson b "$declared" '($a != $b)')"
if [ "$same_set" = "true" ] && [ "$diff_order" = "true" ]; then
  pass "control-plane-reorder: same set as declared, different order (not drift)"
else
  fail "control-plane-reorder: same set as declared, different order (not drift)" "same_set=$same_set diff_order=$diff_order live=$live"
fi
assert_zero_mutations "$LOG" "control-plane-reorder: fixture-serving is read-only"

# --- 4. playground-exact: exact match, same order ---
FX="$FIXTURES_ROOT/playground-exact"
LOG="$(new_log)"
declared='["pytest + smoke (py3.12)","pytest + smoke (py3.13)"]'
live="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-playground/branches/main" --jq '.protection.required_status_checks.contexts')"
eq="$(jq -n --argjson a "$live" --argjson b "$declared" '$a == $b')"
[ "$eq" = "true" ] && pass "playground-exact: live matches declared exactly" || fail "playground-exact: live matches declared exactly" "got live=$live"
assert_zero_mutations "$LOG" "playground-exact: fixture-serving is read-only"

# --- 5. unprotected: acdp-ci, protected:false ---
FX="$FIXTURES_ROOT/unprotected"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-ci/branches/main" --jq .protected)"
[ "$out" = "false" ] && pass "unprotected: protected=false" || fail "unprotected: protected=false" "got '$out'"
assert_zero_mutations "$LOG" "unprotected: fixture-serving is read-only"

# --- 6. protected-no-rsc: protected:true, no required_status_checks key ---
FX="$FIXTURES_ROOT/protected-no-rsc"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-ci/branches/main" --jq '.protection.required_status_checks // "MISSING"')"
[ "$out" = "MISSING" ] && pass "protected-no-rsc: missing required_status_checks served verbatim" || fail "protected-no-rsc: missing required_status_checks served verbatim" "got '$out'"
assert_zero_mutations "$LOG" "protected-no-rsc: fixture-serving is read-only"

# --- 7. contexts-null ---
FX="$FIXTURES_ROOT/contexts-null"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-ci/branches/main" --jq '.protection.required_status_checks.contexts')"
[ "$out" = "null" ] && pass "contexts-null: served verbatim as null" || fail "contexts-null: served verbatim as null" "got '$out'"
assert_zero_mutations "$LOG" "contexts-null: fixture-serving is read-only"

# --- 8. contexts-not-array (a string) ---
FX="$FIXTURES_ROOT/contexts-not-array"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-ci/branches/main" --jq '.protection.required_status_checks.contexts')"
[ "$out" = "rustfmt" ] && pass "contexts-not-array: served verbatim as a string" || fail "contexts-not-array: served verbatim as a string" "got '$out'"
assert_zero_mutations "$LOG" "contexts-not-array: fixture-serving is read-only"

# --- 9. invalid-json: stub must fail loudly, not return empty ---
FX="$FIXTURES_ROOT/invalid-json"
LOG="$(new_log)"
FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-ci/branches/main" --jq '.' >/dev/null 2>/dev/null
rc=$?
[ "$rc" -ne 0 ] && pass "invalid-json: stub surfaces jq parse failure (exit $rc)" || fail "invalid-json: stub surfaces jq parse failure" "got exit 0"
assert_zero_mutations "$LOG" "invalid-json: fixture-serving is read-only"

# --- 10. api-failure: branch fixture file absent ---
FX="$FIXTURES_ROOT/api-failure"
LOG="$(new_log)"
errfile="$(mktemp)"
FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-ci/branches/main" --jq '.' >/dev/null 2>"$errfile"
rc=$?
if [ "$rc" -eq 1 ] && grep -q "acdp-ci_branches_main.json" "$errfile"; then
  pass "api-failure: missing fixture fails loudly (exit 1, names the expected path)"
else
  fail "api-failure: missing fixture fails loudly" "rc=$rc stderr=$(cat "$errfile")"
fi
rm -f "$errfile"
assert_zero_mutations "$LOG" "api-failure: fixture-serving is read-only (no -X in GH_LOG)"

echo
echo "== full-script cases (run scripts/standardize.sh, unmodified) =="

# --- 11. unmanaged: acdp-rs is not in the managed set; checks_for returns 1,
#     the loop `continue`s before any gh call is ever made. ---
FX="$FIXTURES_ROOT/unmanaged"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-rs 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "not in the standard set"; then
  pass "unmanaged: acdp-rs skipped with the expected message"
else
  fail "unmanaged: acdp-rs skipped with the expected message" "rc=$rc out=$out"
fi
if [ ! -s "$LOG" ]; then
  pass "unmanaged: zero gh calls at all (guard never runs)"
else
  fail "unmanaged: zero gh calls at all" "GH_LOG is non-empty: $(cat "$LOG")"
fi

# --- HEADLINE: unmodified script, record mode, registry-rs-drift fixture.
#     Proves the silent drop: the PUT body's contexts array is missing the
#     live 4th check because checks_for() only declares 3. ---
FX="$FIXTURES_ROOT/registry-rs-drift"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "HEADLINE: unmodified standardize.sh completes in record mode"
else
  fail "HEADLINE: unmodified standardize.sh completes in record mode" "rc=$rc out=$out"
fi

mut_n="$(count_mutations "$LOG")"
[ "$mut_n" -eq 2 ] && pass "HEADLINE: exactly 2 mutating calls (PATCH + PUT)" || fail "HEADLINE: exactly 2 mutating calls (PATCH + PUT)" "got $mut_n"

put_body="$(awk '/^gh api -X PUT/{getline; if ($0 ~ /^STDIN: /) { sub(/^STDIN: /, ""); print; exit }}' "$LOG")"
put_contexts="$(printf '%s' "$put_body" | jq -c '.required_status_checks.contexts // empty' 2>/dev/null)"
if [ "$put_contexts" = '["rustfmt","clippy","tests"]' ]; then
  pass "HEADLINE: PUT body contexts = declared 3 checks only"
else
  fail "HEADLINE: PUT body contexts = declared 3 checks only" "got '$put_contexts'"
fi

dropped="$(printf '%s' "$put_body" | jq '(.required_status_checks.contexts // []) | index("conformance (spec fixtures)") == null' 2>/dev/null)"
if [ "$dropped" = "true" ]; then
  pass "HEADLINE: conformance (spec fixtures) is silently dropped from the PUT"
else
  fail "HEADLINE: conformance (spec fixtures) is silently dropped from the PUT" "got '$dropped'"
fi

# Persist the baseline evidence for the record.
baseline_file="$SCRIPT_DIR/baseline-drift-demo.txt"
{
  echo "# Pre-fix baseline: scripts/standardize.sh (unmodified) silently drops a"
  echo "# live required check that checks_for() does not declare."
  echo "#"
  echo "# Produced by tests/standardize/run.sh running the CURRENT, UNMODIFIED"
  echo "# scripts/standardize.sh against the tests/standardize/fixtures/registry-rs-drift"
  echo "# fixture, with the shadow gh (tests/standardize/bin/gh) in record mode"
  echo "# (GH_STUB_RECORD=1) so the run proceeds past the PATCH to the protection PUT"
  echo "# instead of being blocked at the first mutation."
  echo "#"
  echo "# Live branches/main fixture declares 4 contexts (rustfmt, clippy, tests,"
  echo "# conformance (spec fixtures)); checks_for() for acdp-registry-rs in"
  echo "# scripts/standardize.sh only declares 3 (rustfmt, clippy, tests). Because"
  echo "# the script PUTs required_status_checks.contexts wholesale from that"
  echo "# 3-item table, the live 4th check is silently dropped from the request body"
  echo "# below -- this is the bug Phase 2 fixes."
  echo "#"
  echo "# Command:"
  echo "#   FIXTURES=tests/standardize/fixtures/registry-rs-drift \\"
  echo "#   GH_STUB_RECORD=1 GH_LOG=<log> \\"
  echo "#   PATH=tests/standardize/bin:\$PATH scripts/standardize.sh acdp-registry-rs"
  echo "#"
  echo "# Relevant \$GH_LOG excerpt (the PUT call and its stdin body):"
  echo "#"
  grep -A1 '^gh api -X PUT' "$LOG" | sed 's/^/# /'
  echo "#"
  echo "# Parsed contexts array from that STDIN body:"
  echo "#   $put_contexts"
  echo "#"
  echo "# 'conformance (spec fixtures)' present in that array: false (should be true)"
} > "$baseline_file"
echo
echo "Baseline drift demo written to $baseline_file"

# --- block-mode guard: default mode must refuse the mutation, never reach PUT ---
FX="$FIXTURES_ROOT/unprotected"
LOG="$(new_log)"
FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-ci >/dev/null 2>/dev/null
rc=$?
[ "$rc" -eq 99 ] && pass "block-mode guard: exit 99 on first mutation" || fail "block-mode guard: exit 99 on first mutation" "got rc=$rc"
if grep -q "BLOCKED MUTATION PATCH repos/$ORG/acdp-ci" "$LOG"; then
  pass "block-mode guard: PATCH was the blocked call"
else
  fail "block-mode guard: PATCH was the blocked call" "GH_LOG: $(cat "$LOG")"
fi
if grep -q "PUT" "$LOG"; then
  fail "block-mode guard: PUT never attempted" "PUT appears in GH_LOG: $(cat "$LOG")"
else
  pass "block-mode guard: PUT never attempted (script aborted at the first mutation)"
fi

# --- bash 3.2 compatibility: run the same block-mode guard case explicitly
#     under /bin/bash (macOS stock 3.2.57), not the 5.x `bash` on PATH. ---
if [ -x "$BASH32" ]; then
  LOG="$(new_log)"
  FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$BASH32" "$STANDARDIZE" acdp-ci >/dev/null 2>/dev/null
  rc=$?
  if [ "$rc" -eq 99 ] && grep -q "BLOCKED MUTATION PATCH repos/$ORG/acdp-ci" "$LOG"; then
    pass "bash-3.2 ($BASH32): standardize.sh runs and blocks identically"
  else
    fail "bash-3.2 ($BASH32): standardize.sh runs and blocks identically" "rc=$rc GH_LOG=$(cat "$LOG")"
  fi
else
  fail "bash-3.2 ($BASH32) availability" "not found or not executable on this machine"
fi

echo
echo "===================="
echo "  $pass_count passed, $fail_count failed"
echo "===================="

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
