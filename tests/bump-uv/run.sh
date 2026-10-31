#!/usr/bin/env bash
# Offline harness for actions/uv-relock/relock.sh. A shadow `uv`
# (tests/bump-uv/bin/uv) models an index that serves the target late; no
# network. Set BUMP_UV_LIVE=1 to also run two cases against real uv + PyPI.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RELOCK="$HERE/../../actions/uv-relock/relock.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1 -- $2"; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "$(eval "${3:-true}")"; fi; }

# Real uv on PATH ahead of the stub would make every case vacuous.
REAL_PATH="$PATH"
PATH="$HERE/bin:$PATH"
[ "$(command -v uv)" = "$HERE/bin/uv" ] || { echo "PATH guard: uv is not the shadow"; exit 2; }

newcase() {
  W="$(mktemp -d)"; FAKE="$W/.fake"; mkdir -p "$FAKE"; : > "$FAKE/calls.log"; export FAKE
  cat > "$W/uv.lock" <<'L'
version = 1
requires-python = ">=3.10"

[[package]]
name = "acdp"
version = "0.18.2"
source = { registry = "https://pypi.org/simple" }

[[package]]
name = "acdp-playground"
version = "0.1.0"
source = { editable = "." }
L
}
run_relock() { ( cd "$W" && PKG=acdp T=0.19.0 RELOCK_ATTEMPTS="${ATT:-4}" RELOCK_SLEEP=0 "$RELOCK" 2>&1 ); }
locked() { awk '$0=="name = \"acdp\""{f=1;next} f&&/^version/{print $3;exit}' "$W/uv.lock" | tr -d '"'; }
lockhash() { shasum "$W/uv.lock" | cut -d' ' -f1; }

echo "== index serves the target -> exit 0, lock pins exactly T =="
newcase
out="$(run_relock)"; rc=$?
check "exit 0" '[ $rc -eq 0 ]' 'echo "rc=$rc $out"'
check "uv.lock pins acdp 0.19.0" '[ "$(locked)" = 0.19.0 ]' 'locked'
check "pins the version and bypasses the cache" 'grep -q -- "--upgrade-package acdp==0.19.0 --refresh-package acdp" "$FAKE/calls.log"' 'cat "$FAKE/calls.log"'

echo "== index lags (the acdp-playground #110/#111 race) -> retries, then exact T =="
newcase
out="$(FAKE_SERVED_AFTER=2 run_relock)"; rc=$?
check "exit 0 after retries" '[ $rc -eq 0 ]' 'echo "rc=$rc $out"'
check "three lock attempts" '[ "$(grep -c "^uv lock" "$FAKE/calls.log")" = 3 ]' 'cat "$FAKE/calls.log"'
check "uv.lock pins acdp 0.19.0, not the previous release" '[ "$(locked)" = 0.19.0 ]' 'locked'

echo "== index never serves it -> exit 1, lock byte-identical, says why =="
newcase; before="$(lockhash)"
out="$(FAKE_SERVED_AFTER=99 run_relock)"; rc=$?
check "exit 1" '[ $rc -eq 1 ]' 'echo "rc=$rc"'
check "lock restored byte-identical" '[ "$before" = "$(lockhash)" ]' 'locked'
check "error names the target" 'printf "%s" "$out" | grep -q "acdp==0.19.0 failed after 4 attempts"' 'echo "$out"'
check "stopped at the attempt cap" '[ "$(grep -c "^uv lock" "$FAKE/calls.log")" = 4 ]' 'cat "$FAKE/calls.log"'

echo "== uv succeeds but locks another version -> exit 1, lock restored =="
newcase; before="$(lockhash)"
out="$(FAKE_LOCK_VERSION=0.18.3 run_relock)"; rc=$?
check "exit 1" '[ $rc -eq 1 ]' 'echo "rc=$rc $out"'
check "says what it pinned" 'printf "%s" "$out" | grep -q "pins acdp at .0.18.3., not 0.19.0"' 'echo "$out"'
check "lock restored byte-identical" '[ "$before" = "$(lockhash)" ]' 'locked'

