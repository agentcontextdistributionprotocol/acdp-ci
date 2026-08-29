# acdp-ci

Shared CI/CD building blocks for the **acdp-\*** repositories — one place to
define how the whole org builds, propagates dependencies, and ships, so every
repo stays uniform instead of drifting.

## What's here

| Reusable workflow | Purpose |
|---|---|
| [`.github/workflows/auto-merge.yml`](.github/workflows/auto-merge.yml) | Auto-merge Dependabot PRs once required checks pass. Patch + minor unattended; **majors held** for review. |
| [`.github/workflows/bump-consume.yml`](.github/workflows/bump-consume.yml) | Consume a new `acdp` SDK release: resolve → wait for registry → bump manifest + lockfile → PR → arm auto-merge. Ecosystems: `npm`, `cargo`, `uv`. |
| [`.github/workflows/bump-spec-ref.yml`](.github/workflows/bump-spec-ref.yml) | Adopt a new pinned ACDP spec SHA: rewrite the pinned `ref:` in a target workflow file → PR. **Held, never auto-merged** — the PR's own conformance CI runs against the new fixtures, and a human adopts the new spec deliberately. |

| Composite action | Purpose |
|---|---|
| [`actions/checkout-spec`](actions/checkout-spec/README.md) | Check out the ACDP spec at a SHA-verified pinned ref, **inside your own job** (a `uses:` step, not a separate reusable-workflow job) — exports `ACDP_SPEC_DIR` and a `path` output. See [DELIVERY-STANDARD.md](DELIVERY-STANDARD.md) for the adoption recipe. |

| Script | Purpose |
|---|---|
| [`scripts/standardize.sh`](scripts/standardize.sh) | Apply uniform branch protection + `allow_auto_merge` + required checks to every repo. |

See **[DELIVERY-STANDARD.md](DELIVERY-STANDARD.md)** for the full model
(dependency-propagation graph, credential design, rollout).

## How a repo uses it

`auto-merge` — commit `.github/workflows/auto-merge.yml`:

```yaml
name: auto-merge
on: pull_request
permissions: { contents: write, pull-requests: write }
jobs:
  call:
    uses: agentcontextdistributionprotocol/acdp-ci/.github/workflows/auto-merge.yml@v1
```

`bump-acdp` (consumers only) — commit `.github/workflows/bump-acdp.yml`:

```yaml
name: bump acdp
on:
  repository_dispatch: { types: [acdp-released] }
  workflow_dispatch:   { inputs: { version: { required: false, default: '' } } }
jobs:
  bump:
    uses: agentcontextdistributionprotocol/acdp-ci/.github/workflows/bump-consume.yml@v1
    with:  { ecosystem: npm, package: '@agentcontextdistributionprotocol/acdp' }  # cargo|uv per repo
    secrets: inherit
```

`bump-spec` (spec-pinning consumers only) — commit `.github/workflows/bump-spec.yml`:

```yaml
name: bump spec
on:
  repository_dispatch: { types: [spec-released] }
  workflow_dispatch:   { inputs: { sha: { required: false, default: '' } } }
jobs:
  bump:
    uses: agentcontextdistributionprotocol/acdp-ci/.github/workflows/bump-spec-ref.yml@v1
    with:  { file: .github/workflows/ci.yml, sha: '${{ github.event.inputs.sha }}' }
    secrets: inherit
```

`checkout-spec` (spec-pinning consumers only) — a step inside your own CI job, **after** your
own repo's checkout:

```yaml
steps:
  - uses: actions/checkout@v4   # your own repo — must come first, see the action's README

  - uses: agentcontextdistributionprotocol/acdp-ci/actions/checkout-spec@v1
    id: spec
    with:
      ref: f5b66b8f86f48ba16f79bba95eb246d6acb43989   # pinned spec SHA — bumped via bump-spec-ref.yml

  - run: cargo test --features conformance   # $ACDP_SPEC_DIR is set for this and later steps
```

## Credentials

The **only** cross-repo credential is the `acdp-deps-bot` GitHub App, stored
once as org secrets `ACDP_BOT_APP_ID` / `ACDP_BOT_PRIVATE_KEY`. Workflows mint a
short-lived installation token via `actions/create-github-app-token`. No PATs.
Registry-publish tokens (`NPM_TOKEN`, `CARGO_REGISTRY_TOKEN`; PyPI is OIDC) live
in `acdp-rs` and are a separate concern.

## Conventions

- Third-party actions are **SHA-pinned**; first-party `actions/*` use major tags.
- Pin callers to a release tag (`@v1`), not `@main`.
