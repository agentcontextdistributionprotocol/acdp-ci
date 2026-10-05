#!/usr/bin/env bash
# Mutation harness for tests/standardize/run.sh.
#
# run.sh proves the script behaves correctly. It cannot prove its own
# assertions would NOTICE if the script stopped behaving correctly. A test that
# passes with the bug injected is worth nothing, and it looks exactly like a
# test that works. This injects known bugs and requires the suite to fail.
#
# Each mutant targets a guard this repo exists to provide. If a mutant is ever
# survived (suite still green with the bug in), the corresponding assertion has
# rotted into decoration -- fix the test, not this file.
#
# THE TRAP THIS HARNESS IS BUILT AROUND: a mutation that fails to apply runs
# the suite against unmodified code, sees 0 failures, and reports "not caught"
# -- indistinguishable from a genuinely missed bug, and wrong in the more
# alarming direction. Every substitution therefore asserts it matched exactly
# once, and a mutant that does not apply is a hard error, never a result.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HERE/../../scripts/standardize.sh"
SUITE="$HERE/run.sh"

for t in python3 jq; do
  command -v "$t" >/dev/null 2>&1 || {
    echo "mutants.sh: required command '$t' not found -- cannot run (broken environment, not a result)" >&2
    exit 2
  }
done

BACKUP="$(mktemp)"
cp "$TARGET" "$BACKUP"
restore () { cp "$BACKUP" "$TARGET"; }
trap 'restore; rm -f "$BACKUP"' EXIT INT TERM

survived=0
killed=0
mismatched=0

# CONTROL. A mutant "killing" tests proves nothing if the suite was already
# red -- every count would be an artifact of a broken tree rather than of the
# injected bug. Establish green first, and refuse to report otherwise.
echo "Control: the unmutated suite must be green before any mutant means anything."
if ! "$SUITE" >/dev/null 2>&1; then
  echo "!! CONTROL FAILED: the suite is not green before mutation." >&2
  echo "   Every kill count below would be meaningless. Fix the suite first." >&2
  exit 2
fi
echo "Control: green."
echo

# apply_mutant <name> <old> <new> <expected-killers, one per line>
apply_mutant () {
  local name="$1" old="$2" new="$3" expected="$4"
  restore
  if ! MUT_OLD="$old" MUT_NEW="$new" MUT_TARGET="$TARGET" python3 -c '
import os, pathlib, sys
p = pathlib.Path(os.environ["MUT_TARGET"]); s = p.read_text()
old, new = os.environ["MUT_OLD"], os.environ["MUT_NEW"]
n = s.count(old)
if n != 1:
    sys.stderr.write(f"substitution matched {n} times, expected exactly 1\n")
    sys.exit(1)
p.write_text(s.replace(old, new))
'; then
    echo "!! MUTANT DID NOT APPLY: $name" >&2
    echo "   The anchor text has changed. This is a HARD ERROR, not a survival:" >&2
    echo "   an unapplied mutant tests nothing and would report a false pass." >&2
    exit 2
  fi

  # Exact names via the side channel, never parsed out of the FAIL line --
  # several test names contain " -- " themselves.
  local log actual want
  log="$(mktemp)"
  FAILNAME_LOG="$log" "$SUITE" >/dev/null 2>&1
  actual="$(sort -u "$log")"
  rm -f "$log"
  restore

  want="$(printf '%s\n' "$expected" | sed '/^[[:space:]]*$/d' | sort -u)"

  if [ -z "$actual" ]; then
    printf 'SURVIVED  %s\n' "$name"
    printf '  no assertion caught this bug\n'
    survived=$((survived + 1))
    return
  fi

  if [ "$actual" = "$want" ]; then
    printf 'KILLED    %s  (%s assertion(s), exactly as declared)\n' "$name" "$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
    killed=$((killed + 1))
    return
  fi

  # A count alone is not evidence. Over-killing is as wrong as under-killing:
  # it usually means the mutant broke something broader than the guard it
  # names -- a trivially-caught bug wearing the costume of a subtle one.
  printf 'MISMATCH  %s\n' "$name"
  printf '%s\n' "$want"   > "${TMPDIR:-/tmp}/mut-want.$$"
  printf '%s\n' "$actual" > "${TMPDIR:-/tmp}/mut-got.$$"
  comm -23 "${TMPDIR:-/tmp}/mut-want.$$" "${TMPDIR:-/tmp}/mut-got.$$" | sed 's/^/  declared but did NOT kill: /'
  comm -13 "${TMPDIR:-/tmp}/mut-want.$$" "${TMPDIR:-/tmp}/mut-got.$$" | sed 's/^/  killed but NOT declared:  /'
  rm -f "${TMPDIR:-/tmp}/mut-want.$$" "${TMPDIR:-/tmp}/mut-got.$$"
  mismatched=$((mismatched + 1))
}

