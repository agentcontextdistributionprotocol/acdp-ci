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
echo "== full-script cases (run scripts/standardize.sh) =="

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

# --- HEADLINE (Phase 1, frozen): tests/standardize/baseline-drift-demo.txt
#     is committed evidence that the UNMODIFIED, pre-Phase-2 standardize.sh
#     silently dropped acdp-registry-rs's live 4th check. Phase 2 fixes
#     checks_for() (it now declares that 4th check), so re-running that
#     exact demonstration against the fixed script would no longer show a
#     drop -- it would just overwrite real historical evidence with a
#     negative result. So this harness no longer regenerates that file; it
#     only asserts the frozen evidence is still present and still shows the
#     pre-fix bug, and Phase 2's own drift-guard behaviour is proven fresh
#     by the cases below instead (which use a scratch fixture with a check
#     the now-corrected table still doesn't know about, per the task spec,
#     rather than reverting the checks_for() fix to manufacture drift). ---
baseline_file="$SCRIPT_DIR/baseline-drift-demo.txt"
if [ -f "$baseline_file" ] && grep -q "conformance (spec fixtures)' present in that array: false" "$baseline_file"; then
  pass "baseline-drift-demo.txt: frozen Phase-1 evidence is still present and untouched"
else
  fail "baseline-drift-demo.txt: frozen Phase-1 evidence is still present and untouched" "missing or altered: $baseline_file"
fi

echo
echo "== Phase 2: checks_for() corrections + drift guard (full-script) =="

# --- case 2: registry-rs post-fix -> exit 0, "in sync", PUT keeps all 4 ---
FX="$FIXTURES_ROOT/registry-rs-insync"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "in sync"; then
  pass "case2: registry-rs-insync (post-fix) -> exit 0, reports in sync"
else
  fail "case2: registry-rs-insync (post-fix) -> exit 0, reports in sync" "rc=$rc out=$out"
fi
put_body="$(awk '/^gh api -X PUT/{getline; if ($0 ~ /^STDIN: /) { sub(/^STDIN: /, ""); print; exit }}' "$LOG")"
put_contexts="$(printf '%s' "$put_body" | jq -c '.required_status_checks.contexts // empty' 2>/dev/null)"
if [ "$put_contexts" = '["rustfmt","clippy","tests","conformance (spec fixtures)"]' ]; then
  pass "case2: PUT body carries all 4 declared checks, including conformance (spec fixtures)"
else
  fail "case2: PUT body carries all 4 declared checks" "got '$put_contexts'"
fi

# --- case 3: control-plane-reorder -> exit 0 (false-positive regression test) ---
FX="$FIXTURES_ROOT/control-plane-reorder"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-control-plane 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "!! DRIFT:"; then
  pass "case3: control-plane-reorder -> exit 0, reordering is not drift"
else
  fail "case3: control-plane-reorder -> exit 0, reordering is not drift" "rc=$rc out=$out"
fi

# --- case 4: playground missing-declared-check never blocks -> exit 0.
#     checks_for() now declares 3 checks for acdp-playground ("docker image
#     builds" was added); the playground-exact fixture's live branch still
#     only has the original 2. A declared check with nothing live -- the
#     opposite direction from drift (live has something undeclared) -- must
#     never block: extras is computed as live-minus-declared, so a
#     declared-but-not-live check never appears in it. ---
FX="$FIXTURES_ROOT/playground-exact"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-playground 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "!! DRIFT:"; then
  pass "case4: playground missing-declared-check never blocks -> exit 0"
else
  fail "case4: playground missing-declared-check never blocks -> exit 0" "rc=$rc out=$out"
fi

# --- case 5: unprotected -> exit 0, NOT drift ---
FX="$FIXTURES_ROOT/unprotected"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-ci 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "!! DRIFT:"; then
  pass "case5: unprotected -> exit 0, not reported as drift"
else
  fail "case5: unprotected -> exit 0, not reported as drift" "rc=$rc out=$out"
fi

# --- cases 6-9: fail-closed payload shapes -> apply mode exit 1, zero mutations,
#     BEFORE any -X call (guard precedes the first mutation). ---
for case_name in protected-no-rsc contexts-null contexts-not-array invalid-json; do
  FX="$FIXTURES_ROOT/$case_name"
  LOG="$(new_log)"
  out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-ci 2>&1)"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    pass "case $case_name: fail-closed -> exit 1"
  else
    fail "case $case_name: fail-closed -> exit 1" "rc=$rc out=$out"
  fi
  assert_zero_mutations "$LOG" "case $case_name: no mutation is ever attempted (guard precedes PATCH)"
