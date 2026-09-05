#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every acdp-* repo.
#
# Idempotent with respect to required_status_checks.contexts only — see
# "Known gaps" below for everything else this PUTs unconditionally. For each
# repo it: turns on squash + delete-branch-on-merge, and sets branch
# protection on the default branch with that repo's CI jobs as REQUIRED
# status checks (so auto-merge has something to wait on). Required-check
# names are per-repo (they must match each repo's real check-run names
# exactly) — declared in checks_for() below. Nothing in this script reads
# actual check-runs; an earlier version of this comment claimed checks were
# "verified against actual check-runs so a required check can never hang a
# PR" — that was never backed by code and is retracted. "Allow auto-merge"
# is enabled only for repos that have at least one required check — see the
# protection-only branch below.
#
# --- The drift guard ---
# PUT .../branches/{b}/protection replaces required_status_checks.contexts
# WHOLESALE. If checks_for() below has drifted out of sync with what's live
# on GitHub (a check added to CI and required by hand, or left behind by an
# earlier run of a since-edited table), the next run silently deletes it —
# manifesting as a green PR with a missing gate, not an error. Before the
# first mutating call, the script reads live required contexts from
# GET /repos/{o}/{r}/branches/{b} (the branch *summary* — the SAME endpoint
# the CI-6 guards in .github/workflows/auto-merge.yml and bump-consume.yml
# already use; deliberately NOT the separate .../branches/{b}/protection
# endpoint, which 404s for four different states — unprotected branch,
# missing branch, missing repo, insufficient scope — separable only by
# string-matching the error body. The summary instead returns 200 with
# .protected=false for an unprotected branch, so "unprotected" is a
# positive signal and every non-200 is unambiguously fatal) and refuses to
# proceed if any live required context is absent from checks_for()'s
# declared list for that repo, unless --allow-check-removal is passed. This
# is a set difference, not equality: order and duplicates never matter, so
# a live list that is the declared list merely reordered is NOT drift.
#
# This guard catches exactly ONE defect axis: a live required check that
# the next PUT would silently drop. It does NOT catch the opposite axis — a
# real PR gate (a check-run CI actually produces) that was never added to
# checks_for() and so was never required at all. That axis is invisible to
# both --check and normal apply; finding it means comparing checks_for()
# against each repo's CI workflow by hand.
#
# --allow-check-removal
#   Overrides the guard for a single invocation: proceeds with the PUT even
#   though it would drop a live required check that checks_for() doesn't
#   declare. Use only for an intentional removal. Apply mode only: combined
#   with --check it is rejected outright (exit 2) rather than silently
#   suppressing --check's drift report.
#
# --check / --dry-run (synonyms)
#   Runs the same guard against every named repo (or all managed repos by
#   default) and reports drift, without making any mutating call. Prints
#   the live required contexts it read for every surveyed repo — including
#   repos with no drift — because a permission-degraded read (e.g. a token
#   missing contents:read) can produce a payload indistinguishable from a
#   genuinely unprotected branch, and "no drift reported" is also exactly
#   what a broken token looks like. An unreadable repo is recorded as an
#   error, distinct from drift, and the sweep continues to the remaining
#   repos rather than aborting; the exit status reflects whatever
#   accumulated (drift and/or errors) only after the whole sweep completes.
#   --check needs only contents:read; apply needs admin.
#
# Portable to macOS's stock bash 3.2 (no associative arrays).
#
# Excluded on purpose:
#   acdp-rs      — already protected with its own (richer) config; do not clobber.
#   acdp-website — private repo; branch protection needs GitHub Pro or public.
#
# Protection-only (managed here, but with zero required checks):
#   acdp-ci  — every workflow is `workflow_call`-only, so the repo produces zero
#              check-runs on its own PRs; there is nothing to require. Protection
#              still matters here: with enforce_admins:false it doesn't constrain
#              the solo maintainer, but it does constrain the acdp-deps-bot App
#              (Contents+Workflows write, org-wide) and Dependabot, neither of
#              which is an admin. And since the `v1` tag is force-moved to wherever
#              `main` points, protecting `main` from force-push/deletion is the
#              upstream half of protecting `v1` (the ruleset in DELIVERY-STANDARD.md
#              is the other half).
#   .github  — the org's `.github` repo has no `.github/workflows/` directory at
#              all (verified via the contents API) — same reasoning as acdp-ci.
# Neither gets allow_auto_merge=true: auto-merge.yml's `gh pr merge --auto` would
# merge a PR instantly on a branch with no required checks — a hazard, not a
# convenience, on a zero-check repo. auto-merge.yml and bump-consume.yml both
# now carry their own guard against exactly this (CI-6, Wave 4) — refusing to
# arm auto-merge unless this same script has configured required status checks
# on the target branch — but leaving allow_auto_merge:false here is still the
# right call for these two repos specifically, since neither script-managed
# option even applies (acdp-ci/.github have no CI job to require in the first
# place). Both repos are allow_auto_merge:false on GitHub today, so leaving
# auto-merge off here codifies the status quo rather than changing behaviour.
#
# Known gaps — every run also resets the following to GitHub's defaults,
# regardless of what was live before, because the protection PUT body below
# only ever sets required_status_checks plus the three fields explicitly
# nulled: strict, enforce_admins, required_pull_request_reviews,
# restrictions, required_status_checks.checks (the per-check app_id pinning
# — verified live 2026-09-05: acdp-registry-rs has all four checks pinned to
# app_id:15368, while acdp-control-plane is MIXED, one check pinned and two
# app_id:null — direct evidence that a prior contexts-only PUT already
# widened two of its checks to "any app"), required_linear_history,
# allow_force_pushes, allow_deletions, required_conversation_resolution,
# lock_branch, block_creations, allow_fork_syncing. And, as noted above, the
# drift guard cannot see a real PR gate that was never added to
# checks_for() in the first place (axis C).
#
# Prereqs: gh auth with admin:org for apply; contents:read is enough to run
#          --check. Org secrets (App id/key) are set separately.
# Usage: ./standardize.sh [--check|--dry-run] [--allow-check-removal] [repo ...]
#        ./standardize.sh -h | --help
#        (default repo list, and order flags may appear in: see below)
set -euo pipefail

