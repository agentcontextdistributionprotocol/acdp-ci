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
  # Exact name on a side channel for mutants.sh. Parsing it back out of the
  # line above is not safe: three test names legitimately contain " -- "
  # (the `G4: --check -- <typo'd repo>` cases), so a split on that separator
  # silently truncates them to "G4: --check" and merges three distinct tests
  # into one. A killer-set comparison built on that would be quietly wrong in
  # both directions. Unset in normal runs; nothing is written.
  if [ -n "${FAILNAME_LOG:-}" ]; then
    printf '%s\n' "$1" >> "$FAILNAME_LOG"
  fi
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

# --- 1. registry-rs-drift: 4 live contexts incl. the one the old table dropped (fixture-serving only) ---
FX="$FIXTURES_ROOT/registry-rs-drift"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs" --jq .default_branch)"
[ "$out" = "main" ] && pass "registry-rs-drift: default_branch" || fail "registry-rs-drift: default_branch" "got '$out'"
n="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs/branches/main" --jq '.protection.required_status_checks.contexts | length')"
[ "$n" = "4" ] && pass "registry-rs-drift: live has 4 contexts" || fail "registry-rs-drift: live has 4 contexts" "got '$n'"
has="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs/branches/main" --jq '.protection.required_status_checks.contexts | index("conformance (spec fixtures)") != null')"
[ "$has" = "true" ] && pass "registry-rs-drift: live includes conformance check" || fail "registry-rs-drift: live includes conformance check" "got '$has'"
assert_zero_mutations "$LOG" "registry-rs-drift: fixture-serving is read-only"

# --- 2. registry-rs-insync: the canonical in-sync registry fixture (11 live contexts) ---
FX="$FIXTURES_ROOT/registry-rs-insync"
LOG="$(new_log)"
n="$(FIXTURES="$FX" GH_LOG="$LOG" gh api "repos/$ORG/acdp-registry-rs/branches/main" --jq '.protection.required_status_checks.contexts | length')"
[ "$n" = "11" ] && pass "registry-rs-insync: fixture serves 11 contexts" || fail "registry-rs-insync: fixture serves 11 contexts" "got '$n'"
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

# --- case 2: registry-rs post-fix -> exit 0, "in sync", PUT keeps every declared check ---
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
put_contexts="$(printf '%s' "$put_body" | jq -c '[.required_status_checks.checks[].context]' 2>/dev/null)"
if [ "$put_contexts" = '["rustfmt","clippy","tests","conformance (spec fixtures)","cargo-deny","lint","msrv","rustdoc","coverage","docker (build + smoke)","mutants pins"]' ]; then
  pass "case2: PUT body carries all 11 declared checks, including msrv, coverage and mutants pins"
else
  fail "case2: PUT body carries all 11 declared checks" "got '$put_contexts'"
fi
put_pin="$(printf '%s' "$put_body" | jq -c '[.required_status_checks.checks[].app_id] | unique' 2>/dev/null)"
[ "$put_pin" = "[15368]" ] && pass "case2: registry PUT pins every check to app_id 15368 via checks" || fail "case2: registry PUT pins every check to app_id 15368 via checks" "got '$put_pin'"
put_ea="$(printf '%s' "$put_body" | jq -c '.enforce_admins' 2>/dev/null)"
[ "$put_ea" = "true" ] && pass "case2: registry PUT sets enforce_admins:true (issue #29)" || fail "case2: registry PUT sets enforce_admins:true (issue #29)" "got '$put_ea'"

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
#     11-check table still doesn't know about a hypothetical 7th live check.
#     Apply mode must block before any mutation and name the dropped check. ---
SCRATCH_5TH="$(mktemp -d)"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs.json" "$SCRATCH_5TH/"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_contents_.github_required-checks.json.json" "$SCRATCH_5TH/"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main_protection.json" "$SCRATCH_5TH/"
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
put_contexts="$(printf '%s' "$put_body" | jq -c '[.required_status_checks.checks[].context]' 2>/dev/null)"
if [ "$put_contexts" = '["rustfmt","clippy","tests","conformance (spec fixtures)","cargo-deny","lint","msrv","rustdoc","coverage","docker (build + smoke)","mutants pins"]' ]; then
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
# Exit 2, not 1: this invocation names a single repo, so an unreadable repo
# means EVERY surveyed repo was unreadable and the run learned nothing. A
# result you did not obtain must not share an exit code with a result you did
# (drift/pending), because drift-check.yml treats exit 1 as a reportable
# finding -- green job, routine-looking issue -- and anything else as a hard
# failure. The partial case (some readable, some not) is still 1; that is
# pinned separately in the sweep section below.
FX="$FIXTURES_ROOT/protected-no-rsc"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check acdp-ci 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q "!! DRIFT:"; then
  pass "check: wholly-unreadable survey is fatal (exit 2), and distinct from drift"
else
  fail "check: wholly-unreadable survey is fatal (exit 2), and distinct from drift" "rc=$rc out=$out"
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

