# ACDP Delivery Standard

The uniform CI/CD model for every `acdp-*` repository. Where repos legitimately
differ (build toolchain, publish target), that difference is called out and
kept local; everything else is shared here.

## Publish topology

`acdp-rs` is the hub. It publishes three packages via three independent,
tag-triggered workflows, each with its own registry credential:

| Package | Workflow (in acdp-rs) | Trigger | Registry | Credential |
|---|---|---|---|---|
| `acdp` crate | `release-plz.yml` | push to `main` | crates.io | `CARGO_REGISTRY_TOKEN` |
| `@agentcontextdistributionprotocol/acdp` (NAPI) | `bindings-release.yml` | tag `acdp-node-v*` | npm | `NPM_TOKEN` |
| `acdp` wheels | `acdp-py-release.yml` | tag `acdp-py-v*` | PyPI | OIDC (no token) |

## Propagation graph

```
                     ┌─ crate (release-plz) ─▶ dispatch ▶ acdp-registry-rs   → cargo add acdp@X
acdp-rs publishes ───┼─ npm   (bindings)     ─▶ dispatch ▶ acdp-control-plane → npm re-lock
                     └─ py    (py-release)   ─▶ dispatch ▶ acdp-playground    → uv lock --upgrade
```

Each publish job fires `repository_dispatch: acdp-released` (payload
`{version, ecosystem}`) at its consumer(s) using an `acdp-deps-bot` App token.
The consumer's `bump-acdp.yml` calls `bump-consume.yml`. Dependabot's weekly
`acdp` group is the safety net if a dispatch is ever missed.

Leaves — standardized (CI + auto-merge + Dependabot) but no SDK dependency, so
no `bump-acdp`:

- **acdp-verifier-py** — independent second implementation of the verification
  core (for spec Final promotion). Its independence from `acdp-rs` is the point.
- **acdp-ui-console**, **acdp-website** — Vercel deploys.

## Merge policy

Patch + minor auto-merge on a green pipeline; **majors are held** for a human
(Dependabot majors, and breaking SDK bumps — `major`, or a `minor` while
`0.x` — from `bump-consume`).

## Credentials

One GitHub App (`acdp-deps-bot`, Contents RW + Pull requests RW), installed
org-wide, key stored once as org secrets `ACDP_BOT_APP_ID` /
`ACDP_BOT_PRIVATE_KEY`. Every cross-repo dispatch and every bot PR mints a
short-lived installation token from it — **zero PATs**. Registry-publish tokens
stay in `acdp-rs`.

## Repo matrix

| Repo | Lang | CI caller | auto-merge | Dependabot | bump-acdp | Publish | Graph role |
|---|---|---|---|---|---|---|---|
| acdp-rs | Rust | own ci | ✅ | ✅ (SHA-pinned) | — | crate+npm+py+wasm | **hub / sends 3 dispatches** |
| acdp-registry-rs | Rust | own ci | add | cargo+docker+ga | cargo | Docker + crate | consumes crate |
| acdp-control-plane | npm | own ci | ✅ | npm+docker+ga | npm | Docker | consumes npm |
| acdp-playground | Python/uv | own ci | add | uv+docker+ga | uv | Docker | consumes py |
| acdp-verifier-py | Python | own ci | add | pip+ga | — | — | independent |
| acdp-ui-console | TS | own ci | add | npm+ga | — | Vercel | leaf |
| acdp-website | MDX | own ci | add | npm+ga | — | Vercel | leaf |

## Extending to new SDKs (Java / Go / Kotlin)

Add a `bump-consume` ecosystem branch (`gradle`/`go`/…) and an `acdp-rs`
publish→dispatch step. The consumer repo gets the same thin `bump-acdp.yml`
caller. Nothing else changes.
