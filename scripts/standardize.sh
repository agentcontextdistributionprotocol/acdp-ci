#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every acdp-* repo.
#
# Idempotent. For each repo it: enables "Allow auto-merge", turns on squash +
# delete-branch-on-merge, and sets branch protection on the default branch with
# that repo's CI jobs as REQUIRED status checks (so auto-merge has something to
# wait on). Required-check names are per-repo (they must match each repo's real
# check-run names exactly) — declared in checks_for() below, verified against
# actual check-runs so a required check can never hang a PR.
#
# Portable to macOS's stock bash 3.2 (no associative arrays).
#
# Excluded on purpose:
#   acdp-rs      — already protected with its own (richer) config; do not clobber.
#   acdp-website — private repo; branch protection needs GitHub Pro or public.
#
# Prereqs: gh auth with admin:org. Org secrets (App id/key) are set separately.
# Usage: ./standardize.sh [repo ...]   (default: all repos below)
set -euo pipefail

ORG=agentcontextdistributionprotocol
ALL_REPOS="acdp-control-plane acdp-registry-rs acdp-playground acdp-verifier-py acdp-ui-console agentcontextdistributionprotocol"

# Emits one required check-name per line for the given repo (non-zero if unknown).
checks_for() {
  case "$1" in
    acdp-control-plane)
      # NB: matches main's COMMITTED ci.yml. An in-flight working-tree ci.yml
      # renames these to "lint + tsc + jest (unit, coverage-gated)" and adds
      # "docker build (no push)" — update here when that lands on main.
      printf '%s\n' "tsc + jest (unit)" "jest integration (Postgres)" ;;
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
    *) return 1 ;;
  esac
}

if [ "$#" -gt 0 ]; then repos="$*"; else repos="$ALL_REPOS"; fi

for repo in $repos; do
  if ! lines=$(checks_for "$repo"); then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"; continue
  fi
  contexts_json=$(printf '%s' "$lines" | jq -R . | jq -sc .)
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch)
  echo "== $repo (@$branch) =="

  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge=true -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"'

  jq -nc --argjson ctx "$contexts_json" '{
    required_status_checks: { strict: true, contexts: $ctx },
    enforce_admins: false,
    required_pull_request_reviews: null,
    restrictions: null
  }' | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq '"  required checks: \(.required_status_checks.contexts | join(", "))"'
done
echo "done."
