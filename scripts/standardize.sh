#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every acdp-* repo.
#
# Idempotent. For each repo it: enables "Allow auto-merge", turns on squash +
# delete-branch-on-merge, and sets branch protection on the default branch with
# that repo's CI jobs as REQUIRED status checks (so auto-merge has something to
# wait on). Required-check names are per-repo (they must match each ci.yml's job
# `name:` exactly) — declared in CHECKS below.
#
# Prereqs: `gh auth login` as an org admin. Org secrets (App id/key) are set
# once, separately, and are NOT touched here.
#
# Usage: ./standardize.sh [repo ...]   (default: all repos in CHECKS)
set -euo pipefail

ORG=agentcontextdistributionprotocol

# repo -> newline-separated required check (job display) names.
declare -A CHECKS=(
  [acdp-control-plane]=$'lint + tsc + jest (unit, coverage-gated)\njest integration (Postgres)\ndocker build (no push)'
  # Fill the rest from each repo's ci.yml job names before first run:
  [acdp-rs]=$'TODO-ci-job-name'
  [acdp-registry-rs]=$'TODO-ci-job-name'
  [acdp-playground]=$'TODO-ci-job-name'
  [acdp-verifier-py]=$'TODO-ci-job-name'
  [acdp-ui-console]=$'TODO-ci-job-name'
  [acdp-website]=$'TODO-ci-job-name'
)

repos=("${@:-${!CHECKS[@]}}")

for repo in "${repos[@]}"; do
  contexts_json=$(printf '%s\n' "${CHECKS[$repo]}" | jq -R . | jq -sc .)
  if printf '%s' "$contexts_json" | grep -q 'TODO'; then
    echo "!! $repo: required checks not filled in yet — skipping branch protection"; continue
  fi
  branch=$(gh api "repos/$ORG/$repo" --jq .default_branch)
  echo "== $repo (@$branch) =="

  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge=true -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge)"'

  jq -nc --argjson ctx "$contexts_json" '{
    required_status_checks: { strict: true, contexts: $ctx },
    enforce_admins: false,
    required_pull_request_reviews: null,
    restrictions: null
  }' | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq '"  required checks: \(.required_status_checks.contexts | join(", "))"'
done
echo "done."