# write_org_listing <dir> [name:archived ...] -- the orgs/<org>/repos fixture the
# default --check sweep reads for the UNREGISTERED condition (acdp-ci#19). Always
# lists every managed + deliberately-excluded repo; extras are name:archived.
write_org_listing() {
  fx_dir="$1"; shift
  {
    for n in acdp-control-plane acdp-registry-rs acdp-playground acdp-verifier-py acdp-ui-console agentcontextdistributionprotocol acdp-ci .github acdp-rs acdp-website acdp-docs; do
      printf '%s\tfalse\n' "$n"
    done
    for e in "$@"; do printf '%s\t%s\n' "${e%%:*}" "${e##*:}"; done
  } | jq -R -s -c 'split("\n")|map(select(length>0)|split("\t")|{name:.[0],archived:(.[1]=="true"),fork:false})' > "$fx_dir/orgs_${ORG}_repos.json"
}

# write_registry_baseline <dir> -- serve acdp-registry-rs's committed
# .github/required-checks.json (raw) from the canonical fixture.
write_registry_baseline() {
  cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_contents_.github_required-checks.json.json" "$1/"
  cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main_protection.json" "$1/"
}

SWEEP_FX="$(mktemp -d)"
write_insync_fixture "$SWEEP_FX" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
write_insync_fixture "$SWEEP_FX" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)" "cargo-deny" "lint" "msrv" "rustdoc" "coverage" "docker (build + smoke)" "mutants pins"
write_insync_fixture "$SWEEP_FX" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
write_insync_fixture "$SWEEP_FX" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
write_insync_fixture "$SWEEP_FX" acdp-ui-console "Lint · Typecheck · Test · Build"
write_insync_fixture "$SWEEP_FX" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
write_unprotected_fixture "$SWEEP_FX" acdp-ci
write_unprotected_fixture "$SWEEP_FX" .github
write_org_listing "$SWEEP_FX"
write_registry_baseline "$SWEEP_FX"
# Corrupt repo #1 (first entry in ALL_REPOS) -> unreadable.
rm -f "$SWEEP_FX/repos_${ORG}_acdp-control-plane_branches_main.json"

LOG="$(new_log)"
out="$(FIXTURES="$SWEEP_FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check 2>&1)"
rc=$?
# Exactly 1, not merely nonzero: 1 of 8 unreadable is a genuine per-repo
# finding and must stay reportable. Only a wholly-failed survey escalates to
# the fatal 2. Asserting "nonzero" here would let the two collapse together.
[ "$rc" -eq 1 ] && pass "sweep: partial failure (1 of 8 unreadable) stays a finding, exit 1" || fail "sweep: partial failure (1 of 8 unreadable) stays a finding, exit 1" "rc=$rc out=$out"
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
#     it never names an unmanaged repo (acdp-rs/acdp-website/acdp-docs are excluded
#     from ALL_REPOS on purpose), so a clean, fully-in-sync --check sweep
#     must still exit 0 exactly as before this fix. ---
CLEAN_SWEEP_FX="$(mktemp -d)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)" "cargo-deny" "lint" "msrv" "rustdoc" "coverage" "docker (build + smoke)" "mutants pins"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
write_insync_fixture "$CLEAN_SWEEP_FX" acdp-ui-console "Lint · Typecheck · Test · Build"
write_insync_fixture "$CLEAN_SWEEP_FX" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
write_unprotected_fixture "$CLEAN_SWEEP_FX" acdp-ci
write_unprotected_fixture "$CLEAN_SWEEP_FX" .github
write_org_listing "$CLEAN_SWEEP_FX"
write_registry_baseline "$CLEAN_SWEEP_FX"
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
echo "== G1: missing = declared - live (pending-apply reporting) =="

# --- G1a: playground-exact is declared (3, checks_for() now includes
#     "docker image builds") ⊋ live (2). --check must exit 1 and name the
#     missing check under its own "!! PENDING:" marker, distinct from
#     "!! DRIFT:", with zero mutating calls. ---
FX="$FIXTURES_ROOT/playground-exact"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check acdp-playground 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "!! PENDING:" && printf '%s' "$out" | grep -q "docker image builds"; then
  pass "G1a: --check on declared⊋live (playground-exact) exits 1 with PENDING marker naming the missing check"
else
  fail "G1a: --check on declared⊋live (playground-exact) exits 1 with PENDING marker naming the missing check" "rc=$rc out=$out"
fi
if ! printf '%s' "$out" | grep -q "!! DRIFT:"; then
  pass "G1a: declared⊋live is reported as PENDING, never as DRIFT (opposite axis)"
else
  fail "G1a: declared⊋live is reported as PENDING, never as DRIFT" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "G1a: --check on declared⊋live makes zero mutating calls"

# --- G1b: APPLY mode against that SAME fixture must still proceed all the
#     way to the mutation -- missing never blocks apply, since the PUT
#     about to run is exactly what adds the missing check. The PUT body
#     carries checks_for()'s full declared set (all 3), since contexts_json
#     is always the declared list, never filtered by what's live. ---
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-playground 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "!! PENDING:"; then
  pass "G1b: apply mode on declared⊋live still exits 0 (missing never blocks), PENDING reported informationally"
else
  fail "G1b: apply mode on declared⊋live still exits 0 (missing never blocks)" "rc=$rc out=$out"
fi
n_mut="$(count_mutations "$LOG")"
if [ "$n_mut" -gt 0 ]; then
  pass "G1b: apply mode on declared⊋live reaches the mutation (missing never blocks the apply)"
else
  fail "G1b: apply mode on declared⊋live reaches the mutation" "expected >0 mutating calls in $LOG, found $n_mut"