done

# --- G3: a 200 with an empty body makes jq produce no output at all, so
#     live_contexts() must not fall through to `return 0` with an empty
#     $result -- that would violate its own documented contract ("never
#     prints [] on failure"). Built as a scratch fixture (not a committed
#     one) with a genuinely empty branches/main file. ---
EMPTY_BODY_FX="$(mktemp -d)"
echo '{"default_branch":"main"}' > "$EMPTY_BODY_FX/repos_${ORG}_acdp-ci.json"
: > "$EMPTY_BODY_FX/repos_${ORG}_acdp-ci_branches_main.json"
LOG="$(new_log)"
out="$(FIXTURES="$EMPTY_BODY_FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-ci 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "acdp-ci"; then
  pass "G3: empty-body branch read fails closed (exit 1), naming the repo"
else
  fail "G3: empty-body branch read fails closed (exit 1), naming the repo" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "G3: empty-body branch read makes zero mutating calls"
rm -rf "$EMPTY_BODY_FX"

# --- case 10: API failure (branch fixture absent) -> exit 1, no -X in GH_LOG ---
FX="$FIXTURES_ROOT/api-failure"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-ci 2>&1)"
rc=$?
[ "$rc" -eq 1 ] && pass "case10: api-failure -> exit 1" || fail "case10: api-failure -> exit 1" "rc=$rc out=$out"
assert_zero_mutations "$LOG" "case10: api-failure -> no -X in GH_LOG"

# --- case 1: registry-rs pre-fix-style drift, reproduced against a SCRATCH
#     fixture (not a reversion of the checks_for() fix): the now-corrected
#     4-check table still doesn't know about a hypothetical 5th live check.
#     Apply mode must block before any mutation and name the dropped check. ---
SCRATCH_5TH="$(mktemp -d)"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs.json" "$SCRATCH_5TH/"
jq '.protection.required_status_checks.contexts += ["nightly fuzz (spec fixtures)"]
    | .protection.required_status_checks.checks += [{"context":"nightly fuzz (spec fixtures)","app_id":15368}]' \
  "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main.json" \
  > "$SCRATCH_5TH/repos_${ORG}_acdp-registry-rs_branches_main.json"

LOG="$(new_log)"
out="$(FIXTURES="$SCRATCH_5TH" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "nightly fuzz (spec fixtures)"; then
  pass "case1: undeclared 5th live check blocks apply and names it"
else
  fail "case1: undeclared 5th live check blocks apply and names it" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "case1: no mutation reaches gh (guard precedes PATCH)"

# --- --allow-check-removal (record mode): override reaches the PUT, with
#     the reduced (declared-only) contexts body -- proves the override
#     actually reaches the mutation path, not just past the guard. ---
LOG="$(new_log)"
out="$(FIXTURES="$SCRATCH_5TH" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" --allow-check-removal acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- "--allow-check-removal"; then
  pass "override: --allow-check-removal lets a drifted apply complete"
else
  fail "override: --allow-check-removal lets a drifted apply complete" "rc=$rc out=$out"
fi
put_body="$(awk '/^gh api -X PUT/{getline; if ($0 ~ /^STDIN: /) { sub(/^STDIN: /, ""); print; exit }}' "$LOG")"
put_contexts="$(printf '%s' "$put_body" | jq -c '.required_status_checks.contexts // empty' 2>/dev/null)"
if [ "$put_contexts" = '["rustfmt","clippy","tests","conformance (spec fixtures)"]' ]; then
  pass "override: PUT body reaches the mutation path with the reduced (declared-only) contexts"
else
  fail "override: PUT body reaches the mutation path with the reduced (declared-only) contexts" "got '$put_contexts'"
fi
rm -rf "$SCRATCH_5TH"

# --- G1: --check and --allow-check-removal are mutually exclusive. Honoring
#     both (the pre-fix ordering tested ALLOW_CHECK_REMOVAL before
#     CHECK_MODE) would let --check report "all repos in sync" while
#     suppressing a real DRIFT report -- reject the combination outright
#     instead, before any repo is even looked at. ---
LOG="$(new_log)"
out="$(GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check --allow-check-removal acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "mutually exclusive"; then
  pass "flags: --check --allow-check-removal is rejected outright (exit 2)"
else
  fail "flags: --check --allow-check-removal is rejected outright (exit 2)" "rc=$rc out=$out"
fi
if [ ! -s "$LOG" ]; then
  pass "flags: --check --allow-check-removal makes zero gh calls at all (rejected before any repo is touched)"
