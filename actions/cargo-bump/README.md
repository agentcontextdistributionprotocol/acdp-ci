# `cargo-bump`

Composite action used by [`bump-consume.yml`](../../.github/workflows/bump-consume.yml)
for the `cargo` ecosystem. It bumps crate `PKG` to `T` and **fails closed** when it can't do
that safely. The logic is in [`bump.sh`](bump.sh), and
[`tests/bump-cargo`](../../tests/bump-cargo/run.sh) runs it offline.

## Why

Before this action, the cargo path replaced the whole version string, which turned
`acdp = { version = "=0.18.1" }` into `"0.18.2"`. It also left a second workspace and the
cargo-vet exemptions on the old version. In acdp-registry-rs that produced three bump PRs
that auto-merged with `cargo-vet` red (#476, #485, #497; acdp-ci#47).

## What it does

For the root and for each dir in `extra-manifests`, it does two things:

1. It rewrites every `PKG = "…"` and `PKG = { version = "…", … }` line in that
   `Cargo.toml`. It keeps the operator, so `=0.18.1`, `^0.18.1`, `~0.18.1` and `0.18.1`
   become `=T`, `^T`, `~T` and `T`. `features`, the table form and `[workspace.dependencies]`
   stay as they were.
2. It runs `cargo update -p PKG --precise T --manifest-path <dir>/Cargo.toml`, so that
   directory's own `Cargo.lock` moves as well.

Next, if `vet-config` exists (default `supply-chain/config.toml`), it updates each
`[[exemptions.acdp*]]` whose version is one a lockfile just moved away from to the version
it moved to. That covers the lockstep `acdp-*` crates too. Exemptions for other crates are
left alone, even if a transitive re-resolve moved them, because a new third-party version is
a trust decision.

## Fails closed (no PR opens)

- A requirement that isn't `=`, `^`, `~` or a bare version, such as `">=0.18, <0.20"`.
- A dotted `[dependencies.PKG]` table (or a multi-line inline table); write it inline on
  one line.
- A listed manifest that is missing, or that has no `PKG` requirement to bump.
- `cargo update` fails.

## Inputs

| Input | Default | Meaning |
|---|---|---|
| `package` | (required) | Crate name in the manifests. |
| `version` | (required) | Target version. |
| `extra-manifests` | `''` | Dirs relative to the repo root, separated by whitespace or newlines, each with its own `Cargo.toml` and `Cargo.lock`. |
| `vet-config` | `supply-chain/config.toml` | cargo-vet config; skipped when it doesn't exist. |

Callers set `extra-manifests` through `bump-consume.yml`'s input of the same name. For
example, acdp-registry-rs passes `extra-manifests: tools/live-smoke`.
