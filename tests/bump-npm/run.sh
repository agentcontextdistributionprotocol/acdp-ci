#!/usr/bin/env bash
# Offline harness for actions/npm-relock/relock.sh (acdp-ci#28). A shadow
# `npm` (tests/bump-npm/bin/npm) models the publish race; no network.
# Set BUMP_NPM_LIVE=1 to also run the real-registry case.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELOCK="$HERE/../../actions/npm-relock/relock.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1 -- $2"; }

# Real npm on PATH ahead of the stub would make every case vacuous.
PATH="$HERE/bin:$PATH"
[ "$(command -v npm)" = "$HERE/bin/npm" ] || { echo "PATH guard: npm is not the shadow"; exit 2; }

OPT4='{"plat-darwin-arm64":"0.14.4","plat-darwin-x64":"0.14.4","plat-linux-x64-gnu":"0.14.4"}'

# newcase <optionals-json|""> <published-lines...> -> sets W (workdir) and FAKE
newcase() {
  opts="$1"; shift
  W="$(mktemp -d)"; FAKE="$W/.fake"; mkdir -p "$FAKE"
  : > "$FAKE/published"; : > "$FAKE/calls.log"
  if [ -n "$opts" ]; then echo "$opts" > "$FAKE/optionals.json"; else echo '{}' > "$FAKE/optionals.json"; fi
  for p in "$@"; do echo "$p" >> "$FAKE/published"; done
  echo '{"packages":{"":{"name":"consumer"}}}' > "$W/package-lock.json"
  echo '{"name":"consumer"}' > "$W/package.json"
  export FAKE
}
run_relock() { ( cd "$W" && PKG=@scope/acdp T=0.14.4 RELOCK_ATTEMPTS="${ATT:-3}" RELOCK_SLEEP=0 "$RELOCK" 2>&1 ); }
lockhash() { shasum "$W/package-lock.json" | cut -d' ' -f1; }
ALLPUB=(plat-darwin-arm64@0.14.4 plat-darwin-x64@0.14.4 plat-linux-x64-gnu@0.14.4)

echo "== all optionals published -> exit 0, all in lock =="
newcase "$OPT4" "${ALLPUB[@]}"
out="$(run_relock)"; rc=$?
[ $rc -eq 0 ] && pass "all published: exit 0" || fail "all published: exit 0" "rc=$rc $out"
n="$(jq '[.packages|keys[]|select(startswith("node_modules/plat-"))]|length' "$W/package-lock.json")"
[ "$n" = 3 ] && pass "all published: lock has all 3 platform packages" || fail "all published: lock has all 3" "n=$n"

echo "== one optional never published -> exit 1, lock restored byte-identical, names the package =="
newcase "$OPT4" plat-darwin-x64@0.14.4 plat-linux-x64-gnu@0.14.4
before="$(lockhash)"
out="$(run_relock)"; rc=$?
[ $rc -eq 1 ] && pass "unpublished: exit 1" || fail "unpublished: exit 1" "rc=$rc $out"
printf '%s' "$out" | grep -q "plat-darwin-arm64" && pass "unpublished: names the missing package" || fail "unpublished: names the missing package" "$out"
[ "$before" = "$(lockhash)" ] && pass "unpublished: lock byte-identical" || fail "unpublished: lock byte-identical" "changed"
grep -q "install" "$FAKE/calls.log" && fail "unpublished: never relocks while a platform pkg is missing" "install ran" || pass "unpublished: never relocks while a platform pkg is missing"

echo "== optional published late -> retry succeeds =="
newcase "$OPT4" plat-darwin-x64@0.14.4 plat-linux-x64-gnu@0.14.4
export FAKE_PUBLISH_AFTER_VIEWS=2
out="$(ATT=4 run_relock)"; rc=$?
unset FAKE_PUBLISH_AFTER_VIEWS
[ $rc -eq 0 ] && pass "late publish: retry then exit 0" || fail "late publish: retry then exit 0" "rc=$rc $out"

