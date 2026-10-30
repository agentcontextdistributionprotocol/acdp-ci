#!/usr/bin/env bash
# Offline harness for actions/cargo-bump/bump.sh (acdp-ci#47). A shadow `cargo`
# (tests/bump-cargo/bin/cargo) models `cargo update --precise`; no network.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BUMP="$HERE/../../actions/cargo-bump/bump.sh"
PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1 -- $2"; }
check() { if eval "$2"; then pass "$1"; else fail "$1" "$(eval "${3:-true}")"; fi; }

# Real cargo on PATH ahead of the stub would make every case vacuous.
PATH="$HERE/bin:$PATH"
[ "$(command -v cargo)" = "$HERE/bin/cargo" ] || { echo "PATH guard: cargo is not the shadow"; exit 2; }

lock() {  # lock <file> <acdp-version>
  cat > "$1" <<L
version = 4

[[package]]
name = "acdp"
version = "$2"
source = "registry+https://github.com/rust-lang/crates.io-index"
dependencies = [
 "acdp-chain",
]

[[package]]
name = "acdp-chain"
version = "$2"
source = "registry+https://github.com/rust-lang/crates.io-index"

[[package]]
name = "acdp-registry-types"
version = "0.7.0"

[[package]]
name = "serde"
version = "1.0.200"
source = "registry+https://github.com/rust-lang/crates.io-index"
L
}

# newcase <root acdp line> -> W: a registry-rs-shaped repo at 0.18.1
newcase() {
  W="$(mktemp -d)"; FAKE="$W/.fake"; mkdir -p "$FAKE" "$W/tools/live-smoke" "$W/supply-chain"; : > "$FAKE/calls.log"; export FAKE
  cat > "$W/Cargo.toml" <<M
[workspace.dependencies]
$1
acdp-registry-types = { path = "crates/acdp-registry-types", version = "0.7.0" }
serde = "1"
M
  cat > "$W/tools/live-smoke/Cargo.toml" <<'M'
[package]
name = "live-smoke"

[dependencies]
acdp       = { version = "=0.18.1", features = ["client"] }
M
  lock "$W/Cargo.lock" 0.18.1; lock "$W/tools/live-smoke/Cargo.lock" 0.18.1
  cat > "$W/supply-chain/config.toml" <<'V'
[cargo-vet]
version = "0.10"

[[exemptions.acdp]]
version = "0.18.1"
criteria = "safe-to-deploy"

[[exemptions.acdp-chain]]
version = "0.18.1"
criteria = "safe-to-deploy"

[[exemptions.acdp-old]]
version = "0.9.0"
criteria = "safe-to-deploy"

[[exemptions.serde]]
version = "0.18.1"
criteria = "safe-to-deploy"
V
}
run_bump() { ( cd "$W" && PKG=acdp T=0.18.2 "$BUMP" 2>&1 ); }
line() { grep -E "^\s*$2\s*=" "$W/$1" | head -1; }
vet_ver() { awk -v c="[[exemptions.$1]]" '$0==c{f=1;next} f&&/^version/{print $3;exit}' "$W/supply-chain/config.toml" | tr -d '"'; }
lock_ver() { awk -v n="name = \"$2\"" '$0==n{f=1;next} f&&/^version/{print $3;exit}' "$W/$1" | tr -d '"'; }

echo "== exact pin, table form, + extra manifest + vet exemptions (the acdp-registry-rs shape) =="
newcase 'acdp = { version = "=0.18.1", features = ["server", "client"] }'
out="$(cd "$W" && PKG=acdp T=0.18.2 EXTRA_MANIFESTS='tools/live-smoke' "$BUMP" 2>&1)"; rc=$?
check "exit 0" '[ $rc -eq 0 ]' 'echo "rc=$rc $out"'
check "root: =0.18.1 stays exact as =0.18.2, features kept" \
  '[ "$(line Cargo.toml acdp)" = "acdp = { version = \"=0.18.2\", features = [\"server\", \"client\"] }" ]' 'line Cargo.toml acdp'
check "extra manifest: =0.18.1 stays exact as =0.18.2" \
  '[ "$(line tools/live-smoke/Cargo.toml acdp)" = "acdp       = { version = \"=0.18.2\", features = [\"client\"] }" ]' 'line tools/live-smoke/Cargo.toml acdp'