echo "== uv succeeds but drops the package -> exit 1 =="
newcase
out="$(FAKE_LOCK_DROP=1 run_relock)"; rc=$?
check "exit 1, <absent>" '[ $rc -eq 1 ] && printf "%s" "$out" | grep -q "<absent>"' 'echo "rc=$rc $out"'

echo "== backoff is capped =="
newcase
out="$( cd "$W" && FAKE_SERVED_AFTER=99 PKG=acdp T=0.19.0 RELOCK_ATTEMPTS=3 RELOCK_SLEEP=1 RELOCK_SLEEP_MAX=1 bash -c 'time "$0"' "$RELOCK" 2>&1 )"; rc=$?
secs="$(printf '%s' "$out" | awk '/^real/{split($2,a,"m"); sub("s","",a[2]); print int(a[1]*60+a[2])}')"
check "3 attempts, 2 sleeps capped at 1s -> about 2s" '[ $rc -eq 1 ] && [ "${secs:-99}" -ge 2 ] && [ "${secs:-99}" -le 4 ]' 'echo "rc=$rc secs=$secs"'

echo "== missing inputs =="
newcase; rm "$W/uv.lock"
out="$(run_relock)"; rc=$?
check "no uv.lock: exit 1" '[ $rc -eq 1 ]' 'echo "rc=$rc"'
newcase
out="$(cd "$W" && env -u PKG T=0.19.0 "$RELOCK" 2>&1)"; rc=$?
check "PKG unset: non-zero" '[ $rc -ne 0 ]' 'echo "rc=$rc"'

echo "== workflow wiring =="
WF="$HERE/../../.github/workflows/bump-consume.yml"
check "uv path uses actions/uv-relock@v1" 'grep -q "acdp-ci/actions/uv-relock@v1" "$WF"' 'true'
check "no unpinned uv lock --upgrade-package left in the workflow" '! grep -q "uv lock --upgrade-package \"\$PKG\"" "$WF"' 'true'
relock_line="$(grep -n 'uv-relock@' "$WF" | head -1 | cut -d: -f1)"
pr_line="$(grep -n 'git checkout -b "\$BR"' "$WF" | head -1 | cut -d: -f1)"
check "uv-relock step is before branch creation" '[ -n "$relock_line" ] && [ -n "$pr_line" ] && [ "$relock_line" -lt "$pr_line" ]' 'echo "relock=$relock_line pr=$pr_line"'

if [ "${BUMP_UV_LIVE:-0}" = 1 ]; then
  echo "== live: real uv, real PyPI =="
  PATH="$REAL_PATH"
  W="$(mktemp -d)"; printf '[project]\nname="p"\nversion="0"\nrequires-python=">=3.10"\ndependencies=["acdp>=0.15.0"]\n' > "$W/pyproject.toml"
  ( cd "$W" && uv lock -q --upgrade-package acdp==0.18.2 ) >/dev/null 2>&1
  out="$( cd "$W" && PKG=acdp T=0.18.3 RELOCK_ATTEMPTS=2 RELOCK_SLEEP=1 "$RELOCK" 2>&1 )"; rc=$?
  check "live: 0.18.2 -> exactly 0.18.3 (not latest)" '[ $rc -eq 0 ] && [ "$(locked)" = 0.18.3 ]' 'echo "rc=$rc $(locked) $out"'
  before="$(lockhash)"
  out="$( cd "$W" && PKG=acdp T=99.0.0 RELOCK_ATTEMPTS=2 RELOCK_SLEEP=1 "$RELOCK" 2>&1 )"; rc=$?
  check "live: unpublished 99.0.0 fails closed, lock restored" '[ $rc -eq 1 ] && [ "$before" = "$(lockhash)" ]' 'echo "rc=$rc $out"'
fi

echo; echo "===================="; echo "  $PASS passed, $FAIL failed"; echo "===================="
[ "$FAIL" -eq 0 ]
