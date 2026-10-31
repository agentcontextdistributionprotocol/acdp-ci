#!/usr/bin/env bash
# relock.sh — re-lock a uv consumer to exactly PKG==T, and FAIL CLOSED if the
# index never serves T.
#
# Why this exists: the old step ran `uv lock --upgrade-package PKG`, which takes
# whatever the index serves *now*. The registry wait in bump-consume.yml polls
# PyPI's JSON API, which sees a release before the simple index uv resolves
# against, so the lock landed one release behind the PR title (acdp-playground
# #110 titled 0.18.3 locked 0.18.2; #111 titled 0.19.0 locked 0.18.3).
#
# Each attempt: `uv lock --upgrade-package PKG==T --refresh-package PKG` (uv
# errors when T is not resolvable yet), then verify uv.lock pins PKG at T.
# Retries with linear backoff capped at RELOCK_SLEEP_MAX; on exhaustion restores
# the original uv.lock and exits 1, so the caller never opens a PR whose lock
# installs a different version than its title.
#
# Env: PKG (required), T (required, target version)
#      RELOCK_ATTEMPTS (default 10), RELOCK_SLEEP base seconds (default 10),
#      RELOCK_SLEEP_MAX (default 60)  ≈ 6.5 min worst case
set -euo pipefail

: "${PKG:?PKG is required}" "${T:?T is required}"
ATTEMPTS="${RELOCK_ATTEMPTS:-10}"
SLEEP="${RELOCK_SLEEP:-10}"
SLEEP_MAX="${RELOCK_SLEEP_MAX:-60}"

[ -f uv.lock ] || { echo "::error::no uv.lock in $(pwd)" >&2; exit 1; }
BACKUP="$(mktemp)"
cp uv.lock "$BACKUP"
OK=0
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  [ "$OK" -eq 1 ] || cp "$BACKUP" uv.lock
  rm -f "$BACKUP" "$BACKUP.err"
}
trap cleanup EXIT

# uv.lock names are PEP 503-normalized
NAME="$(printf '%s' "$PKG" | tr 'A-Z_.' 'a-z--')"
locked_version() {
  awk -v n="name = \"$NAME\"" '$0=="[[package]]"{f=0} $0==n{f=1;next} f&&/^version = /{v=$3; gsub(/"/,"",v); print v; exit}' uv.lock
}

attempt=1
last_problem=""
while [ "$attempt" -le "$ATTEMPTS" ]; do
  echo "relock attempt $attempt/$ATTEMPTS for $PKG==$T"
  if ! uv lock --upgrade-package "$PKG==$T" --refresh-package "$PKG" 2>"$BACKUP.err"; then
    last_problem="uv lock could not resolve $PKG==$T: $(tail -c 400 "$BACKUP.err" | tr '\n' ' ')"
  else
    got="$(locked_version)"
    if [ "$got" = "$T" ]; then
      echo "uv.lock verified: $PKG $T"
      OK=1
      exit 0
    fi
    last_problem="uv.lock pins $PKG at '${got:-<absent>}', not $T"
  fi
  echo "attempt $attempt failed: $last_problem" >&2
  [ "$attempt" -lt "$ATTEMPTS" ] && { s=$((SLEEP * attempt)); [ "$s" -gt "$SLEEP_MAX" ] && s="$SLEEP_MAX"; sleep "$s"; }
  attempt=$((attempt + 1))
done

echo "::error::relock for $PKG==$T failed after $ATTEMPTS attempts — $last_problem. No PR opened; re-run the bump once the index serves $T." >&2
exit 1
