# Cross-repo note: the push-only release-dispatch gate in acdp-rs is already tracked

**Owning repo:** `agentcontextdistributionprotocol/acdp-rs` (this note is written and
tracked in `acdp-ci`, per that repo's cross-repo convention — see
`acdp-ci/DELIVERY-STANDARD.md`'s propagation-graph section for the doc-side context, and
`acdp-ci/plans/registry-rs-drift-and-doc-sync.md` Phase 4 for how this was found).

## Why

This started as a plan to hand `acdp-rs` a fresh issue for a dispatch gate this session
found independently. Verification turned up that both halves of the gap are **already
filed and open** in `acdp-rs`, one of them with a materially better fix than the naive one
this session first drafted. This file exists to point at that existing work accurately,
correct one gap in it, and stop `acdp-ci`'s own docs from implying the problem is
untracked. It does **not** propose a fix of its own — `acdp-rs#302`'s linked plan already
is one, and is more careful than what this session would have written.

## Delivers

`acdp-ci/DELIVERY-STANDARD.md` cites the real, already-open tracking issues instead of
implying this gap is unhandled. Whoever next touches `acdp-rs#304` (or reads this file)
knows its suggested fix is incomplete in the same way `acdp-rs#302`'s *was*, before that
issue's own linked plan fixed it.

## Depends on

Nothing in `acdp-ci`. Nothing to implement here at all — this repo makes no code change
in `acdp-rs`.

## Files

- `agentcontextdistributionprotocol/acdp-rs#304` — open issue, PyPI/uv half
  (`acdp-py-release.yml`). Not touched by this note; described below.
- `agentcontextdistributionprotocol/acdp-rs#302` — open issue, npm half
  (`bindings-release.yml`). Not touched by this note; described below.
- `agentcontextdistributionprotocol/acdp-control-plane/plans/cross-repo/acdp-rs-bump-dispatch-fix.md`
  — the actual fix plan for the `#302` half, already written. **The link `#302` itself
  gives for this file 404s** — confirmed via `gh api .../acdp-control-plane/contents/plans/...`
  (Not Found) and a full recursive tree of that repo's `main` (no `plans/` path at all).
  Cause: `acdp-control-plane/.gitignore` still has the bare `plans/` pattern — the exact
  bug this PR fixed in `acdp-ci`'s own `.gitignore` (`plans/` → `plans/*` +
  `!plans/cross-repo/`). The file exists uncommitted on the local checkout at
  `../acdp-control-plane/plans/cross-repo/acdp-rs-bump-dispatch-fix.md` in this workspace,
  which is how its content below was actually read — not the dead URL. This is a real gap
  in `#302`, owned by `acdp-control-plane`/`acdp-rs`, not something this note fixes; noted
  here so whoever next reads `#302` doesn't burn time on a 404 the way this session almost
  did.

## Approach

