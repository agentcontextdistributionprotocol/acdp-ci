#!/usr/bin/env bash
# Handoff: move the acdp-ci `v1` tag to current origin/main      Authored by: Claude   Date: 2026-10-05
# Why a human runs this: `v1` is consumed by ~9 repos' workflows (`uses: …/acdp-ci/...@v1`); moving it
#   ships everything since 0159101 to all of them at once, and cannot be un-run for jobs already started.
# Run:  scripts/handoff/2026-10-05-move-v1.sh            (dry-run, read-only)
#       scripts/handoff/2026-10-05-move-v1.sh --apply    (moves the tag; asks you to type the target)
# Prerequisite: PRs #34-#39 merged into main (the script refuses otherwise).
# Mirrors DELIVERY-STANDARD.md "v1 release" runbook: fast-forward only, annotated tag, one explicit refspec.
HANDOFF_TARGET="prod:acdp-ci-v1"
source "$(dirname "$0")/lib.sh"

REPO=agentcontextdistributionprotocol/acdp-ci
OLD_TAG_OBJ=$(git ls-remote --tags origin | awk '$2=="refs/tags/v1"{print $1}')
OLD_COMMIT=$(git ls-remote --tags origin | awk '$2=="refs/tags/v1^{}"{print $1}')
[ -n "$OLD_TAG_OBJ" ] && [ -n "$OLD_COMMIT" ] || { echo "cannot read current v1 (tag object/peeled commit) — STOP" >&2; exit 1; }
git fetch -q origin main
NEW_SHA=$(git rev-parse origin/main)

handoff_begin "move v1 ${OLD_COMMIT:0:7} -> ${NEW_SHA:0:7}" \
  "git push origin \"+${OLD_TAG_OBJ}:refs/tags/v1\"   # restores tag object ${OLD_TAG_OBJ} (needs tag-ruleset bypass if active)"
say "   rollback anchor: tag object $OLD_TAG_OBJ, commit $OLD_COMMIT  (paste into the PR thread)"
say "   ships:"; git log --oneline "$OLD_COMMIT..$NEW_SHA" | tee -a "$LOG"

is_ff()          { git merge-base --is-ancestor "$OLD_COMMIT" "$NEW_SHA"; }
has_file()       { git cat-file -e "$NEW_SHA:$1"; }
prs_merged()     { for n in 34 35 36 37 38 39; do [ "$(gh pr view "$n" --repo "$REPO" --json state -q .state)" = MERGED ] || { echo "PR #$n not merged"; return 1; }; done; }
move_tag()       { git tag -f -a v1 -m "acdp-ci v1" "$NEW_SHA" && git push origin refs/tags/v1 --force; }
peeled_is_new()  { [ "$(git ls-remote --tags origin | awk '$2=="refs/tags/v1^{}"{print $1}')" = "$NEW_SHA" ]; }

verify "all sweep PRs (#34-#39) are merged" prs_merged
verify "new tip is a fast-forward of the current v1" is_ff
verify "new tip carries actions/npm-relock/action.yml" has_file actions/npm-relock/action.yml
verify "new tip carries actions/auto-merge-gate/action.yml" has_file actions/auto-merge-gate/action.yml
verify "new tip carries the reusable workflows" has_file .github/workflows/bump-consume.yml
step   "move v1 (annotated, single-ref force push)" move_tag
if [ "$HANDOFF_APPLY" = 1 ]; then verify "v1's peeled commit is now $NEW_SHA" peeled_is_new; fi
say "   smoke (manual, after apply): dispatch one consumer (e.g. a bump workflow) and confirm @v1 resolves."
handoff_done