fi
put_body="$(awk '/^gh api -X PUT/{getline; if ($0 ~ /^STDIN: /) { sub(/^STDIN: /, ""); print; exit }}' "$LOG")"
put_contexts="$(printf '%s' "$put_body" | jq -c '.required_status_checks.contexts // empty' 2>/dev/null)"
if [ "$put_contexts" = '["pytest + smoke (py3.12)","pytest + smoke (py3.13)","docker image builds"]' ]; then
  pass "G1b: PUT body carries checks_for()'s full declared set, including the previously-missing check"
else
  fail "G1b: PUT body carries checks_for()'s full declared set" "got '$put_contexts'"
fi

# --- G1c: a clean full sweep (declared == live for every managed repo)
#     still exits 0 -- regression guard, reusing the same fixtures as the
#     G4 regression-guard sweep above (already declared == live for every
#     repo, including acdp-playground's 3 checks and acdp-verifier-py's 4,
#     so no fixture changes were needed for this fix). Re-run --check here
#     explicitly asserting no PENDING marker appears anywhere. ---
CLEAN_SWEEP2_FX="$(mktemp -d)"
write_insync_fixture "$CLEAN_SWEEP2_FX" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
write_insync_fixture "$CLEAN_SWEEP2_FX" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)" "cargo-deny" "lint" "msrv" "rustdoc" "coverage" "docker (build + smoke)" "mutants pins"
write_insync_fixture "$CLEAN_SWEEP2_FX" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
write_insync_fixture "$CLEAN_SWEEP2_FX" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
write_insync_fixture "$CLEAN_SWEEP2_FX" acdp-ui-console "Lint · Typecheck · Test · Build"
write_insync_fixture "$CLEAN_SWEEP2_FX" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
write_unprotected_fixture "$CLEAN_SWEEP2_FX" acdp-ci
write_unprotected_fixture "$CLEAN_SWEEP2_FX" .github
write_org_listing "$CLEAN_SWEEP2_FX"
write_registry_baseline "$CLEAN_SWEEP2_FX"
LOG="$(new_log)"
out="$(FIXTURES="$CLEAN_SWEEP2_FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check 2>&1)"
rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "!! PENDING:"; then
  pass "G1c: clean full sweep (declared == live everywhere) still exits 0, no PENDING marker"
else
  fail "G1c: clean full sweep still exits 0, no PENDING marker" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "G1c: clean full sweep --check makes zero mutating calls"
rm -rf "$CLEAN_SWEEP2_FX"

# --- G1d: drift (extras) AND missing together on the SAME repo -> exit 1,
#     BOTH markers appear. This fixture hardcodes its own 4-item contexts/checks
#     arrays below (does not derive from registry-rs-insync's base count) --
#     live is {rustfmt, clippy, tests, "nightly fuzz (spec fixtures)"}, so live
#     has one check checks_for()'s now-6-item declared set doesn't declare
#     (extras: nightly fuzz) AND is missing several checks_for() does declare
#     (missing: conformance (spec fixtures), cargo-deny, lint), in the same
#     repo, same run -- the assertion below only greps for BOTH marker types
#     appearing and for "conformance (spec fixtures)" surviving in the missing
#     list, so it holds regardless of the exact missing-set size. ---
SCRATCH_BOTH="$(mktemp -d)"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs.json" "$SCRATCH_BOTH/"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_contents_.github_required-checks.json.json" "$SCRATCH_BOTH/"
cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main_protection.json" "$SCRATCH_BOTH/"
jq '.protection.required_status_checks.contexts = ["rustfmt","clippy","tests","nightly fuzz (spec fixtures)"]
    | .protection.required_status_checks.checks = [
        {"context":"rustfmt","app_id":15368},
        {"context":"clippy","app_id":15368},
        {"context":"tests","app_id":15368},
        {"context":"nightly fuzz (spec fixtures)","app_id":15368}
      ]' \
  "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main.json" \
  > "$SCRATCH_BOTH/repos_${ORG}_acdp-registry-rs_branches_main.json"

LOG="$(new_log)"
out="$(FIXTURES="$SCRATCH_BOTH" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check acdp-registry-rs 2>&1)"
rc=$?
if [ "$rc" -eq 1 ] \
   && printf '%s' "$out" | grep -q "!! DRIFT:" \
   && printf '%s' "$out" | grep -q "nightly fuzz (spec fixtures)" \
   && printf '%s' "$out" | grep -q "!! PENDING:" \
   && printf '%s' "$out" | grep -q "conformance (spec fixtures)"; then
  pass "G1d: drift and missing together on the same repo -> exit 1, BOTH markers appear"
else
  fail "G1d: drift and missing together on the same repo -> exit 1, BOTH markers appear" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "G1d: drift+missing --check makes zero mutating calls"
rm -rf "$SCRATCH_BOTH"

# --- FATAL vs FINDING: a run that never happened must not look like a result ---
# drift-check.yml routes exit 1 to "file an issue, job green" and anything else
# to a hard job failure. So every way the check can fail to RUN has to land
# outside {0,1}, or a broken monitor reports as a working one.

# (a) whole-sweep read failure -> 2, not 1. An empty fixture dir makes every
# repo's read fail, standing in for a degraded token or an unreachable API.
EMPTY_FX="$(mktemp -d)"
LOG="$(new_log)"
out="$(FIXTURES="$EMPTY_FX" GH_LOG="$LOG" GH_STUB_RECORD=0 "$STANDARDIZE" --check 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "FATAL"; then
  pass "fatal: every repo unreadable -> exit 2 and says FATAL in words"