**The root cause, precisely.** `acdp-rs/.github/workflows/release-plz.yml:129-138` is the
*standard* release path — every real release fires `bindings-release.yml`,
`acdp-py-release.yml`, and `acdp-wasm-release.yml` via
`gh workflow run "$wf" --ref main -f version="$VER" -f dry_run=false`, i.e.
`workflow_dispatch`, not a tag `push`. Both `bindings-release.yml`
(`:238-239` mint, `:246-247` dispatch) and `acdp-py-release.yml` (`:209` mint, `:217`
dispatch) gate their `acdp-released` notification on `if: ${{ github.event_name ==
'push' }}` alone — so the notification is skipped **by construction** on every
release-plz-driven release, which is not an edge case, it is the normal case. This is
what let `acdp-control-plane` (npm) sit pinned at `^0.8.5` while npm carried `0.14.1`,
and `acdp-playground` (PyPI) fall from `0.8.3` to needing a hand-catch-up to `0.14.1`
(eight releases missed since `0.10.0`, per `acdp-rs#304`'s own `gh run list` evidence).

**Both halves are already open issues, filed 2026-09-23/24, independently of this
session:**

- **`acdp-rs#302`** (npm/bindings-release.yml) is the more rigorous of the two. It
  identifies a second, compounding bug this session's own first draft of this file
  missed: `bindings-release.yml:250-253` derives the dispatched version from
  `github.ref_name`, which on `workflow_dispatch --ref main` is the literal string
  `"main"` — so naively widening the `if:` to also match `workflow_dispatch` would
  dispatch `{"version":"main"}` instead of silently skipping, a *worse* failure than
  today's. `#302` links a full plan,
  `acdp-control-plane/plans/cross-repo/acdp-rs-bump-dispatch-fix.md`, that fixes this
  correctly: derive `VER` from `inputs.version` when present and the tag suffix
  otherwise, reject anything that isn't plain semver, *then* widen the `if:` to the
  predicate the workflow's own publish step already uses
  (`${{ always() && (github.event_name == 'push' || !inputs.dry_run) }}`), and move the
  dispatch after the tag-creation step. That plan's *content* is complete and needs no
  addition here — but the URL `#302` links to it is currently dead (see `## Files`
  above); whoever picks up `#302` should also fix that before relying on the issue alone
  to hand it off.

- **`acdp-rs#304`** (PyPI/acdp-py-release.yml) does **not** carry the same care.
  Its "Suggested fix" is "drop the `github.event_name == 'push'` guard (or broaden it) …
  so the dispatch fires regardless of how the release run was triggered" — with no mention
  of version derivation. But `acdp-py-release.yml:217-222` has the *identical* hazard:
  ```yaml
  env:
    REF: ${{ github.ref_name }}
  run: |
    VER="${REF#acdp-py-v}"
  ```
  On `workflow_dispatch --ref main` this yields `VER="main"` exactly as in the
  `bindings-release.yml` case — applying `#304`'s suggested fix as written would dispatch
  `{"version":"main"}` to `acdp-playground` the first time a release-plz release actually
  exercises the widened gate. **This is the one concrete gap this note has to flag**:
  whoever picks up `#304` should apply the same trigger-aware-`VER`-then-widen-then-reorder
  pattern `#302`'s linked plan uses for `bindings-release.yml`, not the issue's own
  as-written suggestion.

**Also worth correcting:** this session's plan originally speculated `acdp-control-plane`
might have been "likely silently protected" from the gate by its Dependabot `acdp-sdk`
group. `#302` shows that's wrong, not just unverified — `acdp-control-plane` was
confirmed stuck at `^0.8.5` while npm carried `0.14.1`, i.e. the Dependabot group did
*not* catch it in practice (both `acdp-control-plane`'s own `PROGRESS.md` and `#302`'s
body confirm the bump was ultimately done by hand, because the version range crosses a
breaking API change no automated PR could resolve regardless).

**No new issue is filed by this note.** Filing one for either half would duplicate
`#302`/`#304`. The one action worth considering — leaving a comment on `#304` pointing out
the version-derivation hazard `#302` already found for the sibling workflow — is itself a
cross-repo write into `acdp-rs` and is called out separately for an explicit go/no-go; it
is not part of this file's own deliverable.

## Acceptance criteria

1. `DELIVERY-STANDARD.md`'s propagation-graph section names `release-plz.yml` as the
   actual release trigger (not `workflow_dispatch` in the abstract), and cites
   `acdp-rs#302` and `acdp-rs#304` as the existing tracking issues.
2. This file accurately describes both issues' current state and does not recommend
   `#304`'s literal suggested fix without the version-derivation caveat.
3. No file under `acdp-rs/`, `acdp-playground/`, or `acdp-control-plane/` is modified.
4. No new GitHub issue is filed by this plan.

## Tests

None — this is a documentation/handoff correction, not executable code. The fix itself,
whenever `#302`/`#304` are picked up, is verified by that work's own acceptance criteria
(already written into `#302`'s linked plan).
