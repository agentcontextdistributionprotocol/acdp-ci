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