else
  fail "fatal: every repo unreadable -> exit 2 and says FATAL in words" "rc=$rc out=$out"
fi
assert_zero_mutations "$LOG" "fatal: a wholly-failed survey makes zero mutating calls"
rm -rf "$EMPTY_FX"

# (b) a missing dependency -> 2, not 1. PATH keeps a shell and coreutils but
# drops jq, so the preflight is what fires rather than an interpreter error.
NOJQ_BIN="$(mktemp -d)"
for _t in bash sh env cat sed grep printf mktemp rm gh; do
  _src="$(command -v "$_t" 2>/dev/null)" && ln -sf "$_src" "$NOJQ_BIN/$_t"
done
out="$(PATH="$NOJQ_BIN" "$STANDARDIZE" --check 2>&1)"
rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -qi "jq"; then
  pass "fatal: missing jq -> exit 2 and names the missing tool"
else
  fail "fatal: missing jq -> exit 2 and names the missing tool" "rc=$rc out=$out"
fi
rm -rf "$NOJQ_BIN"

echo
echo "== #22 / #30: stub honesty, enforce_admins bodies, acdp-rs never touched =="

# --- the stub must LOG a call even when $FIXTURES is unset, or every "zero gh
#     calls at all" assertion run without FIXTURES is vacuous. ---
LOG="$(new_log)"
( unset FIXTURES; GH_LOG="$LOG" gh api repos/x/y >/dev/null 2>&1 )
if [ -s "$LOG" ] && grep -q "gh api repos/x/y" "$LOG"; then
  pass "stub: a call made with FIXTURES unset is still logged (zero-call assertions can fail)"
else
  fail "stub: a call made with FIXTURES unset is still logged" "GH_LOG empty: $(cat "$LOG")"
fi

put_body_of() { awk '/^gh api -X PUT/{getline; if ($0 ~ /^STDIN: /) { sub(/^STDIN: /, ""); print; exit }}' "$1"; }

# --- EA1: the protection-only body asserts enforce_admins:true and no checks.
FX="$FIXTURES_ROOT/unprotected"
LOG="$(new_log)"
FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-ci >/dev/null 2>&1
ea1="$(put_body_of "$LOG" | jq -c '[.enforce_admins,.required_status_checks]' 2>/dev/null)"
if [ "$ea1" = "[true,null]" ]; then
  pass "EA1: protection-only PUT (acdp-ci) sets enforce_admins:true and required_status_checks:null"
else
  fail "EA1: protection-only PUT (acdp-ci) sets enforce_admins:true and required_status_checks:null" "got '$ea1'"
fi

# --- EA2: a has-checks repo that is not the registry gets enforce_admins:false
#     and a contexts-only (unpinned) required_status_checks.
FX="$FIXTURES_ROOT/playground-exact"
LOG="$(new_log)"
FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-playground >/dev/null 2>&1
ea2="$(put_body_of "$LOG" | jq -c '[.enforce_admins,(.required_status_checks|has("checks")),(.required_status_checks|has("contexts"))]' 2>/dev/null)"
if [ "$ea2" = "[false,false,true]" ]; then
  pass "EA2: has-checks PUT (acdp-playground) sets enforce_admins:false with contexts and no checks pinning"
else
  fail "EA2: has-checks PUT (acdp-playground) sets enforce_admins:false with contexts and no checks pinning" "got '$ea2'"
fi

# --- #30: a full apply sweep never touches acdp-rs, and no mutating call ever
#     targets a contents/ path (standardize.sh does not write files).
CLEAN_FX="$(mktemp -d)"
write_insync_fixture "$CLEAN_FX" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
write_insync_fixture "$CLEAN_FX" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)" "cargo-deny" "lint" "msrv" "rustdoc" "coverage" "docker (build + smoke)" "mutants pins"
write_insync_fixture "$CLEAN_FX" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
write_insync_fixture "$CLEAN_FX" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
write_insync_fixture "$CLEAN_FX" acdp-ui-console "Lint · Typecheck · Test · Build"
write_insync_fixture "$CLEAN_FX" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
write_unprotected_fixture "$CLEAN_FX" acdp-ci
write_unprotected_fixture "$CLEAN_FX" .github
write_registry_baseline "$CLEAN_FX"
LOG="$(new_log)"
FIXTURES="$CLEAN_FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" >/dev/null 2>&1
rc=$?
nmut="$(count_mutations "$LOG")"
if [ "$rc" -eq 0 ] && [ "$nmut" -ge 16 ]; then
  pass "#30: full apply sweep ran (16 mutating calls recorded) -- the next assertions are not vacuous"
else
  fail "#30: full apply sweep ran" "rc=$rc mutations=$nmut"
fi
if grep -Eq '/acdp-rs(/| |$)' "$LOG"; then
  fail "#30: no gh call during a full sweep ever targets acdp-rs" "$(grep -E '/acdp-rs(/| |$)' "$LOG")"
else
  pass "#30: no gh call during a full sweep ever targets acdp-rs"
fi
# A write is an explicit -X/--method, OR (real gh) any -f/-F/--input body, which
# flips the call to POST without an -X. Match all of them.
if grep -E -- '/contents/' "$LOG" | grep -Eq -- '(^| )((-X|--method) (PATCH|PUT|POST|DELETE)|-f|-F|--input)( |$)'; then
  fail "#30: no mutating call targets a contents/ path (standardize.sh never writes files)" "found"
