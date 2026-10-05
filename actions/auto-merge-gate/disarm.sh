#!/usr/bin/env bash
# disarm.sh — if auto-merge is already armed on this PR (a previous run, before
# a rebase/regroup made it hold), turn it off. Only called for deny-list holds,
# never for the historical major hold (a human may have armed a major on purpose).
# Env: PR_URL, GH_TOKEN
set -euo pipefail
: "${PR_URL:?PR_URL is required}"
armed="$(gh pr view "$PR_URL" --json autoMergeRequest --jq '.autoMergeRequest != null')"
if [ "$armed" = "true" ]; then
  gh pr merge --disable-auto "$PR_URL"
  echo "auto-merge disarmed on $PR_URL (held by a deny list)"
else
  echo "auto-merge was not armed on $PR_URL; nothing to disarm"
fi
