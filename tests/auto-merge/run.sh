#!/usr/bin/env bash
# Offline table-driven tests for actions/auto-merge-gate (acdp-ci#30).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DECIDE="$HERE/../../actions/auto-merge-gate/decide.sh"
DISARM="$HERE/../../actions/auto-merge-gate/disarm.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1 -- $2"; }
PATH="$HERE/bin:$PATH"
[ "$(command -v gh)" = "$HERE/bin/gh" ] || { echo "PATH guard: gh is not the shadow"; exit 2; }

PATCH=version-update:semver-patch; MINOR=version-update:semver-minor; MAJOR=version-update:semver-major
DEPS_RING='[{"dependencyName":"ring","dependencyGroup":"crypto"},{"dependencyName":"serde"}]'
DEPS_SERDE='[{"dependencyName":"serde"},{"dependencyName":"tokio"}]'

# decide <label> <expect-eligible> <expect-held-by-deny> [VAR=val ...]
decide() {
  label="$1"; want="$2"; wantdeny="$3"; shift 3
  out="$(env -i PATH="$PATH" "$@" "$DECIDE" 2>&1)"; rc=$?
  got="$(printf '%s' "$out" | sed -n 's/^eligible=//p')"; deny="$(printf '%s' "$out" | sed -n 's/^held_by_deny=//p')"
  if [ "$rc" -eq 0 ] && [ "$got" = "$want" ] && [ "$deny" = "$wantdeny" ]; then pass "$label"; else fail "$label" "rc=$rc eligible=$got held_by_deny=$deny out=$out"; fi
}

echo "== default policy (no deny lists) is the historical rule =="
decide "patch -> arm"                         true  false UPDATE_TYPE=$PATCH
decide "minor -> arm"                         true  false UPDATE_TYPE=$MINOR
decide "major -> held (not a deny hold)"      false false UPDATE_TYPE=$MAJOR
decide "major + allow-major -> arm"           true  false UPDATE_TYPE=$MAJOR ALLOW_MAJOR=true
decide "empty update-type -> held"            false false UPDATE_TYPE=
decide "unknown update-type -> held"          false false UPDATE_TYPE=version-update:semver-wat
decide "deny lists empty even with deps -> arm" true false UPDATE_TYPE=$PATCH "DEPS_JSON=$DEPS_RING"

echo "== exclude-dependencies =="
decide "exact name match -> held by deny"     false true  UPDATE_TYPE=$PATCH "DEPS_JSON=$DEPS_RING" EXCLUDE_DEPENDENCIES=ring
decide "glob match -> held by deny"           false true  UPDATE_TYPE=$MINOR "DEPS_JSON=$DEPS_RING" "EXCLUDE_DEPENDENCIES=ri*"
decide "no match -> arm"                      true  false UPDATE_TYPE=$PATCH "DEPS_JSON=$DEPS_SERDE" EXCLUDE_DEPENDENCIES=ring
decide "second dependency matches -> held"    false true  UPDATE_TYPE=$PATCH "DEPS_JSON=$DEPS_SERDE" "EXCLUDE_DEPENDENCIES=ring,tokio"
decide "newline separated + comments + CRLF"  false true  UPDATE_TYPE=$PATCH "DEPS_JSON=$DEPS_SERDE" "EXCLUDE_DEPENDENCIES=$(printf '# crypto\r\nring\r\ntokio  # async\r\n')"
decide "scoped npm name glob"                 false true  UPDATE_TYPE=$PATCH 'DEPS_JSON=[{"dependencyName":"@noble/curves"}]' "EXCLUDE_DEPENDENCIES=@noble/*"
decide "pattern is not a prefix match"        true  false UPDATE_TYPE=$PATCH "DEPS_JSON=$DEPS_SERDE" EXCLUDE_DEPENDENCIES=ser
decide "deny set but metadata empty -> hold (fail-safe)" false true UPDATE_TYPE=$PATCH DEPS_JSON= EXCLUDE_DEPENDENCIES=ring
decide "deny set but metadata unparseable -> hold"       false true UPDATE_TYPE=$PATCH "DEPS_JSON=not json" EXCLUDE_DEPENDENCIES=ring
decide "deny set, JSON empty array -> hold"              false true UPDATE_TYPE=$PATCH "DEPS_JSON=[]" EXCLUDE_DEPENDENCIES=ring
decide "falls back to dependency-names when JSON absent" false true UPDATE_TYPE=$PATCH DEPS_JSON= "DEP_NAMES=serde, ring" EXCLUDE_DEPENDENCIES=ring
decide "deny list + major still held, but NOT a deny hold" false false UPDATE_TYPE=$MAJOR "DEPS_JSON=$DEPS_RING" EXCLUDE_DEPENDENCIES=ring
decide "a name containing glob chars is matched literally on the left" true false UPDATE_TYPE=$PATCH 'DEPS_JSON=[{"dependencyName":"a*b"}]' EXCLUDE_DEPENDENCIES=zzz

echo "== exclude-groups =="
decide "group match -> held by deny"          false true  UPDATE_TYPE=$PATCH GROUP=crypto EXCLUDE_GROUPS=crypto
decide "group glob"                           false true  UPDATE_TYPE=$MINOR GROUP=crypto-core "EXCLUDE_GROUPS=crypto*"
decide "different group -> arm"               true  false UPDATE_TYPE=$PATCH GROUP=dev-deps EXCLUDE_GROUPS=crypto
decide "ungrouped PR with exclude-groups set -> arm" true false UPDATE_TYPE=$PATCH GROUP= EXCLUDE_GROUPS=crypto

echo "== disarm.sh =="
LOG="$(mktemp)"
out="$(FAKE_ARMED=1 GH_LOG="$LOG" PR_URL=https://x/pr/1 "$DISARM" 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && grep -q "pr merge --disable-auto https://x/pr/1" "$LOG"; } && pass "disarm: armed PR -> gh pr merge --disable-auto called" || fail "disarm: armed PR -> disable called" "rc=$rc $(cat "$LOG")"
LOG="$(mktemp)"
out="$(FAKE_ARMED=0 GH_LOG="$LOG" PR_URL=https://x/pr/1 "$DISARM" 2>&1)"; rc=$?
{ [ $rc -eq 0 ] && ! grep -q "disable-auto" "$LOG"; } && pass "disarm: unarmed PR -> nothing disabled" || fail "disarm: unarmed PR -> nothing disabled" "rc=$rc $(cat "$LOG")"
out="$(env -u PR_URL GH_LOG="$(mktemp)" "$DISARM" 2>&1)"; rc=$?
[ $rc -ne 0 ] && pass "disarm: PR_URL unset -> non-zero" || fail "disarm: PR_URL unset -> non-zero" "rc=$rc"

echo "== workflow wiring =="
WF="$HERE/../../.github/workflows/auto-merge.yml"
n="$(grep -c "steps.gate.outputs.eligible == 'true'" "$WF")"
[ "$n" = 2 ] && pass "wiring: both the guard and the enable step are gated on the gate output" || fail "wiring: both guard and enable gated on the gate output" "n=$n"
grep -q "update-type == 'version-update:semver" "$WF" && fail "wiring: the old inline type condition is gone from the steps" "still present" || pass "wiring: the old inline type condition is gone from the steps"

echo; echo "===================="; echo "  $PASS passed, $FAIL failed"; echo "===================="
[ "$FAIL" -eq 0 ]