else
  pass "#30: no mutating call targets a contents/ path (standardize.sh never writes files)"
fi
rm -rf "$CLEAN_FX"

echo
echo "== #19: UNREGISTERED org repos in the default --check sweep =="

build_clean_sweep() {
  d="$1"
  write_insync_fixture "$d" acdp-control-plane "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)"
  write_insync_fixture "$d" acdp-registry-rs "rustfmt" "clippy" "tests" "conformance (spec fixtures)" "cargo-deny" "lint" "msrv" "rustdoc" "coverage" "docker (build + smoke)" "mutants pins"
  write_insync_fixture "$d" acdp-playground "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds"
  write_insync_fixture "$d" acdp-verifier-py "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)"
  write_insync_fixture "$d" acdp-ui-console "Lint · Typecheck · Test · Build"
  write_insync_fixture "$d" agentcontextdistributionprotocol "All Validations Passed" "Validate Schemas, Examples, and Conformance"
  write_unprotected_fixture "$d" acdp-ci
  write_unprotected_fixture "$d" .github
  write_registry_baseline "$d"
}

# B1: clean listing -> exit 0, no marker.
U_FX="$(mktemp -d)"; build_clean_sweep "$U_FX"; write_org_listing "$U_FX"
LOG="$(new_log)"
out="$(FIXTURES="$U_FX" GH_LOG="$LOG" "$STANDARDIZE" --check 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q "UNREGISTERED"; then
  pass "B1: every org repo accounted for -> exit 0, no UNREGISTERED"
else
  fail "B1: every org repo accounted for -> exit 0, no UNREGISTERED" "rc=$rc out=$out"
fi
grep -q "orgs/$ORG/repos" "$LOG" && pass "B1: the sweep did enumerate the org (not vacuous)" || fail "B1: the sweep did enumerate the org (not vacuous)" "no orgs/ call in log"

# B10: acdp-docs (private KB + MCP repo) is deliberately excluded: it is in the
# listing yet never reported UNREGISTERED. Not vacuous -- the listing really
# contains it.
jq -e 'any(.[]; .name == "acdp-docs")' "$U_FX/orgs_${ORG}_repos.json" >/dev/null \
  && ! printf '%s' "$out" | grep -q "UNREGISTERED: acdp-docs" \
  && pass "B10: acdp-docs is in the org listing and treated as deliberately excluded" \
  || fail "B10: acdp-docs is in the org listing and treated as deliberately excluded" "out=$out"

# B2: an unaccounted-for repo -> exit 1, named, no DRIFT, zero mutations.
write_org_listing "$U_FX" acdp-newrepo:false
LOG="$(new_log)"
out="$(FIXTURES="$U_FX" GH_LOG="$LOG" "$STANDARDIZE" --check 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "!! UNREGISTERED: acdp-newrepo" && ! printf '%s' "$out" | grep -q "!! DRIFT"; then
  pass "B2: unregistered repo -> exit 1, named, no DRIFT"
else
  fail "B2: unregistered repo -> exit 1, named, no DRIFT" "rc=$rc out=$out"
fi
printf '%s' "$out" | grep -q "unregistered org repo(s)" && pass "B2: summary names the unregistered condition" || fail "B2: summary names the unregistered condition" "$out"
assert_zero_mutations "$LOG" "B2: --check stays read-only"

# B5: an archived extra is ignored (and said so).
write_org_listing "$U_FX" acdp-oldrepo:true
out="$(FIXTURES="$U_FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "ignoring archived org repo: acdp-oldrepo"; then
  pass "B5: archived extra repo is ignored, and reported as ignored"
else
  fail "B5: archived extra repo is ignored, and reported as ignored" "rc=$rc out=$out"
fi

# B3: the listing cannot be read -> exit 1 (a finding about the check itself), never a silent pass.
rm -f "$U_FX/orgs_${ORG}_repos.json"
out="$(FIXTURES="$U_FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "cannot enumerate org repos"; then
  pass "B3: unreadable org listing -> exit 1 and says the check did not run"
else
  fail "B3: unreadable org listing -> exit 1 and says the check did not run" "rc=$rc out=$out"
fi

# B4: empty listing / listing missing a managed repo -> not trustworthy.
echo '[]' > "$U_FX/orgs_${ORG}_repos.json"
out="$(FIXTURES="$U_FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "cannot enumerate" && pass "B4a: empty listing -> exit 1, not a clean pass" || fail "B4a: empty listing -> exit 1, not a clean pass" "rc=$rc out=$out"
write_org_listing "$U_FX"
jq -c 'map(select(.name != "acdp-ui-console"))' "$U_FX/orgs_${ORG}_repos.json" > "$U_FX/x" && mv "$U_FX/x" "$U_FX/orgs_${ORG}_repos.json"
out="$(FIXTURES="$U_FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "does not contain accounted-for repo 'acdp-ui-console'" && pass "B4b: listing missing a managed repo -> exit 1, names it" || fail "B4b: listing missing a managed repo -> exit 1, names it" "rc=$rc out=$out"