else
  fail "flags: --check --allow-check-removal makes zero gh calls at all" "GH_LOG is non-empty: $(cat "$LOG")"
fi

# --- --check must print the live contexts it read per repo, even when in sync ---
FX="$FIXTURES_ROOT/registry-rs-insync"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "live" && printf '%s' "$out" | grep -q "rustfmt"; then
  pass "check: prints the live contexts it read, per repo, even when in sync"
else
  fail "check: prints the live contexts it read, per repo, even when in sync" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "check: in-sync repo makes zero mutating calls"

# --- --check on an unreadable repo: reported as an ERROR, distinct from DRIFT ---
FX="$FIXTURES_ROOT/protected-no-rsc"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check acdp-ci 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && ! printf '%s' "$out" | grep -q "!! DRIFT:"; then
  pass "check: unreadable repo is reported distinctly from drift, and still exits 1"
else
  fail "check: unreadable repo is reported distinctly from drift, and still exits 1" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "check: unreadable repo still makes zero mutating calls"

# --- G4: --check <explicitly-named unmanaged repo> must not exit 0 having
#     surveyed nothing -- e.g. a typo'd repo name. checks_for()'s tri-state
#     skip itself is unchanged (it still returns 1 and the loop still
#     `continue`s before any gh call); only CHECK_MODE's exit status
#     changes when that unmanaged repo was named explicitly. No FIXTURES
#     needed: checks_for() rejects the name before any gh call is made. ---
LOG="$(new_log)"
out="$(GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check acdp-typo 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not in the standard set"; then
  pass "G4: --check <typo'd repo> exits non-zero instead of a false all-clear"
else
  fail "G4: --check <typo'd repo> exits non-zero instead of a false all-clear" "rc=$rc out=$out"
fi
if [ ! -s "$LOG" ]; then
  pass "G4: --check <typo'd repo> makes zero gh calls at all"
else
  fail "G4: --check <typo'd repo> makes zero gh calls at all" "GH_LOG is non-empty: $(cat "$LOG")"
fi

# --- G4: the `--` terminator must not lose EXPLICIT_REPOS tracking -- a
#     repo named after `--` is still explicitly-named, so an unmanaged
#     typo behind `--` must also exit non-zero instead of a false
#     all-clear. No FIXTURES needed: checks_for() rejects the name before
#     any gh call is made. ---
LOG="$(new_log)"
out="$(GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check -- acdp-typo 2>&1)"
rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not in the standard set"; then
  pass "G4: --check -- <typo'd repo> exits non-zero instead of a false all-clear"
else
  fail "G4: --check -- <typo'd repo> exits non-zero instead of a false all-clear" "rc=$rc out=$out"
fi
if [ ! -s "$LOG" ]; then
  pass "G4: --check -- <typo'd repo> makes zero gh calls at all"
else
  fail "G4: --check -- <typo'd repo> makes zero gh calls at all" "GH_LOG is non-empty: $(cat "$LOG")"
fi

# --- G4: the `--` terminator does not break a MANAGED repo either -- named
#     after `--`, it is still recognized and checked normally. ---
FX="$FIXTURES_ROOT/unprotected"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check -- acdp-ci 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi "not in the standard set"; then
  pass "G4: --check -- <managed repo> works normally"
else
  fail "G4: --check -- <managed repo> works normally" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "G4: --check -- <managed repo> makes zero mutating calls"

# --- flag parsing: --check works trailing too, and is never mistaken for a repo ---
FX="$FIXTURES_ROOT/unprotected"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" acdp-ci --check 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -qi "not in the standard set"; then
  pass "flags: trailing --check is parsed as a flag, not a repo name"
else
  fail "flags: trailing --check is parsed as a flag, not a repo name" "rc=$rc out=$out"
fi
if grep -q -- '--check' "$LOG"; then
  fail "flags: trailing --check never reaches gh as part of a path" "GH_LOG: $(cat "$LOG")"
else
  pass "flags: trailing --check never reaches gh as part of a path"
fi
assert_zero_mutations "$LOG" "flags: --check (leading or trailing) makes zero mutating calls"

# --- flag parsing: an unknown flag exits 2 ---
out="$("$STANDARDIZE" --this-flag-does-not-exist 2>&1)"
rc=$?
[ "$rc" -eq 2 ] && pass "flags: unknown flag exits 2" || fail "flags: unknown flag exits 2" "rc=$rc out=$out"

# --- -h/--help exits 0 without touching gh at all ---
out="$("$STANDARDIZE" --help 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi "usage"; then
  pass "flags: --help exits 0 and prints usage"
