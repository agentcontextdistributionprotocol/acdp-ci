#!/usr/bin/env bash
# relock.sh — re-lock an npm consumer after bump-consume.yml has rewritten
# package.json to PKG@T, and FAIL CLOSED if the resulting lockfile is not
# installable.
#
# Why this exists (acdp-ci#28): a release publishes the main package before
# its platform packages (optionalDependencies). `npm install --package-lock-only`
# run in that window exits 0 and silently leaves the not-yet-published optional
# deps out of the lock, so the bot PR then fails `npm ci` in the consumer
# (EUSAGE "Missing: …-darwin-arm64@X from lock file"). The old wait loop only
# looked at the main package, so it could not see this.
#
# Steps: (1) wait until every optionalDependency of PKG@T is served,
# (2) relock, (3) verify — every optional dep present in the lock,
# `npm ci --dry-run` exits 0, the lock pins PKG at exactly T, and every
# tarball it resolves downloads — retrying (1)-(3) a bounded number of times,
# (4) on exhaustion restore the original lock and exit 1, so the caller never
# opens a PR from a broken lock.
#
# Env: PKG (required), T (required, target version)
#      RELOCK_ATTEMPTS (default 24), RELOCK_SLEEP seconds (default 15) ≈ 6 min
set -euo pipefail

: "${PKG:?PKG is required}" "${T:?T is required}"
ATTEMPTS="${RELOCK_ATTEMPTS:-24}"
SLEEP="${RELOCK_SLEEP:-15}"

[ -f package-lock.json ] || { echo "::error::no package-lock.json in $(pwd)" >&2; exit 1; }
BACKUP="$(mktemp)"
cp package-lock.json "$BACKUP"
OK=0
# Whatever the exit path (including an unexpected crash under set -e), a run
# that did not verify leaves the original lockfile in place.
# shellcheck disable=SC2329  # invoked via trap
cleanup() {
  [ "$OK" -eq 1 ] || cp "$BACKUP" package-lock.json
  rm -f "$BACKUP" "$BACKUP.err"
}
trap cleanup EXIT

# name<TAB>spec per optional dependency of PKG@T. Empty = pure-JS package.
# A failed or unparseable `npm view` is an error, never "no optionals".
list_optionals() {
  local raw
  raw="$(npm view "$PKG@$T" optionalDependencies --json 2>/dev/null)" || return 1
  [ -z "$raw" ] && return 0   # npm prints nothing when the field is absent
  printf '%s' "$raw" | node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      const o=JSON.parse(s);
      if (o===null || typeof o!=="object" || Array.isArray(o)) process.exit(2);
      for (const [k,v] of Object.entries(o)) {
        if (typeof v!=="string") process.exit(2);
        console.log(k+"\t"+v);
      }
    })'
}

fail() {
  echo "::error::$1" >&2
  exit 1
}

attempt=1
last_problem=""
while [ "$attempt" -le "$ATTEMPTS" ]; do
  echo "relock attempt $attempt/$ATTEMPTS for $PKG@$T"
  last_problem=""

  if ! OPTS="$(list_optionals)"; then
    last_problem="could not read optionalDependencies of $PKG@$T from the registry"
  else
    # (1) every platform package must be served before we relock.
    while IFS=$'\t' read -r name spec; do
      [ -z "$name" ] && continue
      # An `npm:real@range` alias spec is viewed as `real@range`.
      view="$name@$spec"
      case "$spec" in npm:*) view="${spec#npm:}" ;; esac
      if [ -z "$(npm view "$view" version 2>/dev/null || true)" ]; then
        last_problem="optional dependency $name@$spec is not on the registry yet"
        break
      fi
    done <<<"$OPTS"
  fi

  if [ -z "$last_problem" ]; then
    # (2) relock. --prefer-online: don't trust a stale packument cache.
    if ! npm install --package-lock-only --ignore-scripts --prefer-online; then
      last_problem="npm install --package-lock-only failed"
    fi
  fi

  if [ -z "$last_problem" ]; then
    # (3a) every optional dep present in the lock, at the top level or nested
    # under another package after a hoisting conflict. Presence only: the lock
    # may legitimately resolve a newer in-range version if another release
    # landed meanwhile, and `npm ci --dry-run` below is the authoritative
    # check. (npm: aliases keep their alias name as the lock key.)
    missing="$(OPTS="$OPTS" node -e '
      const lock=require(process.cwd()+"/package-lock.json").packages||{};
      const keys=Object.keys(lock);
      const out=[];
      for (const line of (process.env.OPTS||"").split("\n")) {
        if (!line) continue;
        const [name,spec]=line.split("\t");
        const suffix="node_modules/"+name;
        if (!keys.some(k=>k===suffix||k.endsWith("/"+suffix))) out.push(name+"@"+spec);
      }
      console.log(out.join(", "));')"
    if [ -n "$missing" ]; then
      last_problem="lockfile is missing optional dependencies: $missing"
    elif ! npm ci --dry-run --ignore-scripts >/dev/null 2>"$BACKUP.err"; then
      last_problem="npm ci --dry-run rejects the lockfile: $(head -c 400 "$BACKUP.err" | tr '\n' ' ')"
    fi
    rm -f "$BACKUP.err"
  fi

  if [ -z "$last_problem" ]; then
    # (3b) the lock installs exactly PKG@T — the version the PR title names —
    # and every tarball it resolves (PKG and its optional deps) downloads. The
    # packument lists a version before its tarball is served, and `npm ci
    # --dry-run` never fetches tarballs, so without this a bump PR's CI could
    # 404 on `npm ci` (acdp-ui-console #186).
    if ! check="$(OPTS="$OPTS" node -e '
      const lock=require(process.cwd()+"/package-lock.json").packages||{};
      const pkg=process.env.PKG, T=process.env.T;
      const root=lock["node_modules/"+pkg]||lock["node_modules/"+pkg.split("/").pop()];
      if (!root) { console.log("BAD\t"+pkg+" is not in the lockfile"); process.exit(0); }
      if (root.version!==T) { console.log("BAD\tlockfile pins "+pkg+" at "+root.version+", not "+T); process.exit(0); }
      const urls=[root.resolved];
      const keys=Object.keys(lock);
      for (const line of (process.env.OPTS||"").split("\n")) {
        if (!line) continue;
        const suffix="node_modules/"+line.split("\t")[0];
        for (const k of keys) if (k===suffix||k.endsWith("/"+suffix)) urls.push(lock[k].resolved);
      }
      for (const u of urls) if (u) console.log("URL\t"+u);')"; then
      last_problem="could not read package-lock.json"
    elif bad="$(printf '%s\n' "$check" | awk -F'\t' '$1=="BAD"{print $2; exit}')" && [ -n "$bad" ]; then
      last_problem="$bad"
    else
      while IFS=$'\t' read -r kind url; do
        [ "$kind" = URL ] || continue
        if ! curl -fsSL --max-time 60 -o /dev/null "$url"; then
          last_problem="tarball not downloadable yet: $url"
          break
        fi
      done <<<"$check"
    fi
  fi

  if [ -z "$last_problem" ]; then
    echo "lockfile verified for $PKG@$T"
    OK=1
    exit 0
  fi
  echo "attempt $attempt failed: $last_problem" >&2
  attempt=$((attempt + 1))
  [ "$attempt" -le "$ATTEMPTS" ] && sleep "$SLEEP"
done

fail "relock for $PKG@$T not installable after $ATTEMPTS attempts — $last_problem. No PR opened; re-run the bump once the release has fully published."