# B9: stale exclusion (excluded repo gone from the org) -> exit 1, names it.
write_org_listing "$U_FX"
jq -c 'map(select(.name != "acdp-website"))' "$U_FX/orgs_${ORG}_repos.json" > "$U_FX/x" && mv "$U_FX/x" "$U_FX/orgs_${ORG}_repos.json"
out="$(FIXTURES="$U_FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "accounted-for repo 'acdp-website'" && pass "B9: stale exclusion -> exit 1, names it" || fail "B9: stale exclusion -> exit 1, names it" "rc=$rc out=$out"

# B6: naming a repo is a targeted check: no org enumeration.
write_org_listing "$U_FX" acdp-newrepo:false
LOG="$(new_log)"
FIXTURES="$U_FX" GH_LOG="$LOG" "$STANDARDIZE" --check acdp-ci >/dev/null 2>&1; rc=$?
if [ "$rc" -eq 0 ] && ! grep -q "orgs/" "$LOG"; then
  pass "B6: --check <repo> makes no org enumeration call (and ignores the unregistered repo)"
else
  fail "B6: --check <repo> makes no org enumeration call" "rc=$rc log=$(cat "$LOG")"
fi

# B7: apply mode never enumerates the org.
LOG="$(new_log)"
FIXTURES="$U_FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-ci >/dev/null 2>&1
grep -q "orgs/" "$LOG" && fail "B7: apply mode makes no org enumeration call" "found orgs/ in log" || pass "B7: apply mode makes no org enumeration call"
rm -rf "$U_FX"

# G4 (strengthened after #19): the `--` terminator must keep EXPLICIT_REPOS, or
# `--check -- <typo>` falls through to the full default sweep and, against a
# clean org, exits 0 -- a false all-clear. Offline this needs a fully clean
# sweep fixture: without one the fall-through fails for an unrelated reason
# (missing fixtures) and the exit-non-zero assertion is vacuous.
G4_FX="$(mktemp -d)"; build_clean_sweep "$G4_FX"; write_org_listing "$G4_FX"
out="$(FIXTURES="$G4_FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check -- acdp-typo 2>&1)"; rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "not in the standard set"; then
  pass "G4b: --check -- <typo'd repo> against a CLEAN org still exits non-zero (no false all-clear)"
else
  fail "G4b: --check -- <typo'd repo> against a CLEAN org still exits non-zero (no false all-clear)" "rc=$rc out=$out"
fi
rm -rf "$G4_FX"

# B8: a repo that is both managed and excluded is a config error (exit 2).
CFG_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/std-cfg.XXXXXX")"
sed 's/^EXCLUDED_REPOS="acdp-rs acdp-website acdp-docs"/EXCLUDED_REPOS="acdp-rs acdp-ci acdp-website acdp-docs"/' "$STANDARDIZE" > "$CFG_SCRIPT"
LOG="$(new_log)"
out="$(FIXTURES="$FIXTURES_ROOT/unprotected" GH_LOG="$LOG" bash "$CFG_SCRIPT" --check acdp-ci 2>&1)"; rc=$?
rm -f "$CFG_SCRIPT"
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q "in both ALL_REPOS and EXCLUDED_REPOS" && [ ! -s "$LOG" ]; then
  pass "B8: managed-and-excluded overlap is a config error (exit 2, before any gh call)"
else
  fail "B8: managed-and-excluded overlap is a config error (exit 2, before any gh call)" "rc=$rc out=$out"
fi

echo
echo "== #33 (#29 item 3): the registry's required checks come from its own baseline file =="

BASE_REL="repos_${ORG}_acdp-registry-rs_contents_.github_required-checks.json.json"
GOOD_BASE="$FIXTURES_ROOT/registry-rs-insync/$BASE_REL"
new_registry_fx() {
  d="$(mktemp -d)"
  cp "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs.json" \
     "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main.json" \
     "$FIXTURES_ROOT/registry-rs-insync/repos_${ORG}_acdp-registry-rs_branches_main_protection.json" "$d/"
  cp "$GOOD_BASE" "$d/$BASE_REL"
  echo "$d"
}

# A1: in sync -> apply exit 0; the PUT is built from the file; the raw media type was requested (A6).
FX="$(new_registry_fx)"; LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"; rc=$?
body="$(put_body_of "$LOG")"
want_checks="$(jq -c '.required' "$GOOD_BASE")"
if [ "$rc" -eq 0 ] && [ "$(printf '%s' "$body" | jq -c '.required_status_checks.checks')" = "$want_checks" ] \
   && [ "$(printf '%s' "$body" | jq -c '[.required_status_checks.strict,.enforce_admins,(.required_status_checks|has("contexts"))]')" = "[true,true,false]" ]; then
  pass "A1: in-sync registry apply PUTs exactly the baseline file checks (with app_ids), strict and enforce_admins"
else
  fail "A1: in-sync registry apply PUTs exactly the baseline file checks" "rc=$rc body=$body out=$out"
fi
printf '%s' "$out" | grep -q "baseline read from .github/required-checks.json (11 checks, enforce_admins=true" && pass "A1: says it read the baseline" || fail "A1: says it read the baseline" "$out"
grep -q "Accept: application/vnd.github.raw" "$LOG" && pass "A6: the contents call asks for the raw media type" || fail "A6: the contents call asks for the raw media type" "$(cat "$LOG")"
# A6b: dropping that header yields the base64 envelope (stub models the real API) -> validation must fail closed.
FXA="$(new_registry_fx)"
envelope="$(FIXTURES="$FXA" GH_LOG="$(new_log)" gh api "repos/$ORG/acdp-registry-rs/contents/.github/required-checks.json" --jq .encoding)"
[ "$envelope" = "base64" ] && pass "A6b: stub serves a base64 envelope when the raw header is absent (so dropping it is a behavioural failure)" || fail "A6b: stub serves a base64 envelope when the raw header is absent" "got '$envelope'"
rm -rf "$FXA"
# A8: bad config around it: unknown top-level keys (_comment, tag_ruleset) are tolerated -- the good fixture has both.
jq -e 'has("_comment") and has("tag_ruleset")' "$GOOD_BASE" >/dev/null && pass "A8: the canonical fixture carries unknown keys, so A1 proves they are tolerated" || fail "A8: the canonical fixture carries unknown keys" "missing"
rm -rf "$FX"

