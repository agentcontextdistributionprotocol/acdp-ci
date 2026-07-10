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

## Propagation mechanics

Two propagation lanes, both event-driven, both App-authenticated, both with a
Dependabot safety net.

### SDK propagation (a new `acdp` package → its consumers)

1. `acdp-rs` publishes (`release-plz` crate / `bindings-release` npm tag /
   `acdp-py-release` PyPI tag). Each publish job, on a real publish, mints an
   App token scoped to the consumer and POSTs `repository_dispatch: acdp-released`
   with `client_payload {version, ecosystem}`.
   - crate → `acdp-registry-rs` (detected from release-plz's `releases` output;
     other workspace crates are ignored)
   - npm → `acdp-control-plane` (version from the `acdp-node-v*` tag)
   - PyPI → `acdp-playground` (version from the `acdp-py-v*` tag)
2. The consumer's thin `bump-acdp.yml` calls `bump-consume.yml@v1`, which:
   resolves the target, **waits for the registry to actually serve it** (npm CDN
   / crates.io index / PyPI can lag a publish), bumps the manifest + lockfile for
   the ecosystem (`npm` rewrites the dep and any `npm:` alias; `cargo` edits the
   version in place preserving `features`, virtual-workspace-safe, then
   `cargo update --precise`; `uv` runs `uv lock --upgrade-package`), opens a PR,
   and arms auto-merge **unless the bump is breaking** (major, or a `0.x` minor).
3. Missed dispatch → Dependabot's weekly `acdp` group opens the same PR later.

### Spec propagation (a new spec revision → its SHA-pinners)

The spec (`agentcontextdistributionprotocol`) is a **dependency pinned by git
SHA** in consumers' CI (currently only `acdp-rs` pins it; `acdp-verifier-py`
tracks the default branch, so nothing to bump).

1. On a conformance-relevant push (`schemas/**`, `examples/**`, `rfcs/**`),
   the spec repo's `notify-spec-consumers.yml` dispatches
   `repository_dispatch: spec-released {sha}` to each pinner.
2. The pinner's `bump-spec.yml` calls `bump-spec-ref.yml@v1`, which rewrites the
   pinned `ref:` in the target workflow file and opens a PR that is **never
   auto-merged** — the PR's own conformance CI runs against the new fixtures, and
   a human adopts the new spec deliberately (the pin exists precisely so spec
   changes never silently alter CI).

## Merge policy

Patch + minor auto-merge on a green pipeline; **majors are held** for a human
(Dependabot majors, and breaking SDK bumps — `major`, or a `minor` while
`0.x` — from `bump-consume`).

## Credentials

One GitHub App (`acdp-deps-bot`), installed org-wide, key stored once as org
secrets `ACDP_BOT_APP_ID` / `ACDP_BOT_PRIVATE_KEY`. Every cross-repo dispatch and
every bot PR mints a short-lived installation token from it — **zero PATs**.
Registry-publish tokens (`NPM_TOKEN`, `CARGO_REGISTRY_TOKEN`; PyPI is OIDC) stay
in `acdp-rs`.

App repository permissions:

| Permission | Why |
|---|---|
| Contents: Read/write | commit bump branches; POST `repository_dispatch` |
| Pull requests: Read/write | open the bump PRs |
| **Workflows: Read/write** | **required** for `bump-spec-ref` — the spec pin lives in `.github/workflows/ci.yml`, and GitHub blocks an App from pushing changes under `.github/workflows/` without it |

`bump-consume` (manifests/lockfiles) does not need Workflows; only spec-pin
propagation does.

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