# 1. The wave's reason for existing: the guard that refuses to drop a live
#    required check. Disabled, the next apply silently deletes a real gate.
apply_mutant "drift detection disabled (extras always empty)" \
  "'\$live - \$want'" "'[]'" \
  'case1: no mutation reaches gh (guard precedes PATCH)
case1: undeclared 5th live check blocks apply and names it
G1d: drift and missing together on the same repo -> exit 1, BOTH markers appear
override: --allow-check-removal lets a drifted apply complete
A4: apply is blocked by that DRIFT
A4: baseline behind live -> DRIFT'

# 2. The B4 fail-open. On a permission-degraded read this yields [], which
#    reads as "no extras" and lets the destructive PUT proceed. This is the
#    exact defaulting the reverify rejected; it must never come back.
# The whole conditional is replaced, not one branch of it. Disabling a
# single elif is not the B4 bug: the next branch still catches the same
# fixture (null|type is "null", not "array"), so the guard holds and the
# mutant proves nothing. Only substituting the entire expression for the
# defaulting form reproduces the actual fail-open.
BLOCK_FAILCLOSED='if (.protected|type) != "boolean" then error("no .protected -- unexpected payload")
        elif .protected == false then []
        elif (.protection.required_status_checks|type) != "object"
          then error("protected=true but no required_status_checks object -- read may be permission-degraded")
        elif (.protection.required_status_checks.contexts|type) != "array"
          then error("contexts is not an array")
        else .protection.required_status_checks.contexts end'
apply_mutant "fail-closed jq replaced by the B4 // [] defaulting" \
  "$BLOCK_FAILCLOSED" \
  '.protection.required_status_checks.contexts // []' \
  'case contexts-null: fail-closed -> exit 1
case contexts-null: no mutation is ever attempted (guard precedes PATCH)
case protected-no-rsc: fail-closed -> exit 1
case protected-no-rsc: no mutation is ever attempted (guard precedes PATCH)
check: wholly-unreadable survey is fatal (exit 2), and distinct from drift'

# 3. Fatal collapsed into finding. drift-check.yml routes exit 1 to "file an
#    issue, job green", so a check that could not run would report as a result.
apply_mutant "wholly-failed survey downgraded from fatal (2) to finding (1)" \
  '    echo "--check: FATAL: all $SURVEYED surveyed repo(s) were unreadable' \
  '    exit 1; echo "--check: FATAL: all $SURVEYED surveyed repo(s) were unreadable' \
  'check: wholly-unreadable survey is fatal (exit 2), and distinct from drift
fatal: every repo unreadable -> exit 2 and says FATAL in words
A2: --check on the registry alone with no baseline -> exit 2'

# 4. The opposite error: escalating ANY unreadable repo to fatal. One
#    unreadable repo out of eight is a real finding and must stay reportable.
apply_mutant "partial failure over-escalated to fatal (any unreadable, not all)" \
  '[ "$UNREADABLE" -eq "$SURVEYED" ]' \
  '[ "$UNREADABLE" -gt 0 ]' \
  'sweep: partial failure (1 of 8 unreadable) stays a finding, exit 1
A2: sweep with the baseline missing -> exit 1 naming the registry'


# --- #22: guards that had zero mutant coverage. Killer sets below were
#     MEASURED (run, read, then declared), not guessed.

# 5. checks_for() tri-state: an unmanaged repo must be SKIPPED (return 1), not
#    collapsed into "managed, protection-only" (return 0 + empty) -- which
#    would PUT required_status_checks:null onto a repo this script does not own.
apply_mutant "checks_for tri-state: unmanaged collapsed into protection-only" \
  '      return 0 ;;
    *) return 1 ;;' '      return 0 ;;
    *) return 0 ;;' \
  "G4: --check -- <typo'd repo> exits non-zero instead of a false all-clear
G4: --check -- <typo'd repo> makes zero gh calls at all
G4: --check <typo'd repo> exits non-zero instead of a false all-clear
G4: --check <typo'd repo> makes zero gh calls at all
unmanaged: acdp-rs skipped with the expected message
unmanaged: zero gh calls at all
G4b: --check -- <typo'd repo> against a CLEAN org still exits non-zero (no false all-clear)"