check "root lockfile re-locked" '[ "$(lock_ver Cargo.lock acdp)" = 0.18.2 ]' 'lock_ver Cargo.lock acdp'
check "extra lockfile re-locked" '[ "$(lock_ver tools/live-smoke/Cargo.lock acdp)" = 0.18.2 ]' 'lock_ver tools/live-smoke/Cargo.lock acdp'
check "cargo update ran once per manifest" \
  '[ "$(grep -c -- "update -p acdp --precise 0.18.2" "$FAKE/calls.log")" = 2 ] && grep -q "manifest-path tools/live-smoke/Cargo.toml" "$FAKE/calls.log"' 'cat "$FAKE/calls.log"'
check "vet: exemptions.acdp moved to 0.18.2" '[ "$(vet_ver acdp)" = 0.18.2 ]' 'vet_ver acdp'
check "vet: lockstep exemptions.acdp-chain moved to 0.18.2" '[ "$(vet_ver acdp-chain)" = 0.18.2 ]' 'vet_ver acdp-chain'
check "vet: unrelated acdp-old exemption untouched" '[ "$(vet_ver acdp-old)" = 0.9.0 ]' 'vet_ver acdp-old'
check "vet: non-acdp exemption untouched even at a matching version" '[ "$(vet_ver serde)" = 0.18.1 ]' 'vet_ver serde'
check "path crate acdp-registry-types untouched" \
  'line Cargo.toml acdp-registry-types | grep -q "version = \"0.7.0\""' 'line Cargo.toml acdp-registry-types'

echo "== a third-party crate that moves in the lock keeps its exemption (a trust decision, not ours) =="
newcase 'acdp = "=0.18.1"'
perl -i -pe 's/^version = "0.18.1"/version = "1.0.200"/ if $prev =~ /exemptions\.serde/; $prev = $_' "$W/supply-chain/config.toml"
out="$(cd "$W" && FAKE_ALSO_MOVE='serde 1.0.201' PKG=acdp T=0.18.2 "$BUMP" 2>&1)"; rc=$?
check "serde moved in the lock" '[ $rc -eq 0 ] && [ "$(lock_ver Cargo.lock serde)" = 1.0.201 ]' 'echo "rc=$rc $(lock_ver Cargo.lock serde) $out"'
check "vet: exemptions.serde stays at 1.0.200" '[ "$(vet_ver serde)" = 1.0.200 ]' 'vet_ver serde'
check "vet: exemptions.acdp still moved" '[ "$(vet_ver acdp)" = 0.18.2 ]' 'vet_ver acdp'

echo "== operators preserved: ^, ~, bare; plain-string form =="
for req in '^0.18.1:^0.18.2' '~0.18.1:~0.18.2' '0.18.1:0.18.2' '= 0.18.1:=0.18.2'; do
  from="${req%%:*}"; to="${req#*:}"
  newcase "acdp = { version = \"$from\", features = [\"client\"] }"
  out="$(run_bump)"; rc=$?
  check "table \"$from\" -> \"$to\"" '[ $rc -eq 0 ] && [ "$(line Cargo.toml acdp)" = "acdp = { version = \"$to\", features = [\"client\"] }" ]' 'echo "rc=$rc $(line Cargo.toml acdp) $out"'
  newcase "acdp = \"$from\""
  out="$(run_bump)"; rc=$?
  check "string \"$from\" -> \"$to\"" '[ $rc -eq 0 ] && [ "$(line Cargo.toml acdp)" = "acdp = \"$to\"" ]' 'echo "rc=$rc $(line Cargo.toml acdp) $out"'
done

echo "== without EXTRA_MANIFESTS the second workspace is not touched =="
newcase 'acdp = { version = "=0.18.1" }'
out="$(run_bump)"; rc=$?
check "exit 0" '[ $rc -eq 0 ]' 'echo "$out"'
check "tools/live-smoke left at =0.18.1" 'line tools/live-smoke/Cargo.toml acdp | grep -q "=0.18.1"' 'line tools/live-smoke/Cargo.toml acdp'

