# `scripts/handoff/`

Human-run scripts for steps an agent should not execute itself (sensitive, irreversible, or
affecting every consumer at once). Each script is **dry-run by default**, takes `--apply`
to act, and — when it sets `HANDOFF_TARGET` — makes the operator type that target to
confirm. Every step is logged under `~/.cache/seam/handoff/`.

| File | Purpose |
|---|---|
| [`lib.sh`](lib.sh) | Shared helpers (`handoff_begin`, `step`, `verify`, `handoff_done`). Copied from the `seam` repo's `scripts/handoff/lib.sh`, which is why its log directory (`~/.cache/seam/`) and its header refer to `seam` (its `docs/delivery/10-agent-standing-rules.md`); the optional `preflight.sh` hook is absent here. There is no `_template.sh` in this repo. |
| [`2026-10-05-move-v1.sh`](2026-10-05-move-v1.sh) | Fast-forward the annotated `v1` tag to `origin/main`. **Already executed** (the `v1` tag was moved to `main` at the time; later commits follow the normal `v1` release runbook; its "PRs #34–#39 merged" prerequisite is historical). Kept as the worked example of the contract. |

The `v1` move itself is specified by the *Releasing acdp-ci (the `v1` tag)* section of
[DELIVERY-STANDARD.md](../../DELIVERY-STANDARD.md#releasing-acdp-ci-the-v1-tag); the script
mirrors that runbook (fast-forward only, annotated tag, one explicit refspec) and targets
`origin/main`.

Writing a new handoff: copy the shape of `2026-10-05-move-v1.sh` — set `HANDOFF_TARGET`,
source `lib.sh`, state the rollback in `handoff_begin`, make every `step` idempotent, put
read-only checks in `verify`.