# 6. --check / --allow-check-removal mutual exclusion (exit 2).
apply_mutant "mutual exclusion removed (--check honours --allow-check-removal)" \
  'if [ "$CHECK_MODE" -eq 1 ] && [ "$ALLOW_CHECK_REMOVAL" -eq 1 ]; then' 'if false; then' \
  "flags: --check --allow-check-removal is rejected outright (exit 2)
flags: --check --allow-check-removal makes zero gh calls at all"
apply_mutant "mutual exclusion downgraded from exit 2 to exit 1" \
  '(--allow-check-removal is apply-mode only)" >&2
  exit 2' '(--allow-check-removal is apply-mode only)" >&2
  exit 1' \
  "flags: --check --allow-check-removal is rejected outright (exit 2)"

# 7. G4: an explicitly-named unmanaged repo must not exit 0 having read nothing.
apply_mutant "G4: explicitly-named unmanaged repo no longer an error" \
  'if [ "$CHECK_MODE" -eq 1 ] && [ "$EXPLICIT_REPOS" -eq 1 ]; then
      ERRORS=1
    fi
    continue' 'if [ "$CHECK_MODE" -eq 1 ] && [ "$EXPLICIT_REPOS" -eq 1 ]; then
      :
    fi
    continue' \
  "G4: --check -- <typo'd repo> exits non-zero instead of a false all-clear
G4: --check <typo'd repo> exits non-zero instead of a false all-clear
G4b: --check -- <typo'd repo> against a CLEAN org still exits non-zero (no false all-clear)"
apply_mutant "G4: EXPLICIT_REPOS tracking lost after the -- terminator" \
  '    EXPLICIT_REPOS=1
    continue' '    :
    continue' \
  "G4: --check -- <managed repo> works normally
G4: --check -- <typo'd repo> makes zero gh calls at all
G4b: --check -- <typo'd repo> against a CLEAN org still exits non-zero (no false all-clear)"

# 8. enforce_admins differs between the protection-only and has-checks bodies.
apply_mutant "protection-only body: enforce_admins true -> false" \
  '"required_status_checks":null,"enforce_admins":true' '"required_status_checks":null,"enforce_admins":false' \
  "EA1: protection-only PUT (acdp-ci) sets enforce_admins:true and required_status_checks:null"
apply_mutant "has-checks default: enforce_admins false -> true" \
  '        enforce_admins: false,' '        enforce_admins: true,' \
  "EA2: has-checks PUT (acdp-playground) sets enforce_admins:false with contexts and no checks pinning"
apply_mutant "registry enforce_admins ignores the baseline (hardcoded false)" \
  '        enforce_admins: .enforce_admins,' '        enforce_admins: false,' \
  "case2: registry PUT sets enforce_admins:true (issue #29)
A1: in-sync registry apply PUTs exactly the baseline file checks"

# 9. Ordering: the repo-settings PATCH must precede the protection PUT.
apply_mutant "protection PUT attempted before the settings PATCH" \
  '  gh api -X PATCH "repos/$ORG/$repo" \' '  printf '"'"'%s'"'"' "$protection_json" | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - >/dev/null
  gh api -X PATCH "repos/$ORG/$repo" \' \
  "bash-3.2 (/bin/bash): standardize.sh runs and blocks identically
block-mode guard: PATCH was the blocked call
block-mode guard: PUT never attempted"

# 10. Registry app_id pinning.
apply_mutant "registry app_id pinning dropped (checks -> contexts)" \
  'required_status_checks: { strict: .strict, checks: .required },' 'required_status_checks: { strict: .strict, contexts: [.required[].context] },' \
  "case2: PUT body carries all 11 declared checks
case2: registry PUT pins every check to app_id 15368 via checks
override: PUT body reaches the mutation path with the reduced (declared-only) contexts
A1: in-sync registry apply PUTs exactly the baseline file checks
A5: PUT takes enforce_admins, strict and app_id from the baseline file"


# --- #19: the UNREGISTERED org-registry condition. Killer sets measured.
apply_mutant "UNREGISTERED: repo found but flag never accumulated" \
  '        UNREGISTERED=1
      done' '        :
      done' \
  "B2: summary names the unregistered condition
B2: unregistered repo -> exit 1, named, no DRIFT"
apply_mutant "UNREGISTERED: exclusion subtraction removed (excluded repos reported)" \
  'case " $ALL_REPOS $EXCLUDED_REPOS " in *" $name "*) continue ;; esac' 'case " $ALL_REPOS " in *" $name "*) continue ;; esac' \
  "B1: every org repo accounted for -> exit 0, no UNREGISTERED