# A2: baseline file missing.
FX="$(new_registry_fx)"; rm -f "$FX/$BASE_REL"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "cannot read .github/required-checks.json"; } && pass "A2: missing baseline -> apply exits 1" || fail "A2: missing baseline -> apply exits 1" "rc=$rc out=$out"
assert_zero_mutations "$LOG" "A2: missing baseline -> apply makes zero mutating calls"
out="$(FIXTURES="$FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check acdp-registry-rs 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "A2: --check on the registry alone with no baseline -> exit 2 (the only surveyed repo is unreadable)" || fail "A2: --check on the registry alone with no baseline -> exit 2" "rc=$rc out=$out"
SW="$(mktemp -d)"; build_clean_sweep "$SW"; write_org_listing "$SW"; rm -f "$SW/$BASE_REL"
out="$(FIXTURES="$SW" GH_LOG="$(new_log)" "$STANDARDIZE" --check 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "acdp-registry-rs: cannot read .github/required-checks.json"; } && pass "A2: sweep with the baseline missing -> exit 1 naming the registry" || fail "A2: sweep with the baseline missing -> exit 1 naming the registry" "rc=$rc out=$out"
rm -rf "$SW" "$FX"

# A3: malformed baselines all fail closed with zero mutations.
check_bad_baseline() {
  label="$1"; content="$2"
  FX="$(new_registry_fx)"; printf '%s' "$content" > "$FX/$BASE_REL"
  LOG="$(new_log)"
  out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"; rc=$?
  if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "not a valid baseline" && [ "$(count_mutations "$LOG")" -eq 0 ]; then
    pass "A3: $label -> refused, exit 1, zero mutations"
  else
    fail "A3: $label -> refused, exit 1, zero mutations" "rc=$rc mutations=$(count_mutations "$LOG") out=$out"
  fi
  rm -rf "$FX"
}
check_bad_baseline "invalid JSON" 'not json {'
check_bad_baseline "a JSON array, not an object" '[1,2]'
check_bad_baseline "empty required (would wipe all checks)" "$(jq -c '.required=[]' "$GOOD_BASE")"
check_bad_baseline "required missing" "$(jq -c 'del(.required)' "$GOOD_BASE")"
check_bad_baseline "non-string context" "$(jq -c '.required[0].context=5' "$GOOD_BASE")"
check_bad_baseline "empty-string context" "$(jq -c '.required[0].context=""' "$GOOD_BASE")"
check_bad_baseline "string app_id" "$(jq -c '.required[0].app_id="15368"' "$GOOD_BASE")"
check_bad_baseline "null app_id" "$(jq -c '.required[0].app_id=null' "$GOOD_BASE")"
check_bad_baseline "fractional app_id" "$(jq -c '.required[0].app_id=1.5' "$GOOD_BASE")"
check_bad_baseline "non-boolean enforce_admins" "$(jq -c '.enforce_admins="yes"' "$GOOD_BASE")"
check_bad_baseline "missing strict" "$(jq -c 'del(.strict)' "$GOOD_BASE")"
check_bad_baseline "non-boolean pending_settings" "$(jq -c '.pending_settings=1' "$GOOD_BASE")"
check_bad_baseline "duplicate contexts" "$(jq -c '.required += [.required[0]]' "$GOOD_BASE")"
check_bad_baseline "context both required and advisory_pending" "$(jq -c '.advisory_pending=["rustfmt"]' "$GOOD_BASE")"
check_bad_baseline "advisory_pending not an array of strings" "$(jq -c '.advisory_pending=[1]' "$GOOD_BASE")"
check_bad_baseline "advisory_pending present but not an array" "$(jq -c '.advisory_pending=false' "$GOOD_BASE")"
check_bad_baseline "context with an embedded newline (would split into two names in the drift guard)" "$(jq -c '.required[0].context="rustfmt\nclippy"' "$GOOD_BASE")"
check_bad_baseline "context that is only a newline (would empty the list -> protection-only PUT)" "$(jq -c '.required |= [{"context":"\n","app_id":15368}]' "$GOOD_BASE")"
check_bad_baseline "whitespace-only context" "$(jq -c '.required[0].context="   "' "$GOOD_BASE")"
check_bad_baseline "app_id -1 (any app: unpins the check)" "$(jq -c '.required[0].app_id=-1' "$GOOD_BASE")"
check_bad_baseline "app_id 0" "$(jq -c '.required[0].app_id=0' "$GOOD_BASE")"
check_bad_baseline "app_id beyond a safe integer" "$(jq -c '.required[0].app_id=4503599627370496' "$GOOD_BASE")"

