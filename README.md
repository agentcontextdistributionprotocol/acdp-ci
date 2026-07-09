# acdp-ci

Shared CI/CD building blocks for the **acdp-\*** repositories — one place to
define how the whole org builds, propagates dependencies, and ships, so every
repo stays uniform instead of drifting.

## What's here

| Reusable workflow | Purpose |
|---|---|
| [`.github/workflows/auto-merge.yml`](.github/workflows/auto-merge.yml) | Auto-merge Dependabot PRs once required checks pass. Patch + minor unattended; **majors held** for review. |
| [`.github/workflows/bump-consume.yml`](.github/workflows/bump-consume.yml) | Consume a new `acdp` SDK release: resolve → wait for registry → bump manifest + lockfile → PR → arm auto-merge. Ecosystems: `npm`, `cargo`, `uv`. |

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

## Credentials

The **only** cross-repo credential is the `acdp-deps-bot` GitHub App, stored
once as org secrets `ACDP_BOT_APP_ID` / `ACDP_BOT_PRIVATE_KEY`. Workflows mint a
short-lived installation token via `actions/create-github-app-token`. No PATs.
Registry-publish tokens (`NPM_TOKEN`, `CARGO_REGISTRY_TOKEN`; PyPI is OIDC) live
in `acdp-rs` and are a separate concern.

## Conventions

- Third-party actions are **SHA-pinned**; first-party `actions/*` use major tags.
- Pin callers to a release tag (`@v1`), not `@main`.