else
  fail "flags: --help exits 0 and prints usage" "rc=$rc out=$out"
fi

# --- multi-repo --check: repo 1 (acdp-control-plane, first in ALL_REPOS)
#     unreadable must still survey repos 2..8, proving accumulation rather
#     than first-error abort. ---
write_insync_fixture() {
  fx_dir="$1"; fx_repo="$2"; shift 2
  fx_ctx="$(printf '%s\n' "$@" | jq -R . | jq -sc .)"
  echo '{"default_branch":"main"}' > "$fx_dir/repos_${ORG}_${fx_repo}.json"
  jq -nc --argjson ctx "$fx_ctx" \
    '{name:"main",protected:true,protection:{enabled:true,required_status_checks:{enforcement_level:"non_admins",contexts:$ctx,checks:($ctx|map({context:.,app_id:15368}))}}}' \
    > "$fx_dir/repos_${ORG}_${fx_repo}_branches_main.json"
}
write_unprotected_fixture() {
  fx_dir="$1"; fx_repo="$2"
  echo '{"default_branch":"main"}' > "$fx_dir/repos_${ORG}_${fx_repo}.json"
  echo '{"name":"main","protected":false,"protection":{"enabled":false,"required_status_checks":{"enforcement_level":"off","contexts":[],"checks":[]}}}' \
    > "$fx_dir/repos_${ORG}_${fx_repo}_branches_main.json"
}

SWEEP_FX="$(mktemp -d)"
write_insync_fixture "$SWEEP_FX" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
write_insync_fixture "$SWEEP_FX" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)"
write_insync_fixture "$SWEEP_FX" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
write_insync_fixture "$SWEEP_FX" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
write_insync_fixture "$SWEEP_FX" acdp-ui-console "Lint · Typecheck · Test · Build"
write_insync_fixture "$SWEEP_FX" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
write_unprotected_fixture "$SWEEP_FX" acdp-ci
write_unprotected_fixture "$SWEEP_FX" .github
# Corrupt repo #1 (first entry in ALL_REPOS) -> unreadable.
rm -f "$SWEEP_FX/repos_${ORG}_acdp-control-plane_branches_main.json"

LOG="$(new_log)"
out="$(FIXTURES="$SWEEP_FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check 2>&1)"
rc=$?
[ "$rc" -ne 0 ] && pass "sweep: --check exits nonzero when repo 1 is unreadable" || fail "sweep: --check exits nonzero when repo 1 is unreadable" "rc=$rc out=$out"
if printf '%s' "$out" | grep -q "acdp-control-plane"; then
  pass "sweep: the unreadable repo 1 is named in the output"
else
  fail "sweep: the unreadable repo 1 is named in the output" "$out"
fi
surveyed_all=1
for r in acdp-registry-rs acdp-playground acdp-verifier-py acdp-ui-console agentcontextdistributionprotocol acdp-ci .github; do
  if ! printf '%s' "$out" | grep -q -- "$r"; then
    surveyed_all=0
    echo "  (sweep: missing from output: $r)"
  fi
done
if [ "$surveyed_all" -eq 1 ]; then
  pass "sweep: repos 2..8 were all surveyed despite repo 1 failing (accumulation, not first-error abort)"
else
  fail "sweep: repos 2..8 were all surveyed despite repo 1 failing" "$out"
fi
assert_zero_mutations "$LOG" "sweep --check: zero mutating calls across the whole sweep"
rm -rf "$SWEEP_FX"

# --- G4 regression guard: the default no-arg full sweep must NOT change --
#     it never names an unmanaged repo (acdp-rs/acdp-website are excluded
#     from ALL_REPOS on purpose), so a clean, fully-in-sync --check sweep
#     must still exit 0 exactly as before this fix. ---
CLEAN_SWEEP_FX="$(mktemp -d)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-ui-console "Lint · Typecheck · Test · Build"
write_insync_fixture "$CLEAN_SWEEP_FX" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
write_unprotected_fixture "$CLEAN_SWEEP_FX" acdp-ci
write_unprotected_fixture "$CLEAN_SWEEP_FX" .github
LOG="$(new_log)"
out="$(FIXTURES="$CLEAN_SWEEP_FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check 2>&1)"
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "G4 regression guard: default no-arg full sweep --check still exits 0 (acdp-rs is never named, so the new explicit-unmanaged check never fires)"
else
  fail "G4 regression guard: default no-arg full sweep --check still exits 0" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "G4 regression guard: full sweep --check makes zero mutating calls"
rm -rf "$CLEAN_SWEEP_FX"

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