B5: archived extra repo is ignored, and reported as ignored
G1c: clean full sweep still exits 0, no PENDING marker
G4 regression guard: default no-arg full sweep --check still exits 0"
apply_mutant "UNREGISTERED: unreadable org listing no longer an error (fail-open)" \
  '      ERRORS=1
    else
      org_names=' '      :
    else
      org_names=' \
  "B3: unreadable org listing -> exit 1 and says the check did not run
B4a: empty listing -> exit 1, not a clean pass"
apply_mutant "UNREGISTERED: escalated to fatal exit 2" \
  '        UNREGISTERED=1
      done' '        UNREGISTERED=1; exit 2
      done' \
  "B2: summary names the unregistered condition
B2: unregistered repo -> exit 1, named, no DRIFT"
apply_mutant "UNREGISTERED: org enumerated even when repos are named" \
  '  if [ "$EXPLICIT_REPOS" -eq 0 ]; then
    if ! listing=' '  if true; then
    if ! listing=' \
  "B6: --check <repo> makes no org enumeration call
check: prints the live contexts it read, per repo, even when in sync
flags: trailing --check is parsed as a flag, not a repo name
G4: --check -- <managed repo> works normally
G4: --check -- <typo'd repo> makes zero gh calls at all
G4: --check <typo'd repo> makes zero gh calls at all"
apply_mutant "UNREGISTERED: accounted-for-repo sanity check removed" \
  'if ! printf '"'"'%s\n'"'"' "$org_names" | grep -qxF -- "$acct"; then' 'if false; then' \
  "B4b: listing missing a managed repo -> exit 1, names it
B9: stale exclusion -> exit 1, names it"


# --- #33 (#29 item 3): the registry baseline. Killer sets measured.
apply_mutant "baseline: empty required accepted (would wipe every check)" \
  'if (.required | type) != "array" or (.required | length) == 0 then bad("required must be a non-empty array") else . end' '.' \
  "A3: empty required (would wipe all checks) -> refused, exit 1, zero mutations"
apply_mutant "baseline: status 3 (remote baseline) treated as protection-only (0)" \
  '    acdp-registry-rs)  # remote baseline: its committed .github/required-checks.json
      return 3 ;;' '    acdp-registry-rs)  # remote baseline: its committed .github/required-checks.json
      return 0 ;;' \
  "#30: full apply sweep ran