echo "== registry served it but install drops it (stale metadata) -> fails closed via the lock check =="
newcase "$OPT4" "${ALLPUB[@]}"
before="$(lockhash)"
export FAKE_INSTALL_DROP=plat-darwin-arm64
out="$(run_relock)"; rc=$?
unset FAKE_INSTALL_DROP
[ $rc -eq 1 ] && pass "dropped by install: exit 1" || fail "dropped by install: exit 1" "rc=$rc $out"
printf '%s' "$out" | grep -q "missing optional dependencies: plat-darwin-arm64" && pass "dropped by install: names it" || fail "dropped by install: names it" "$out"
[ "$before" = "$(lockhash)" ] && pass "dropped by install: lock restored" || fail "dropped by install: lock restored" "changed"

echo "== lock complete but npm ci --dry-run rejects it -> still fails closed, lock restored =="
newcase "$OPT4" "${ALLPUB[@]}"
before="$(lockhash)"
export FAKE_CI_FAIL=1
out="$(run_relock)"; rc=$?
unset FAKE_CI_FAIL
[ $rc -eq 1 ] && pass "ci --dry-run is an independent gate: exit 1" || fail "ci --dry-run is an independent gate: exit 1" "rc=$rc $out"
[ "$before" = "$(lockhash)" ] && pass "ci --dry-run failure: lock restored" || fail "ci --dry-run failure: lock restored" "changed"

echo "== npm: alias optionals are viewed by their real name; nested lock keys count =="
newcase '{"plat-alias":"npm:plat-real@0.14.4"}' plat-real@0.14.4
out="$(run_relock)"; rc=$?
# the fake install records published lines by name@spec; an alias is not modelled there, so only the wait step is asserted
grep -q "npm view plat-real@0.14.4 version" "$FAKE/calls.log" && pass "alias: wait step views the real package name" || fail "alias: wait step views the real package name" "$(cat "$FAKE/calls.log")"
newcase "$OPT4" "${ALLPUB[@]}"
echo '{"packages":{"":{},"node_modules/@scope/acdp/node_modules/plat-darwin-arm64":{"version":"0.14.4"},"node_modules/plat-darwin-x64":{"version":"0.14.4"},"node_modules/plat-linux-x64-gnu":{"version":"0.14.4"}}}' > "$W/nested.json"
export FAKE_INSTALL_LOCK="$W/nested.json"
out="$(run_relock)"; rc=$?
unset FAKE_INSTALL_LOCK
[ $rc -eq 0 ] && pass "nested lock key satisfies the presence check" || fail "nested lock key satisfies the presence check" "rc=$rc $out"
newcase "$OPT4" "${ALLPUB[@]}"
echo '{"packages":{"":{},"node_modules/xplat-darwin-arm64":{"version":"0.14.4"},"node_modules/plat-darwin-x64":{"version":"0.14.4"},"node_modules/plat-linux-x64-gnu":{"version":"0.14.4"}}}' > "$W/decoy.json"
export FAKE_INSTALL_LOCK="$W/decoy.json" FAKE_CI_LENIENT=1
out="$(run_relock)"; rc=$?
unset FAKE_INSTALL_LOCK FAKE_CI_LENIENT
[ $rc -eq 1 ] && pass "a look-alike key (xplat-…) does not satisfy the presence check" || fail "a look-alike key (xplat-…) does not satisfy the presence check" "rc=$rc $out"

echo "== a newer in-range release resolved by install is not a false failure =="
newcase "$OPT4" "${ALLPUB[@]}"
export FAKE_INSTALL_NEWER=1
out="$(run_relock)"; rc=$?
unset FAKE_INSTALL_NEWER
[ $rc -eq 0 ] && pass "install resolves 0.14.5 against spec 0.14.4: still exit 0" || fail "install resolves 0.14.5 against spec 0.14.4: still exit 0" "rc=$rc $out"

echo "== unexpected crash after relock still restores the lock =="
newcase "$OPT4" "${ALLPUB[@]}"
before="$(lockhash)"
# corrupt lock written by a (stub) install makes the node check crash under set -e
export FAKE_INSTALL_CORRUPT=1
out="$(run_relock)"; rc=$?
unset FAKE_INSTALL_CORRUPT
{ [ $rc -ne 0 ] && [ "$before" = "$(lockhash)" ]; } && pass "crash path: non-zero and lock restored" || fail "crash path: non-zero and lock restored" "rc=$rc"