ORG=agentcontextdistributionprotocol
# Word-split unquoted below (`for repo in $repos`) under default globbing — every
# name here must stay free of whitespace and glob metacharacters. `.github`'s
# leading dot is not one (no unquoted glob expands it), but this is a property of
# the specific names, not something the script enforces.
ALL_REPOS="acdp-control-plane acdp-registry-rs acdp-playground acdp-verifier-py acdp-ui-console agentcontextdistributionprotocol acdp-ci .github"

usage() {
  cat <<'EOF'
Usage: standardize.sh [--check|--dry-run] [--allow-check-removal] [repo ...]
       standardize.sh -h | --help

  --check, --dry-run     Read-only: report required-check drift per repo,
                          make zero mutating calls. Needs only contents:read.
  --allow-check-removal  Apply mode only: proceed with the protection PUT
                          even if it would drop a live required check that
                          checks_for() doesn't declare.
  -h, --help             Show this help and exit 0.
  --                      End of flags; every following argument is a repo.

With no repo arguments, all managed repos are processed. Apply mode (the
default, no --check) needs gh auth with admin:org.
EOF
}

# Emits one required check-name per line for the given repo (non-zero if unknown).
# A repo may legitimately have zero required checks: printing nothing and
# returning 0 means "protection-only, no required checks" — distinct from
# returning 1, which means "not in the managed set at all, skip entirely".
checks_for() {
  case "$1" in
    acdp-control-plane)
      printf '%s\n' "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)" ;;
    acdp-registry-rs)
      printf '%s\n' "rustfmt" "clippy" "tests" "conformance (spec fixtures)" ;;
    acdp-playground)
      printf '%s\n' "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds" ;;
    acdp-verifier-py)
      printf '%s\n' "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)" ;;
    acdp-ui-console)
      printf '%s\n' "Lint · Typecheck · Test · Build" ;;
    agentcontextdistributionprotocol)  # the spec/RFC repo
      printf '%s\n' "All Validations Passed" "Validate Schemas, Examples, and Conformance" ;;
    acdp-ci|.github)  # protection-only — see header comment
      return 0 ;;
    *) return 1 ;;
  esac
}

# default_branch <repo> — echoes the repo's default branch name on stdout;
# returns 1 (prints nothing usable) if the repo can't be read, or if
# .default_branch resolves empty/null, so callers never PUT to
# branches/null/protection.
#
# Called as `if ! branch=$(default_branch "$repo"); then …`, so -e is OFF
# for this entire function body (see live_contexts() below for why) — every
# command here checks its own exit status explicitly.
default_branch() {
  local repo="$1"
  local errfile
  errfile=$(mktemp) || return 1
  trap 'rm -f "$errfile"' RETURN
  local raw
  if ! raw=$(gh api "repos/$ORG/$repo" --jq '.default_branch // empty' 2>"$errfile"); then
    echo "!! $repo: repos/$repo read failed: $(cat "$errfile")" >&2
    return 1
  fi
  if [ -z "$raw" ]; then
    echo "!! $repo: default_branch is empty/null -- refusing to protect branches/null" >&2
    return 1
  fi
  printf '%s\n' "$raw"
  return 0
}