A1: in-sync registry apply PUTs exactly the baseline file checks
A1: says it read the baseline
A2: --check on the registry alone with no baseline -> exit 2
A2: missing baseline -> apply exits 1
A2: sweep with the baseline missing -> exit 1 naming the registry
A3: a JSON array, not an object -> refused, exit 1, zero mutations
A3: advisory_pending not an array of strings -> refused, exit 1, zero mutations
A3: context both required and advisory_pending -> refused, exit 1, zero mutations
A3: duplicate contexts -> refused, exit 1, zero mutations
A3: empty required (would wipe all checks) -> refused, exit 1, zero mutations
A3: empty-string context -> refused, exit 1, zero mutations
A3: fractional app_id -> refused, exit 1, zero mutations
A3: invalid JSON -> refused, exit 1, zero mutations
A3: missing strict -> refused, exit 1, zero mutations
A3: non-boolean enforce_admins -> refused, exit 1, zero mutations
A3: non-boolean pending_settings -> refused, exit 1, zero mutations
A3: non-string context -> refused, exit 1, zero mutations
A3: null app_id -> refused, exit 1, zero mutations
A3: required missing -> refused, exit 1, zero mutations
A3: string app_id -> refused, exit 1, zero mutations
A4: baseline ahead of live -> PENDING
A5: PUT takes enforce_admins, strict and app_id from the baseline file
A6: the contents call asks for the raw media type
B1: every org repo accounted for -> exit 0, no UNREGISTERED
B2: unregistered repo -> exit 1, named, no DRIFT
B5: archived extra repo is ignored, and reported as ignored
case2: PUT body carries all 11 declared checks
case2: registry PUT pins every check to app_id 15368 via checks
case2: registry PUT sets enforce_admins:true (issue #29)
case2: registry-rs-insync (post-fix) -> exit 0, reports in sync
check: prints the live contexts it read, per repo, even when in sync
G1c: clean full sweep still exits 0, no PENDING marker
G1d: drift and missing together on the same repo -> exit 1, BOTH markers appear
G4 regression guard: default no-arg full sweep --check still exits 0
override: PUT body reaches the mutation path with the reduced (declared-only) contexts"
apply_mutant "baseline: app_id null accepted" \
  'if (.required | map(.app_id | type == "number" and . == floor) | all | not) then bad("every required app_id must be an integer (null is rejected)") else . end' '.' \
  "A3: fractional app_id -> refused, exit 1, zero mutations
A3: null app_id -> refused, exit 1, zero mutations
A3: string app_id -> refused, exit 1, zero mutations"
apply_mutant "baseline: unreadable baseline not an error in --check" \
  '      if [ "$CHECK_MODE" -eq 1 ]; then
        ERRORS=1
        UNREADABLE=$((UNREADABLE + 1))
        continue
      else
        echo "!! $repo: aborting before any mutation" >&2' '      if [ "$CHECK_MODE" -eq 1 ]; then
        :
        UNREADABLE=$((UNREADABLE + 1))
        continue
      else
        echo "!! $repo: aborting before any mutation" >&2' \
  "A2: sweep with the baseline missing -> exit 1 naming the registry"
apply_mutant "baseline: apply carries on silently when the baseline is unreadable" \
  '        echo "!! $repo: aborting before any mutation" >&2
        exit 1' '        echo "!! $repo: aborting before any mutation" >&2
        continue' \
  "A2: missing baseline -> apply exits 1
A3: a JSON array, not an object -> refused, exit 1, zero mutations
A3: advisory_pending not an array of strings -> refused, exit 1, zero mutations
A3: context both required and advisory_pending -> refused, exit 1, zero mutations
A3: duplicate contexts -> refused, exit 1, zero mutations
A3: empty required (would wipe all checks) -> refused, exit 1, zero mutations
A3: empty-string context -> refused, exit 1, zero mutations
A3: fractional app_id -> refused, exit 1, zero mutations
A3: invalid JSON -> refused, exit 1, zero mutations
A3: missing strict -> refused, exit 1, zero mutations
A3: non-boolean enforce_admins -> refused, exit 1, zero mutations
A3: non-boolean pending_settings -> refused, exit 1, zero mutations
A3: non-string context -> refused, exit 1, zero mutations
A3: null app_id -> refused, exit 1, zero mutations
A3: required missing -> refused, exit 1, zero mutations
A3: string app_id -> refused, exit 1, zero mutations"
apply_mutant "baseline: strict hardcoded true" \
  'required_status_checks: { strict: .strict, checks: .required },' 'required_status_checks: { strict: true, checks: .required },' \
  "A5: PUT takes enforce_admins, strict and app_id from the baseline file"
apply_mutant "baseline: raw media type not requested" \
  "-H 'Accept: application/vnd.github.raw' 2>/dev/null" "2>/dev/null" \
  "#30: full apply sweep ran
A1: in-sync registry apply PUTs exactly the baseline file checks
A1: says it read the baseline
A4: baseline ahead of live -> PENDING
A4: baseline behind live -> DRIFT
A5: PUT takes enforce_admins, strict and app_id from the baseline file
A6: the contents call asks for the raw media type
B1: every org repo accounted for -> exit 0, no UNREGISTERED
B5: archived extra repo is ignored, and reported as ignored
case1: undeclared 5th live check blocks apply and names it
case2: PUT body carries all 11 declared checks
case2: registry PUT pins every check to app_id 15368 via checks
case2: registry PUT sets enforce_admins:true (issue #29)
case2: registry-rs-insync (post-fix) -> exit 0, reports in sync
check: prints the live contexts it read, per repo, even when in sync
G1c: clean full sweep still exits 0, no PENDING marker
G1d: drift and missing together on the same repo -> exit 1, BOTH markers appear
G4 regression guard: default no-arg full sweep --check still exits 0
override: --allow-check-removal lets a drifted apply complete
override: PUT body reaches the mutation path with the reduced (declared-only) contexts"

echo
echo "===================="
echo "  $killed killed, $survived survived, $mismatched mismatched"
echo "===================="
if [ "$survived" -ne 0 ]; then
  echo "A survived mutant means an assertion no longer bites. Fix the test." >&2
fi
if [ "$mismatched" -ne 0 ]; then
  echo "A mismatched mutant means the declared killer set is wrong, or the" >&2
  echo "mutant breaks more than the guard it names. Both are defects: an" >&2
  echo "over-killing mutant inflates confidence without testing what it claims." >&2
fi
if [ "$survived" -ne 0 ] || [ "$mismatched" -ne 0 ]; then
  exit 1
fi
exit 0
