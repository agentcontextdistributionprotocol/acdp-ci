#!/usr/bin/env bash
# Bump PKG to T in a cargo consumer (acdp-ci#47). For the root workspace and each
# EXTRA_MANIFESTS dir:
#   1. rewrite every `PKG = "…"` / `PKG = { version = "…", … }` requirement in its
#      Cargo.toml to T, KEEPING the operator (`=`, `^`, `~` or none) — an exact
#      `=x.y.z` pin stays exact;
#   2. `cargo update -p PKG --precise T` against that manifest, so its own lockfile
#      moves too.
# Then, if VET_CONFIG exists, move every `[[exemptions.acdp*]]` whose version is
# the one a lockfile just moved away from to the version it moved to — so
# `cargo vet --locked` does not go red on the bump PR.
# Fails closed (non-zero, the caller opens no PR) on a requirement it can't
# rewrite safely (a range such as `>=0.1, <0.2`, or a dotted `[dependencies.PKG]`
# table) or a manifest with no PKG requirement to bump.
#
# Env: PKG, T (required); EXTRA_MANIFESTS (dirs, whitespace/newline separated,
# relative to the repo root); VET_CONFIG (default supply-chain/config.toml).
set -euo pipefail
: "${PKG:?PKG is required}" "${T:?T is required}"
VET_CONFIG="${VET_CONFIG:-supply-chain/config.toml}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# registry-sourced "name version" pairs of a lockfile, sorted
lock_pkgs() {
  [ -f "$1" ] || return 0
  awk '/^\[\[package\]\]/{n="";v="";s=""} /^name = /{n=$3} /^version = /{v=$3} /^source = "registry\+/{s=1}
       /^$/{if(n!=""&&s)print n,v; n=""} END{if(n!=""&&s)print n,v}' "$1" | tr -d '"' | sort -u
}

# rewrite_manifest <Cargo.toml>: prints the number of requirements rewritten
rewrite_manifest() {
  PKG="$PKG" T="$T" perl -i -ne '
    BEGIN { $n = 0 }
    my $p = quotemeta($ENV{PKG}); my $v = $ENV{T};
    my $fix = sub {
      my ($req) = @_;
      $req =~ /^\s*([=^~]?)\s*\d[0-9A-Za-z.+-]*\s*$/
        or die "unsupported version requirement \"$req\" for $ENV{PKG} in $ARGV (line $.): only =, ^, ~ or a bare version can be bumped\n";
      $n++; return "$1$v";
    };
    /^\s*\[[^\]]*dependencies\.$p\]\s*$/
      and die "$ARGV (line $.): dotted [...dependencies.$ENV{PKG}] tables are not rewritten; use the inline form\n";
    if (/^\s*$p\s*=/) {
      if (/\{/) { s/(\bversion\s*=\s*")([^"]*)(")/$1.$fix->($2).$3/e }
      else      { s/(=\s*")([^"]*)(")/$1.$fix->($2).$3/e }
    }
    print;
    END { print STDERR "$n\n" }
  ' "$1" 2>"$WORK/n" || { cat "$WORK/n" >&2; return 1; }
  tail -n1 "$WORK/n"
}

DIRS=(".")
for d in ${EXTRA_MANIFESTS:-}; do DIRS+=("${d%/}"); done

: > "$WORK/moves"
for d in "${DIRS[@]}"; do
  m="$d/Cargo.toml"; lock="$d/Cargo.lock"
  [ -f "$m" ] || { echo "::error::$m not found" >&2; exit 1; }
  lock_pkgs "$lock" > "$WORK/before"
  n="$(rewrite_manifest "$m")"
  [ "$n" -gt 0 ] || { echo "::error::no $PKG version requirement to bump in $m" >&2; exit 1; }
  echo "$m: $n requirement(s) of $PKG -> $T"
  cargo update -p "$PKG" --precise "$T" --manifest-path "$m"
  lock_pkgs "$lock" > "$WORK/after"
  # crates that moved: one old and one new version (a crate present at two
  # versions on either side is ambiguous, so it is left for a human)
  join -j1 <(awk '{c[$1]++; v[$1]=$2} END{for(k in c) if(c[k]==1) print k,v[k]}' "$WORK/before" | sort) \
           <(awk '{c[$1]++; v[$1]=$2} END{for(k in c) if(c[k]==1) print k,v[k]}' "$WORK/after"  | sort) \
    | awk '$2!=$3' >> "$WORK/moves"
done

if [ -f "$VET_CONFIG" ]; then
  sort -u "$WORK/moves" > "$WORK/moves.u"
  MOVES="$WORK/moves.u" perl -i -ne '
    BEGIN { open my $f, "<", $ENV{MOVES} or die; while (<$f>) { my ($c,$o,$n) = split; $m{"$c $o"} = $n } }
    if (/^\s*\[\[exemptions\.("?)([^\]"]+)\1\]\]/) { $c = $2 } elsif (/^\s*\[/) { $c = "" }
    if ($c =~ /^acdp/ && /^(\s*version\s*=\s*")([^"]+)(")/ && exists $m{"$c $2"}) {
      my $n = $m{"$c $2"}; s/^(\s*version\s*=\s*")[^"]+(")/$1$n$2/;
      print STDERR "$ARGV: exemptions.$c -> $n\n";
    }
    print;
  ' "$VET_CONFIG"
fi