echo "== no vet config -> still succeeds =="
newcase 'acdp = "=0.18.1"'; rm -r "$W/supply-chain"
out="$(run_bump)"; rc=$?
check "exit 0 with no supply-chain/" '[ $rc -eq 0 ] && [ "$(line Cargo.toml acdp)" = "acdp = \"=0.18.2\"" ]' 'echo "rc=$rc $out"'

echo "== fail closed =="
newcase 'acdp = { version = ">=0.18, <0.20" }'
out="$(run_bump)"; rc=$?
check "range requirement: non-zero" '[ $rc -ne 0 ]' 'echo "rc=$rc"'
check "range requirement: says why" 'printf "%s" "$out" | grep -q "unsupported version requirement"' 'echo "$out"'
check "range requirement: cargo update never ran" '! grep -q update "$FAKE/calls.log"' 'cat "$FAKE/calls.log"'

newcase 'acdp = "=0.18.1"'; printf '[package]\nname = "x"\n' > "$W/tools/live-smoke/Cargo.toml"
out="$(cd "$W" && PKG=acdp T=0.18.2 EXTRA_MANIFESTS='tools/live-smoke' "$BUMP" 2>&1)"; rc=$?
check "extra manifest without the dependency: non-zero" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "no acdp version requirement"' 'echo "rc=$rc $out"'

newcase 'acdp = "=0.18.1"'
out="$(cd "$W" && PKG=acdp T=0.18.2 EXTRA_MANIFESTS='tools/nope' "$BUMP" 2>&1)"; rc=$?
check "missing extra manifest: non-zero" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "tools/nope/Cargo.toml not found"' 'echo "rc=$rc $out"'

newcase 'acdp = "=0.18.1"'; printf '\n[dev-dependencies.acdp]\nversion = "=0.18.1"\n' >> "$W/Cargo.toml"
out="$(run_bump)"; rc=$?
check "dotted [dev-dependencies.acdp] table alongside an inline one: non-zero, says why" '[ $rc -ne 0 ] && printf "%s" "$out" | grep -q "dotted"' 'echo "rc=$rc $out"'

newcase 'acdp-chain = "=0.18.1"'
out="$(run_bump)"; rc=$?
check "only acdp-chain (not PKG) in root: non-zero, acdp-chain untouched" '[ $rc -ne 0 ] && line Cargo.toml acdp-chain | grep -q "=0.18.1"' 'echo "rc=$rc $out"'

newcase 'acdp = "=0.18.1"'
out="$(cd "$W" && FAKE_CARGO_FAIL=1 PKG=acdp T=0.18.2 "$BUMP" 2>&1)"; rc=$?
check "cargo update failure: non-zero" '[ $rc -ne 0 ]' 'echo "rc=$rc"'
check "cargo update failure: vet config not touched" '[ "$(vet_ver acdp)" = 0.18.1 ]' 'vet_ver acdp'

out="$(cd "$W" && env -u PKG T=0.18.2 "$BUMP" 2>&1)"; rc=$?
check "PKG unset: non-zero" '[ $rc -ne 0 ]' 'echo "rc=$rc"'

echo "== workflow wiring =="
WF="$HERE/../../.github/workflows/bump-consume.yml"
check "cargo path uses actions/cargo-bump@v1" 'grep -q "acdp-ci/actions/cargo-bump@v1" "$WF"' 'true'
check "extra-manifests input is passed through" 'grep -q "extra-manifests: \${{ inputs.extra-manifests }}" "$WF"' 'true'
check "no whole-string perl rewrite left in the workflow" '! grep -q "s/(version" "$WF"' 'grep -n "s/(version" "$WF"'
bump_line="$(grep -n 'cargo-bump@' "$WF" | head -1 | cut -d: -f1)"
pr_line="$(grep -n 'git checkout -b "\$BR"' "$WF" | head -1 | cut -d: -f1)"
check "cargo-bump step is before branch creation" '[ -n "$bump_line" ] && [ -n "$pr_line" ] && [ "$bump_line" -lt "$pr_line" ]' 'echo "bump=$bump_line pr=$pr_line"'

echo; echo "===================="; echo "  $PASS passed, $FAIL failed"; echo "===================="
[ "$FAIL" -eq 0 ]
