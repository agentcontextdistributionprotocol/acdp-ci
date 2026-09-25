# acdp-control-plane: remove the remaining npm alias for `acdp`

Written from `acdp-ci` as part of
`plans/ci-wave-t4t5-provenance-npm-alias-automerge-scoping.md` (Phase 2, CI-4).
This repo (`acdp-ci`) never edits `acdp-control-plane` directly — this file is
the tracked plan; a GitHub issue in
`agentcontextdistributionprotocol/acdp-control-plane` links here.

## Why

`acdp-ci`'s new `DELIVERY-STANDARD.md` rule forbids `npm:`-alias declarations for
family packages (`@agentcontextdistributionprotocol/*`) in a consumer's
`package.json`. `acdp-control-plane/package.json:35` currently reads:

```json
"acdp": "npm:@agentcontextdistributionprotocol/acdp@^0.8.1",
```

This is the sole remaining declaration of the family SDK in that repo. CP-1
(commit `ffb3a99`) collapsed what used to be a *duplicate* — a real
`@agentcontextdistributionprotocol/acdp` entry the bot correctly bumped, plus
this alias every source import actually resolves through — down to just the
alias. That fixed the *immediate* symptom (a stale-vs-fresh split) but left the
underlying pattern (aliasing a scoped package to a bare import name) in place,
which is exactly the pattern the new rule forbids, for the reason documented in
`acdp-ci/DELIVERY-STANDARD.md`: Dependabot's weekly safety-net sweep does not
reliably follow `npm:` alias specifiers, so this repo remains exposed to a
recurrence of CP-1 any time the fast `bump-consume` dispatch path is missed and
only the safety net fires — even though `bump-consume.yml`'s own rewrite loop
(verified) already handles this exact alias correctly.

## Delivers

- `package.json` — remove the `"acdp": "npm:..."` alias entry; add back a plain
  `"@agentcontextdistributionprotocol/acdp": "^0.8.1"` entry (matching whatever
  `bump-consume.yml`'s `package:` input is configured to for this repo's
  `bump-acdp.yml` caller — check that file to confirm it already targets the
  scoped name, not `acdp`).
- Every source file that currently does `import ... from 'acdp'` (or `require`)
  updated to `import ... from '@agentcontextdistributionprotocol/acdp'`.
- `package-lock.json` regenerated (`npm install --package-lock-only` or a full
  install) to drop the alias resolution and pick up the direct one.
- `.github/workflows/bump-acdp.yml:15-23` — this file's `package:` input already
  correctly targets the scoped name (`@agentcontextdistributionprotocol/acdp`),
  so no functional change is needed there, but its 9-line comment block
  explaining *why* (because the code "only ever imports the `acdp` npm: alias")
  becomes stale prose once the alias is gone — update or remove it in the same
  commit as the rename (confirmed present at this exact location; verified by a
  reviewer pass during the parent plan's drafting, not by this file's original
  author).

## Depends on

None technically — this can land independently of anything in `acdp-ci`. Ordered
after `acdp-ci`'s rule merges only so the linked issue has a stable reference to
point at.

## Files

- `acdp-control-plane/package.json`
- `acdp-control-plane/package-lock.json`
- Every `acdp-control-plane` source file importing the family SDK (grep
  `from 'acdp'` / `require('acdp')` across `src/` to enumerate — not enumerated
  here since this file is written from outside that repo; the owning session
  should do the actual grep before starting).

## Approach

A mechanical rename, not a design decision — the scoped name is the real package;
the alias was only ever a naming convenience. The risk is entirely in coverage
(missing an import site), not in choosing an approach, so the acceptance
criterion below is a repo-wide grep returning zero remaining `from 'acdp'` /
`require('acdp')` hits, not a sampled check.

## Acceptance criteria

- [ ] `package.json` has no `npm:` alias for any `@agentcontextdistributionprotocol/*`
      package.
- [ ] `grep -rn "from 'acdp'\|require('acdp')" src/` (or equivalent for this
      repo's actual source layout) returns zero hits.
- [ ] `npm run build` / `tsc --noEmit` and the existing test suite pass unchanged
      (a pure import-path rename should not alter runtime behavior).
- [ ] `bump-acdp.yml`'s `package:` input still resolves correctly against the
      new plain dependency entry (re-verify against `bump-consume.yml`'s rewrite
      logic, which matches on `k===pkg`) — no change needed to the input itself,
      already correct.
- [ ] `bump-acdp.yml:15-23`'s comment block no longer describes an alias that no
      longer exists.

## Tests

Existing `acdp-control-plane` unit + integration suite, unchanged — this is a
refactor with no intended behavior change. Add no new tests; if the existing
suite doesn't already exercise every import site (unlikely to fully cover
this), the `grep` check above is the real completeness gate, not test coverage.
