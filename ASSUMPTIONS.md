# ASSUMPTIONS

## Composite action path: `actions/checkout-spec/`
- **Plan:** plans/ci-wave1-spec-pin-and-v1-protection.md
- **Assumed:** `actions/checkout-spec/` (repo root) is the right home, not
  `.github/actions/checkout-spec/`.
- **Chose:** repo root — `.github/actions/` conventionally holds actions for
  a repo's own internal use; this one is published for external (cross-repo)
  consumption, and `…/acdp-ci/actions/checkout-spec` (pinned per the wave-5
  SHA-pinning ruling) reads correctly as a public interface.
- **Alternatives:** `.github/actions/checkout-spec/` — rejected, wrong
  connotation for a published cross-repo primitive.
- **Blast radius if wrong:** cheap to reverse *now* — nothing has adopted it
  yet. Becomes a coordinated multi-repo change (PY-2, REG-1 callers) plus a
  `v1` move once adopted.
- **Status:** CONFIRMED (2026-08-28) — see DECISIONS.md.

## `require-conformance` input default: `true`
- **Plan:** plans/ci-wave1-spec-pin-and-v1-protection.md
- **Assumed:** the action should default to exporting
  `ACDP_REQUIRE_CONFORMANCE=1`.
- **Chose:** default `true` — the var only fires when a caller deliberately
  adopts `checkout-spec`, so a unit-only CI leg that never checks out the
  spec is unaffected by the default either way; defaulting on makes the
  shared path fail-loud by construction for callers that *do* adopt it.
  It's inert where a repo doesn't read the var (verifier-py doesn't).
  **Correction (2026-08-28, caught at reconcile):** the original rationale
  above overstated `acdp-registry-rs` as an example this fixes —
  `crates/acdp-registry-server/tests/conformance.rs` reads only
  `ACDP_SPEC_DIR` and does not consume `ACDP_REQUIRE_CONFORMANCE` at all
  today, so REG-1 still needs its own harness change to benefit from this
  default. `acdp-rs` and `acdp-control-plane` *do* already honor the var
  (`std::env::var("ACDP_REQUIRE_CONFORMANCE").is_ok()` checks throughout
  `acdp-rs/tests/*.rs`; `acdp-control-plane/.github/workflows/ci.yml:52`),
  so the default is still correctly justified by those two, just not by the
  repo originally cited.
- **Alternatives:** default `false`, opt-in per caller — rejected, reproduces
  the silent-skip failure mode for any caller that forgets to opt in.
- **Blast radius if wrong:** cheap to reverse — a default on an unreleased
  (`v1` not yet moved) action input.
- **Also found at reconcile:** `set-env: false` + `require-conformance: true`
  (the default) exported `ACDP_REQUIRE_CONFORMANCE=1` without
  `ACDP_SPEC_DIR` — a combination `acdp-rs`'s own test suite treats as a
  hard failure. Fixed same-session: `action.yml`'s verify step now refuses
  that combination with a clear `::error::` before exporting anything.
- **Status:** CONFIRMED (2026-08-28) — see DECISIONS.md.

## CI-4's acceptance bar: "sweep confirms no violations" vs. "sweep documents violations found"
- **Plan:** plans/ci-wave-t4t5-provenance-npm-alias-automerge-scoping.md
- **Assumed:** the item's literal acceptance criterion — "a repo-sweep confirms
  no remaining aliased family deps" — can be read as requiring zero violations
  post-merge.
- **Chose:** treat the local (acdp-ci) acceptance bar as "the rule is
  documented, and the sweep's findings — including any violations — are
  recorded and tracked via an issue," not "zero violations exist." The sweep
  found one live violation (`acdp-control-plane/package.json:35`); fixing it
  requires renaming import sites across that repo's own source, a cross-repo
  code edit out of scope for an `acdp-ci`-only PR. Filed as
  `agentcontextdistributionprotocol/acdp-control-plane#123` plus
  `plans/cross-repo/acdp-control-plane-dealias-acdp.md` instead of silently
  redefining "pass" or blocking this PR on someone else's repo.
- **Alternatives:** hold this whole PR until `acdp-control-plane` de-aliases —
  rejected, makes an unrelated repo's migration a blocker for CI-3/CI-6/CI-7
  too, since this plan ships as one PR.
- **Blast radius if wrong:** low and one-directional — if the true intent was
  "block until zero violations," the fix is just holding the PR later; no code
  written under this assumption needs to change, only the merge timing.
- **Status:** CONFIRMED (2026-08-29) — see DECISIONS.md.

## `enforce_admins` on `acdp-ci` (protection-only repos)
- **Plan:** plans/ci-wave5-standardize-drift-and-protection-apply.md
- **Assumed:** Wave-1 Open Question 1 proposed defaulting `acdp-ci`'s branch
  protection to `enforce_admins: false`, "pending confirmation — log as
  UNCONFIRMED" — it was never logged and never resolved. The post-merge
  runbook now bakes this into the repo that backs the `v1` tag.
- **Chose:** `enforce_admins: true`, but **scoped to the protection-only
  body only** (`acdp-ci` and `.github` — the branch `checks_for()` returns
  empty for). The 6 code-shipping repos keep `enforce_admins: false`,
  unchanged, because they DO have required checks and `true` there would
  block the maintainer on their own CI. For the two protection-only repos
  there is no required-check friction to create, and `v1` is force-moved to
  wherever `main` points, so binding the maintainer's own force-push/deletion
  to the same rule closes a real gap at zero cost. Note: `enforce_admins` is
  NOT covered by the drift guard (which compares `required_status_checks.contexts`
  only) — a future edit could silently revert it with nothing to catch that;
  see `scripts/standardize.sh`'s Known-Gaps header (named as a wave-6 item).
- **Alternatives:** keep `false` — status quo, zero behaviour change, but
  leaves the maintainer's own accidental force-push/deletion on `main`
  unconstrained even though `v1` is force-moved to wherever `main` points.
  Rejected on reconcile.
- **Blast radius if wrong:** low — cheap to reverse, one field in one PUT.
- **Status:** CONFIRMED (2026-09-05) — see DECISIONS.md.

## `checkout-spec` action pinning convention: `@v1` vs. SHA
- **Plan:** plans/ci-wave5-standardize-drift-and-protection-apply.md
- **Assumed:** the spec-pinning rule as written conflates two independent
  pins: the spec `ref:` itself (a 40-hex SHA, never in question) and how a
  caller references the `checkout-spec` action (`@v1` vs. a full SHA). A peer
  repo adopted the action SHA-pinned with a `# v1` comment and asked for a
  ruling.
- **Chose:** SHA-pinning is **mandated**, with a trailing `# v1` comment kept
  for human readability (the comment does not drive Dependabot's
  recognition of the pin — Dependabot parses the `uses:` line itself
  regardless). `@v1` is no longer the documented shape for this action. This
  costs zero migrations: `acdp-verifier-py` is the only repo that has
  adopted the action at all, and it is already SHA-pinned. Full reasoning in
  DELIVERY-STANDARD.md's Spec propagation section.
- **Alternatives:** mandate `@v1` — rejected, binds every adopter to a
  deliberately mutable tag this same wave is building guardrails around.
  Recommend-but-permit both shapes — rejected on reconcile: it was
  originally rejected as "breaking existing `@v1` adopters," but no such
  adopters exist, so the dual shape only bought a silent bias toward `@v1`
  (four copy-paste sites showed `@v1`; "recommended" appeared once in
  prose).
- **Blast radius if wrong:** low — one line per adopter to reverse; affects
  an org-wide convention, so worth a human confirm.
- **Status:** CONFIRMED (2026-09-05) — see DECISIONS.md.
