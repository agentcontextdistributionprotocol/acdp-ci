#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every acdp-* repo.
#
# Idempotent. For each repo it: turns on squash + delete-branch-on-merge, and sets
# branch protection on the default branch with that repo's CI jobs as REQUIRED
# status checks (so auto-merge has something to wait on). Required-check names are
# per-repo (they must match each repo's real check-run names exactly) — declared in
# checks_for() below, verified against actual check-runs so a required check can
# never hang a PR. "Allow auto-merge" is enabled only for repos that have at least
# one required check — see the protection-only branch below.
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
# convenience, on a zero-check repo (CI-6, Wave 4, is chartered to fix this
# properly). Both repos are allow_auto_merge:false on GitHub today, so leaving
# auto-merge off here codifies the status quo rather than changing behaviour.
#
# Prereqs: gh auth with admin:org. Org secrets (App id/key) are set separately.
# Usage: ./standardize.sh [repo ...]   (default: all repos below)
set -euo pipefail

ORG=agentcontextdistributionprotocol
# Word-split unquoted below (`for repo in $repos`) under default globbing — every
# name here must stay free of whitespace and glob metacharacters. `.github`'s
# leading dot is not one (no unquoted glob expands it), but this is a property of
# the specific names, not something the script enforces.
ALL_REPOS="acdp-control-plane acdp-registry-rs acdp-playground acdp-verifier-py acdp-ui-console agentcontextdistributionprotocol acdp-ci .github"

# Emits one required check-name per line for the given repo (non-zero if unknown).
# A repo may legitimately have zero required checks: printing nothing and
# returning 0 means "protection-only, no required checks" — distinct from
# returning 1, which means "not in the managed set at all, skip entirely".
checks_for() {
  case "$1" in
    acdp-control-plane)
      printf '%s\n' "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)" ;;
    acdp-registry-rs)
      printf '%s\n' "rustfmt" "clippy" "tests" ;;
    acdp-playground)
      printf '%s\n' "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" ;;
    acdp-verifier-py)
      printf '%s\n' "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" ;;
    acdp-ui-console)
      printf '%s\n' "Lint · Typecheck · Test · Build" ;;
    agentcontextdistributionprotocol)  # the spec/RFC repo
      printf '%s\n' "All Validations Passed" "Validate Schemas, Examples, and Conformance" ;;
    acdp-ci|.github)  # protection-only — see header comment
      return 0 ;;
    *) return 1 ;;
  esac
}

if [ "$#" -gt 0 ]; then repos="$*"; else repos="$ALL_REPOS"; fi

for repo in $repos; do
  if ! lines=$(checks_for "$repo"); then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"; continue
  fi
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch)
  echo "== $repo (@$branch) =="

  if [ -z "$lines" ]; then
    # Protection-only: no required checks to gate on, so no auto-merge either
    # (see "Protection-only" in the header comment above).
    auto_merge=false
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

  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge="$auto_merge" -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"'

  printf '%s' "$protection_json" | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq 'if .required_status_checks then "  required checks: \(.required_status_checks.contexts | join(", "))" else "  required checks: (none — protection-only)" end'
done
echo "done."