# A4: file ahead of live -> PENDING; file behind live -> DRIFT and apply is blocked.
FX="$(new_registry_fx)"
jq -c '.required += [{"context":"brand-new-check","app_id":15368}]' "$GOOD_BASE" > "$FX/$BASE_REL"
out="$(FIXTURES="$FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "!! PENDING: acdp-registry-rs: .*brand-new-check"; } && pass "A4: a check added to the baseline but not yet live -> PENDING, exit 1" || fail "A4: baseline ahead of live -> PENDING" "rc=$rc out=$out"
jq -c '.required |= map(select(.context != "rustdoc"))' "$GOOD_BASE" > "$FX/$BASE_REL"
out="$(FIXTURES="$FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "!! DRIFT: acdp-registry-rs: .*rustdoc"; } && pass "A4: a live check the baseline dropped -> DRIFT, exit 1" || fail "A4: baseline behind live -> DRIFT" "rc=$rc out=$out"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(count_mutations "$LOG")" -eq 0 ]; } && pass "A4: apply is blocked by that DRIFT, zero mutations" || fail "A4: apply is blocked by that DRIFT" "rc=$rc"
rm -rf "$FX"

# A9: the registry's own file may not WEAKEN live protection unless --allow-check-removal.
PROT_REL="repos_${ORG}_acdp-registry-rs_branches_main_protection.json"
FX="$(new_registry_fx)"
jq -c '.enforce_admins=false' "$GOOD_BASE" > "$FX/$BASE_REL"
out="$(FIXTURES="$FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "!! DRIFT: acdp-registry-rs: .*WEAKEN live protection.*enforce_admins true -> false"; } && pass "A9: baseline lowering enforce_admins -> DRIFT in --check, exit 1" || fail "A9: baseline lowering enforce_admins -> DRIFT in --check" "rc=$rc out=$out"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(count_mutations "$LOG")" -eq 0 ] && printf '%s' "$out" | grep -q "use --allow-check-removal"; } && pass "A9: apply refuses to lower enforce_admins, zero mutations" || fail "A9: apply refuses to lower enforce_admins" "rc=$rc out=$out"
LOG="$(new_log)"
FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" --allow-check-removal acdp-registry-rs >/dev/null 2>&1; rc=$?
{ [ "$rc" -eq 0 ] && [ "$(put_body_of "$LOG" | jq -c .enforce_admins)" = "false" ]; } && pass "A9: --allow-check-removal lets the lowering through" || fail "A9: --allow-check-removal lets the lowering through" "rc=$rc"
rm -rf "$FX"
# A9b: re-pinning a live check to a different app is a weakening; pinning a live-null check is not.
FX="$(new_registry_fx)"
jq -c '.required |= map(if .context=="clippy" then .app_id=99 else . end)' "$GOOD_BASE" > "$FX/$BASE_REL"
out="$(FIXTURES="$FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'check "clippy" app_id 15368 -> 99'; } && pass "A9b: baseline re-pinning a live check to another app -> DRIFT" || fail "A9b: baseline re-pinning a live check -> DRIFT" "rc=$rc out=$out"
rm -rf "$FX"
FX="$(new_registry_fx)"
jq -c '.protection.required_status_checks.checks |= map(if .context=="clippy" then .app_id=null else . end)' "$FX/repos_${ORG}_acdp-registry-rs_branches_main.json" > "$FX/b.json" && mv "$FX/b.json" "$FX/repos_${ORG}_acdp-registry-rs_branches_main.json"
out="$(FIXTURES="$FX" GH_LOG="$(new_log)" "$STANDARDIZE" --check acdp-registry-rs 2>&1)"
printf '%s' "$out" | grep -q "WEAKEN" && fail "A9b: pinning a live null-app check is a strengthening, not reported" "$out" || pass "A9b: pinning a live null-app check is a strengthening, not reported"
rm -rf "$FX"
# A9c: unreadable protection endpoint -> fail closed, zero mutations.
FX="$(new_registry_fx)"; rm "$FX/$PROT_REL"
LOG="$(new_log)"
out="$(FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" acdp-registry-rs 2>&1)"; rc=$?
{ [ "$rc" -eq 1 ] && [ "$(count_mutations "$LOG")" -eq 0 ]; } && pass "A9c: protection endpoint unreadable -> apply aborts, zero mutations" || fail "A9c: protection endpoint unreadable -> apply aborts" "rc=$rc out=$out"
rm -rf "$FX"

# A5: the PUT carries the FILE's values, not hardcoded ones.
FX="$(new_registry_fx)"
jq -c '.enforce_admins=false | .strict=false | .required |= map(.app_id=99)' "$GOOD_BASE" > "$FX/$BASE_REL"
LOG="$(new_log)"
FIXTURES="$FX" GH_LOG="$LOG" GH_STUB_RECORD=1 "$STANDARDIZE" --allow-check-removal acdp-registry-rs >/dev/null 2>&1
body="$(put_body_of "$LOG")"
got="$(printf '%s' "$body" | jq -c '[.enforce_admins,.required_status_checks.strict,([.required_status_checks.checks[].app_id]|unique)]')"
[ "$got" = "[false,false,[99]]" ] && pass "A5: PUT takes enforce_admins, strict and app_id from the baseline file" || fail "A5: PUT takes enforce_admins, strict and app_id from the baseline file" "got '$got'"
rm -rf "$FX"

echo
echo "===================="
echo "  $pass_count passed, $fail_count failed"
echo "===================="

if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
exit 0
