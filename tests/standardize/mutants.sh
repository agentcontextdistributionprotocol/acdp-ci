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

# apply_mutant <name> <old> <new>
apply_mutant () {
  local name="$1" old="$2" new="$3"
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

  local n
  n=$("$SUITE" 2>&1 | grep -cE '^FAIL' || true)
  restore
  if [ "$n" -gt 0 ]; then
    printf 'KILLED   (%2d assertion(s))  %s\n' "$n" "$name"
    killed=$((killed + 1))
  else
    printf 'SURVIVED (0 assertions)   %s\n' "$name"
    survived=$((survived + 1))
  fi
}

echo "Injecting known bugs; the suite is required to FAIL on each."
echo

# 1. The wave's reason for existing: the guard that refuses to drop a live
#    required check. Disabled, the next apply silently deletes a real gate.
apply_mutant "drift detection disabled (extras always empty)" \
  "'\$live - \$want'" "'[]'"

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
  '.protection.required_status_checks.contexts // []'

# 3. Fatal collapsed into finding. drift-check.yml routes exit 1 to "file an
#    issue, job green", so a check that could not run would report as a result.
apply_mutant "wholly-failed survey downgraded from fatal (2) to finding (1)" \
  '    echo "--check: FATAL: all $SURVEYED surveyed repo(s) were unreadable' \
  '    exit 1; echo "--check: FATAL: all $SURVEYED surveyed repo(s) were unreadable'

# 4. The opposite error: escalating ANY unreadable repo to fatal. One
#    unreadable repo out of eight is a real finding and must stay reportable.
apply_mutant "partial failure over-escalated to fatal (any unreadable, not all)" \
  '[ "$UNREADABLE" -eq "$SURVEYED" ]' \
  '[ "$UNREADABLE" -gt 0 ]'

echo
echo "===================="
echo "  $killed killed, $survived survived"
echo "===================="
if [ "$survived" -ne 0 ]; then
  echo "A survived mutant means an assertion no longer bites. Fix the test." >&2
  exit 1
fi
exit 0