# live_contexts <repo> <branch> — echoes the live required-status-check
# contexts for that branch as a compact JSON array on stdout; returns 1
# (NEVER prints "[]" on failure) when live state can't be determined for
# any reason: unreadable branch, malformed payload, or a permission-
# degraded read. Reads GET /repos/{o}/{r}/branches/{b} — see the header
# comment for why that endpoint and not .../protection.
#
# Call site MUST be `if ! live=$(live_contexts …); then …` (never a bare
# assignment) — but that same construction means `set -e` is suppressed for
# this ENTIRE function body, including the gh/jq calls inside it: a failing
# `gh api` would otherwise fall through silently into `jq` on empty input.
# So every command below checks its own exit status explicitly instead of
# relying on -e, and `local var` / assignment are kept on separate lines so
# `local`'s own (always-zero) exit status can never mask a failed
# substitution.
live_contexts() {
  local repo="$1" branch="$2"
  local errfile
  errfile=$(mktemp) || return 1
  trap 'rm -f "$errfile"' RETURN

  local raw
  if ! raw=$(gh api "repos/$ORG/$repo/branches/$branch" 2>"$errfile"); then
    echo "!! $repo: branches/$branch read failed: $(cat "$errfile")" >&2
    return 1
  fi

  local result
  if ! result=$(printf '%s' "$raw" | jq -c '
        if (.protected|type) != "boolean" then error("no .protected -- unexpected payload")
        elif .protected == false then []
        elif (.protection.required_status_checks|type) != "object"
          then error("protected=true but no required_status_checks object -- read may be permission-degraded")
        elif (.protection.required_status_checks.contexts|type) != "array"
          then error("contexts is not an array")
        else .protection.required_status_checks.contexts end
      ' 2>"$errfile"); then
    echo "!! $repo: live required checks unreadable: $(cat "$errfile")" >&2
    return 1
  fi

  # A 200 with an empty body makes jq produce no output at all: $result is
  # then "" with an exit status of 0, which would otherwise fall through to
  # `return 0` below and violate this function's own contract ("never
  # prints [] on failure" -- an empty string isn't "[]" literally, but it's
  # just as unusable to the caller, and today's safety net downstream is
  # only the `--argjson` call rejecting empty input by accident). Fail
  # closed on purpose instead of relying on that accident.
  if [ -z "$result" ]; then
    echo "!! $repo: live required checks read produced empty output -- cannot determine live state" >&2
    return 1
  fi

  printf '%s\n' "$result"
  return 0
}

# --- flag parsing: every argument, not just leading ones -----------------
CHECK_MODE=0
ALLOW_CHECK_REMOVAL=0
end_of_flags=0
repos=""
# EXPLICIT_REPOS distinguishes "repo(s) named on the command line" from "no
# repo args, fell back to the default ALL_REPOS sweep" -- see the CHECK_MODE
# use below (an explicitly-named unmanaged repo must not exit 0 having read
# nothing; the default full sweep must not change behaviour).
EXPLICIT_REPOS=0
for arg in "$@"; do
  if [ "$end_of_flags" -eq 1 ]; then
    if [ -z "$repos" ]; then repos="$arg"; else repos="$repos $arg"; fi
    EXPLICIT_REPOS=1
    continue
  fi
  case "$arg" in
    --)
      end_of_flags=1
      ;;
    --check|--dry-run)
      CHECK_MODE=1
      ;;
    --allow-check-removal)
      ALLOW_CHECK_REMOVAL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "standardize.sh: unknown flag: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$repos" ]; then repos="$arg"; else repos="$repos $arg"; fi
      EXPLICIT_REPOS=1
      ;;
  esac
done
if [ -z "$repos" ]; then repos="$ALL_REPOS"; fi

# --check is read-only by contract; --allow-check-removal only ever matters
# at a mutation. Honoring both together (checks_for BEFORE CHECK_MODE) would
# let --check --allow-check-removal report "all repos in sync" while
# suppressing a real DRIFT report -- a monitor that can be told to lie is
# worse than no monitor. Reject the combination outright instead of merely
# reordering the precedence, so the contradiction can't happen at all.
if [ "$CHECK_MODE" -eq 1 ] && [ "$ALLOW_CHECK_REMOVAL" -eq 1 ]; then
  echo "standardize.sh: --check and --allow-check-removal are mutually exclusive (--allow-check-removal is apply-mode only)" >&2
  exit 2
