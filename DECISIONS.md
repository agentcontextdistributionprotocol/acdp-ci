# DECISIONS

Durable record of `/reconcile` checkpoints. Each entry: the original assumption, the
recommending agent's analysis, the human's verdict, and the resulting status.

## 2026-08-28 — Composite action path: `actions/checkout-spec/`

- **Assumption:** `actions/checkout-spec/` (repo root), not `.github/actions/checkout-spec/`.
- **Recommendation (Opus subagent):** confirm as-is. `.github/actions/` signals
  "internal to this repo's own workflows"; this repo has zero such directory and zero
  internal consumers. Root `actions/<name>/` is the correct layout for a
  cross-repo-published action, and it's already load-bearing: `bump-spec-ref.yml`'s
  detector/rewriter hardcode the literal `acdp-ci/actions/checkout-spec@` string.
  Adjacent findings (not path-related): `v1` currently predates the action (expected —
  the tag move is CI-1's human-assisted deliverable) and `.github/dependabot.yml` didn't
  watch the new action's own directory (addressed below, same session).
- **Verdict:** confirmed as-is.
- **Status:** CONFIRMED. No code change.

## 2026-08-28 — `require-conformance` input default: `true`

- **Assumption:** default `true` (exports `ACDP_REQUIRE_CONFORMANCE=1`).
- **Recommendation (Opus subagent):** confirm as-is. The var only exports when a caller
  deliberately adopts `checkout-spec`, so a caller with a legitimate reason to skip
  conformance checks (e.g. a unit-only CI leg) opts out simply by not adopting the
  action — not via an input — which removes the main argument for defaulting `false`.
  Flagged two corrections: (1) the original rationale overstated `acdp-registry-rs` as
  a repo this default "fixes" — its `conformance.rs` reads only `ACDP_SPEC_DIR`, not
  `ACDP_REQUIRE_CONFORMANCE`, so REG-1 still needs its own harness change; `acdp-rs` and
  `acdp-control-plane` are the repos that actually already honor the var. (2) A latent
  trap: `set-env: false` + `require-conformance: true` (default) would export
  `ACDP_REQUIRE_CONFORMANCE=1` without `ACDP_SPEC_DIR` — a combination `acdp-rs`'s test
  suite treats as a hard failure.
- **Verdict:** confirmed as-is on the default; both corrections accepted as follow-ups
  to fix in this same PR rather than deferred.
- **Status:** CONFIRMED. `ASSUMPTIONS.md`'s rationale corrected in place. Follow-ups:

## 2026-08-28 — Follow-up: guard the `set-env:false` + `require-conformance:true` trap

- **Finding:** surfaced during the reconcile pass above, not a pre-logged assumption.
- **Verdict:** fix now, this PR.
- **Change:** `actions/checkout-spec/action.yml`'s "Verify and export" step now checks
  `require-conformance == true && set-env != true` before exporting anything, and exits
  1 with a `::error::` explaining why, instead of silently producing the broken
  combination. Documented in the action's README inputs table.
- **Status:** DONE. Verified via a 4-case local harness (default/trap/both-off/
  set-env-only) — the trap case is the only one that fails, all three legitimate
  combinations pass through unaffected.

## 2026-08-28 — Follow-up: Dependabot doesn't cover `actions/checkout-spec/`

- **Finding:** surfaced during the reconcile pass above, not a pre-logged assumption.
  `.github/dependabot.yml`'s single `github-actions` entry only scans the repo root
  (`.github/workflows/` + a root `action.yml`, neither of which exist at that path for
  this action), leaving `actions/checkout-spec/action.yml`'s own `actions/checkout@v4`
  pin unmonitored.
- **Verdict:** fix now, this PR.
- **Change:** added a second `github-actions` update entry to `.github/dependabot.yml`
  with `directory: /actions/checkout-spec`, same weekly schedule and grouping as the
  existing entry.
- **Status:** DONE. YAML validated; two update entries confirmed present.

## 2026-08-29 — `acdp-website` will permanently fail Phase 3's (CI-6) auto-merge guard

- **Finding:** surfaced during the plan-review round for
  `plans/ci-wave-t4t5-provenance-npm-alias-automerge-scoping.md`, not a
  pre-logged assumption. `acdp-website` is a live caller of `auto-merge.yml`
  but is structurally excluded from `standardize.sh`'s managed branch
  protection (private repo; branch protection needs GitHub Pro), so the new
  required-checks guard (Phase 3) will permanently red-fail its Dependabot
  auto-merge runs, not just "until adoption completes" like other repos.
- **Options posed:** (1) ship the guard anyway, accepting the behavior change;
  (2) ship the guard and file a tracked issue in `acdp-website` flagging it;
  (3) hold Phase 3 out of this PR until `acdp-website`'s situation is resolved.
- **Verdict:** ship the guard anyway (option 1). No follow-up issue filed.
- **Status:** CONFIRMED. Phase 3 proceeds as designed; `acdp-website`'s
  Dependabot PRs will show a red auto-merge job the next time one runs, with
  no advance notice beyond this record.

## 2026-08-29 — CI-4's acceptance bar: document + track, don't block on cross-repo fix

- **Assumption:** treat the local acceptance criterion as "the rule is
  documented, and the sweep's findings — including violations — are recorded
  and tracked," not "zero violations exist post-merge."
- **Recommendation (Opus subagent):** confirm as-is. Verified against live
  state (not just the plan's description of it): the alias is still present
  at `acdp-control-plane/package.json:35`, issue #123 is open and correctly
  linked both directions, `plans/cross-repo/acdp-control-plane-dealias-acdp.md`
  has concrete, checkable acceptance criteria a future agent could execute
  without re-deriving context, and `DELIVERY-STANDARD.md`'s new rule already
  states the violation is tracked-not-fixed rather than overclaiming
  compliance. Holding the PR would block CI-3/CI-6/CI-7 on an unrelated repo's
  source refactor for no compensating benefit. Flagged two real, separate
  defects: (1) `DELIVERY-STANDARD.md:227`'s "All current repos meet this
  baseline" contradicted the new rule's own finding; (2) issue #123's links
  are pinned to the feature branch and will 404 once it's deleted post-merge.
- **Verdict:** confirm as-is; fix both flagged defects now/at-merge rather
  than deferring either.
- **Status:** CONFIRMED. `DELIVERY-STANDARD.md:227` reworded in this PR to
  name `acdp-control-plane` as the one tracked exception, citing #123.
  Follow-up (not blocking): repoint issue #123's blob-URL links from this
  feature branch to `main` immediately after this PR merges.

## 2026-09-05 — `checkout-spec` action pinning: SHA mandated, not merely recommended

**Plan:** plans/ci-wave5-standardize-drift-and-protection-apply.md
**Raised by:** the `acdp-verifier-py` session (acdp-ci#12), after adopting the action
SHA-pinned with a `# v1` comment rather than `@v1`, and asking for a ruling.

**Original assumption (Phase 3):** SHA-pinning recommended; `@v1` remains permitted.

**Opus recommendation:** change it — mandate the single SHA shape, drop the "@v1 permitted"
half. Decisive point: the alternative had been rejected for "needlessly breaking existing
`@v1` adopters", and **there are none**. Only `acdp-verifier-py` references `checkout-spec`
at all (verified across all 8 managed repos on `origin/main`), and it is already SHA-pinned —
so mandating costs zero migrations and makes the sole adopter conforming rather than deviant.
Second point: the dual shape was silently biased toward `@v1` — "recommended" appeared in one
prose paragraph while four copy-paste sites still showed `@v1`, so adopters 2-9 would have
landed on `@v1` and inverted the ruling in practice. Tooling can enforce a mandate; it cannot
enforce a preference.

**Verdict: CHANGE — mandate SHA + `# v1`.** Applied: the ruling, and every copy-paste site
(`DELIVERY-STANDARD.md` prose + adoption snippet, `README.md` snippet + conventions line, and
`actions/checkout-spec/README.md`, which the recommender's own list missed). `grep -rn
"checkout-spec@v1"` now returns zero hits repo-wide.

**Rejected from the recommendation:** its claim that "acdp-ci SHA-pins nothing" and that the
doc's third-party/`actions/*` risk-grading analogy is therefore unfounded. Verified false —
`dependabot/fetch-metadata@25dd0e34…` IS SHA-pinned (third-party) and every tag-pinned action
is `actions/*`. The convention IS followed; that sentence stays.

**Also noted, not adopted:** the recommender's own strongest counterargument — that
`bump-consume.yml@v1` and `bump-spec-ref.yml@v1` are far MORE privileged (they mint an App
token with write access) yet stay on the mutable tag, so SHA-pinning only the credential-free
action is not a coherent whole-family posture. That asymmetry is real and is now a deliberate
open question for a later wave, not an oversight.

**Status:** CONFIRMED (2026-09-05).

## 2026-09-05 — `enforce_admins: true` on the protection-only repos

**Plan:** plans/ci-wave5-standardize-drift-and-protection-apply.md
**Origin:** wave-1 Open Question 1 proposed `false` "pending confirmation — log as
UNCONFIRMED"; it was never logged and never resolved. This wave logged it, and the post-merge
CI-5a runbook was about to bake it in permanently.

**Original assumption:** keep `false` (status quo, zero behaviour change).

**Opus recommendation:** change to `true`, scoped to the protection-only body only. The
friction the assumption feared does not exist here: `acdp-ci` and `.github` have no required
checks and no required reviews, so the usual `enforce_admins:true` pain (blocked on your own
CI, cannot self-merge) is nil. It blocks exactly two operations — force-push `main`, delete
`main` — neither of which appears in any documented workflow. The escape hatch is intact
(disabling protection is a repo-admin op, already written as CI-5a's inverse). Decisive
asymmetry: if admins CAN force-push under `false`, `true` closes a real gap at zero cost; if
they cannot, `true` is a harmless no-op that makes the intent explicit — whereas `false`
leaves the stated rationale half-true and undetectable.

**Verdict: CHANGE — `enforce_admins: true`, protection-only repos ONLY.** The six
code-shipping repos keep `false`, because they DO have required checks and `true` there would
block the maintainer on their own CI — real friction, unlike here. Applied in
`scripts/standardize.sh`'s protection-only body, not the has-checks body.

**Riders applied at the recommender's suggestion:** `allow_force_pushes:false` and
`allow_deletions:false` are now asserted explicitly in BOTH protection bodies, rather than
relying on undocumented PUT defaults — CI-5a step 4 already *verified* those fields, so the
script should *set* them.

**Known gap, deliberately documented rather than fixed:** `enforce_admins` is outside the
drift guard, which compares `contexts` only — so a future edit could silently revert it. That
is the same unguarded-control pattern this wave exists to fix, and it is named in the script
header as a wave-6 item ("extend the guard to the full protection object"). The recommender
raised this as its own strongest counterargument; it is accepted as a real cost of acting now
rather than a reason not to.

**Status:** CONFIRMED (2026-09-05).

## 2026-09-05 — SUPERSEDES the 2026-08-29 `acdp-website` decision

The 2026-08-29 entry ("`acdp-website` will permanently fail Phase 3's auto-merge guard")
recorded the verdict "ship the guard anyway (option 1). **No follow-up issue filed.**"

That is now superseded. What changed: the guard went live at `@v1` and began producing
recurring red CI on every minor/patch Dependabot PR (run 33492428175; PR #36 stuck open) —
new information not available when the original decision was made. Put to the maintainer with
four options; verdict: **drop the auto-merge caller**, over a GitHub Pro upgrade, making the
repo public, or adding an opt-out input to `acdp-ci` (that last explicitly rejected, since it
would weaken a security control across all 8 callers to unblock one structurally-excluded
repo).

Filed as `acdp-website#39`. Also verified during this wave that the exclusion is permanent by
BOTH mechanisms, not just the one originally cited: the org is on the **free** plan, and
`GET /repos/…/acdp-website/rulesets` returns the same 403 as classic branch protection, so
rulesets are not a workaround.

**Status:** CONFIRMED (2026-09-05). The 2026-08-29 entry stands as the record of what was
decided then; this entry records what replaced it and why.
