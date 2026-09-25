# dotgithub: prerequisite warning on the auto-merge workflow template

**Status: historical record, not a live task.** The target repo is
`agentcontextdistributionprotocol/.github` (its own filename can't start with a literal
`.`, hence this file's `dotgithub` name — every in-repo reference below is corrected to
the real slug). The issue this file was written for,
`agentcontextdistributionprotocol/.github#4`, is closed (2026-08-30); confirmed the
prerequisite warning already exists in `.github/workflow-templates/auto-merge.yml` on
`main`. Kept as the sweep record, per the same convention as
`plans/cross-repo/acdp-control-plane-dealias-acdp.md`.

Written from `acdp-ci` as part of
`plans/ci-wave-t4t5-provenance-npm-alias-automerge-scoping.md` (Phase 3, CI-6).
This repo (`acdp-ci`) never edits `.github` directly — this file is the tracked
plan; a GitHub issue in `agentcontextdistributionprotocol/.github` links here.

## Why

`.github/workflow-templates/auto-merge.yml` is a one-click-adoptable GitHub
repository-template workflow that calls
`agentcontextdistributionprotocol/acdp-ci/.github/workflows/auto-merge.yml@v1`.
As of the referencing PR, that reusable workflow gained a hard guard (its own
Phase 3) that refuses to arm auto-merge when the calling repo's base branch has
no required status checks configured — so the **actual** defense against an
ungated instant-merge now lives in the reusable workflow itself, not in anything
a human reads before clicking "Use this template."

This file's scope is narrower and secondary: a header-comment warning so a human
adopting the template via GitHub's UI sees the prerequisite *before* first use,
rather than discovering it only when their first Dependabot PR's auto-merge run
goes red with the new guard's error. This is a nice-to-have, not the safety net —
don't treat landing this as closing the actual risk; `acdp-ci`'s own Phase 3 does
that regardless of whether this template is ever touched.

## Delivers

- `workflow-templates/auto-merge.yml` — a comment block at the top of the file
  stating: "Prerequisite: this repo's default branch must have branch protection
  with at least one required status check configured *before* adopting this
  workflow — GitHub's native auto-merge completes immediately with no gate on an
  unprotected branch. Run `acdp-ci`'s `scripts/standardize.sh <this-repo>` first
  (see agentcontextdistributionprotocol/acdp-ci/DELIVERY-STANDARD.md)."
- `workflow-templates/auto-merge.properties.json` — extend the `description`
  field (currently a one-line summary, see `:3`) with the same prerequisite,
  since that's the text GitHub surfaces in the template picker UI *before* a user
  ever opens the YAML.

## Depends on

`agentcontextdistributionprotocol/acdp-ci` Phase 3 (the reusable workflow's own
guard) landing first — not a hard technical dependency (this header change is
independent text), but the warning should describe the guard's actual behavior
accurately, so write this only after Phase 3's exact error message/remedy text is
final and merged.

## Files

- `.github/workflow-templates/auto-merge.yml`
- `.github/workflow-templates/auto-merge.properties.json`

## Approach

Text-only change, no workflow logic in `.github` itself (this repo never runs
the reusable workflow — it only hosts the template that other repos copy from).
Match the wording to whatever `acdp-ci/.github/workflows/auto-merge.yml`'s guard
step actually prints in its `::error::` message, so a user who ignores the header
and finds out the hard way sees consistent language.

## Acceptance criteria

- [ ] The template's header comment states the branch-protection prerequisite and
      names `scripts/standardize.sh` as the remedy.
- [ ] `auto-merge.properties.json`'s `description` field states the same
      prerequisite in one sentence.
- [ ] No change to `workflow-templates/bump-acdp.yml` or `bump-spec.yml` (out of
      scope — those don't auto-merge unattended the same way; `bump-consume.yml`
      already holds majors, per `DELIVERY-STANDARD.md`'s Merge policy).

## Tests

N/A — comment/description text only, no executable change.