echo "== pure-JS package (no optionals) -> exit 0, no per-package waits =="
newcase ""
out="$(run_relock)"; rc=$?
[ $rc -eq 0 ] && pass "no optionals: exit 0" || fail "no optionals: exit 0" "rc=$rc $out"

echo "== malformed / failing registry metadata fails closed =="
newcase "$OPT4" "${ALLPUB[@]}"
export FAKE_VIEW_RAW='not json'
out="$(run_relock)"; rc=$?; unset FAKE_VIEW_RAW
[ $rc -eq 1 ] && pass "malformed optionalDependencies JSON: exit 1" || fail "malformed optionalDependencies JSON: exit 1" "rc=$rc $out"
newcase "$OPT4" "${ALLPUB[@]}"
export FAKE_VIEW_RAW='["a"]'
out="$(run_relock)"; rc=$?; unset FAKE_VIEW_RAW
[ $rc -eq 1 ] && pass "array optionalDependencies: exit 1" || fail "array optionalDependencies: exit 1" "rc=$rc $out"
newcase "$OPT4" "${ALLPUB[@]}"
export FAKE_VIEW_FAIL=1
out="$(run_relock)"; rc=$?; unset FAKE_VIEW_FAIL
[ $rc -eq 1 ] && pass "npm view failure is not 'no optionals': exit 1" || fail "npm view failure is not 'no optionals': exit 1" "rc=$rc $out"

echo "== missing lockfile / env =="
newcase "$OPT4" "${ALLPUB[@]}"; rm "$W/package-lock.json"
out="$(run_relock)"; rc=$?
[ $rc -eq 1 ] && pass "no package-lock.json: exit 1" || fail "no package-lock.json: exit 1" "rc=$rc"
out="$(cd "$W" && env -u PKG "$RELOCK" 2>&1)"; rc=$?
[ $rc -ne 0 ] && pass "PKG unset: non-zero" || fail "PKG unset: non-zero" "rc=$rc"

echo "== workflow wiring: relock+verify precedes branch/PR creation; no always() after it =="
WF="$HERE/../../.github/workflows/bump-consume.yml"
relock_line="$(grep -n 'npm-relock@' "$WF" | head -1 | cut -d: -f1)"
pr_line="$(grep -n 'git checkout -b "\$BR"' "$WF" | head -1 | cut -d: -f1)"
{ [ -n "$relock_line" ] && [ -n "$pr_line" ] && [ "$relock_line" -lt "$pr_line" ]; } && pass "wiring: npm-relock step is before branch creation" || fail "wiring: npm-relock step is before branch creation" "relock=$relock_line pr=$pr_line"
grep -q 'always()' "$WF" && fail "wiring: no always() in bump-consume.yml" "found" || pass "wiring: no always() in bump-consume.yml"
grep -q 'npm install --package-lock-only' "$WF" && fail "wiring: no unverified relock left in the workflow" "found" || pass "wiring: no unverified relock left in the workflow"

if [ "${BUMP_NPM_LIVE:-0}" = 1 ]; then
  echo "== live: real registry, real npm =="
  PATH="${PATH#"$HERE/bin:"}"
  W="$(mktemp -d)"; ( cd "$W" && echo '{"name":"c","version":"1.0.0","dependencies":{"@agentcontextdistributionprotocol/acdp":"^0.14.4"}}' > package.json \
    && npm install --package-lock-only --ignore-scripts >/dev/null 2>&1 \
    && PKG=@agentcontextdistributionprotocol/acdp T=0.14.4 RELOCK_SLEEP=2 "$RELOCK" >/dev/null 2>&1 ); rc=$?
  [ $rc -eq 0 ] && pass "live: real acdp@0.14.4 verifies" || fail "live: real acdp@0.14.4 verifies" "rc=$rc"
  n="$(jq '[.packages|keys[]|select(test("acdp-(darwin|linux|win)"))]|length' "$W/package-lock.json")"
  [ "$n" -ge 4 ] && pass "live: lock has the platform packages ($n)" || fail "live: lock has the platform packages" "n=$n"
fi

echo; echo "===================="; echo "  $PASS passed, $FAIL failed"; echo "===================="
[ "$FAIL" -eq 0 ]