fi

DRIFT=0
ERRORS=0

for repo in $repos; do
  if ! lines=$(checks_for "$repo"); then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"
    # An explicitly-named repo (not the default ALL_REPOS sweep) that turns
    # out to be unmanaged is almost always a typo -- e.g. `--check
    # acdp-registryrs` -- and CHECK_MODE must not exit 0 having surveyed
    # nothing. The default no-arg sweep is unaffected: it never names an
    # unmanaged repo in the first place (ALL_REPOS excludes acdp-rs and
    # acdp-website on purpose), and checks_for()'s tri-state skip itself is
    # unchanged either way.
    if [ "$CHECK_MODE" -eq 1 ] && [ "$EXPLICIT_REPOS" -eq 1 ]; then
      ERRORS=1
    fi
    continue
  fi

  if ! branch=$(default_branch "$repo"); then
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      continue
    else
      echo "!! $repo: cannot determine default branch — aborting before any mutation" >&2
      exit 1
    fi
  fi
  echo "== $repo (@$branch) =="

  if [ -z "$lines" ]; then
    # Protection-only: no required checks to gate on, so no auto-merge
    # either (see "Protection-only" in the header comment above). This PUT
    # sets required_status_checks:null, i.e. removes every required check —
    # so contexts_json must be the empty set here too: any live required
    # check on a "protection-only" repo MUST still block below, and
    # contexts_json is otherwise only assigned in the `else` branch — under
    # `set -u` a skipped assignment here would abort the script instead.
    auto_merge=false
    contexts_json='[]'
    protection_json='{"required_status_checks":null,"enforce_admins":false,"required_pull_request_reviews":null,"restrictions":null}'
  else
    auto_merge=true
    contexts_json=$(printf '%s' "$lines" | jq -R . | jq -sc .)
    protection_json=$(jq -nc --argjson ctx "$contexts_json" '{
      required_status_checks: { strict: true, contexts: $ctx },
      enforce_admins: false,
      required_pull_request_reviews: null,
      restrictions: null
    }')
  fi

  # --- drift guard: must run BEFORE the first mutating call, so --check
  # mutates nothing and a blocked apply never leaves allow_auto_merge=true
  # half-set against stale required checks. ---
  if ! live=$(live_contexts "$repo" "$branch"); then
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      continue
    else
      echo "!! $repo: cannot determine live required checks — aborting before any mutation" >&2
      exit 1
    fi
  fi
  echo "   $repo: live required checks = $live"

  if ! extras=$(jq -nc --argjson live "$live" --argjson want "$contexts_json" '$live - $want'); then
    echo "!! $repo: could not compute required-check drift (unexpected JSON)" >&2
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      continue
    else
      exit 1
    fi
  fi
  extras_len=$(printf '%s' "$extras" | jq 'length')

  if [ "$extras_len" -gt 0 ]; then
    extras_list=$(printf '%s' "$extras" | jq -r 'join(", ")')
    if [ "$ALLOW_CHECK_REMOVAL" -eq 1 ]; then
      echo "!! $repo: --allow-check-removal set — proceeding despite live required check(s) not in checks_for(): $extras_list"
    elif [ "$CHECK_MODE" -eq 1 ]; then
      echo "!! DRIFT: $repo: live required check(s) not declared in checks_for() — would be DROPPED by the next PUT: $extras_list"
      DRIFT=1
      continue
    else
      echo "!! DRIFT: $repo: live required check(s) not declared in checks_for() — would be DROPPED by the next PUT: $extras_list (use --allow-check-removal to override)" >&2
      exit 1
    fi
  else
    echo "   $repo: required checks in sync (nothing live would be dropped)"
  fi

  if [ "$CHECK_MODE" -eq 1 ]; then
    continue
  fi

  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge="$auto_merge" -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"'

  printf '%s' "$protection_json" | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq 'if .required_status_checks then "  required checks: \(.required_status_checks.contexts | join(", "))" else "  required checks: (none — protection-only)" end'
done

if [ "$CHECK_MODE" -eq 1 ]; then
  if [ "$DRIFT" -ne 0 ] || [ "$ERRORS" -ne 0 ]; then
    echo "--check: drift and/or unreadable repos found (see '!!' lines above)."
    exit 1
  fi
  echo "--check: all repos in sync, nothing would be dropped."
  exit 0
fi

echo "done."
