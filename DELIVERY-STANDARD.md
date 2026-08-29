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
SHA** in consumers' CI. **The rule: every repo whose CI consumes the spec MUST
check it out at a 40-hex SHA via
[`acdp-ci/actions/checkout-spec@v1`](actions/checkout-spec/README.md)** —
never an unpinned/default-branch checkout. Adoption of a new SHA is always a
reviewed PR, never auto-merged (below). As of 2026-08-28: `acdp-rs` pins via
this action; `acdp-verifier-py` (PY-2) and `acdp-registry-rs` (REG-1) are
scheduled to adopt it — until they do, their CI does not enforce this rule.

1. On a conformance-relevant push (`schemas/**`, `examples/**`, `rfcs/**`),
   the spec repo's `notify-spec-consumers.yml` dispatches
   `repository_dispatch: spec-released {sha}` to each pinner.
2. The pinner's `bump-spec.yml` calls `bump-spec-ref.yml@v1`, which rewrites the
   pinned `ref:` in the target workflow file and opens a PR that is **never
   auto-merged** — the PR's own conformance CI runs against the new fixtures, and
   a human adopts the new spec deliberately (the pin exists precisely so spec
   changes never silently alter CI). `bump-spec-ref.yml` understands both the
   inline pin shape below and the `checkout-spec` action's pin shape.

#### Adopting `checkout-spec` in a new consumer repo

Add a step **after your own repo's checkout** (see Ordering, below) to the job
that needs the spec:

```yaml
steps:
  - uses: actions/checkout@v4   # your own repo — MUST come first, see Ordering

  - uses: agentcontextdistributionprotocol/acdp-ci/actions/checkout-spec@v1
    id: spec
    with:
      ref: f5b66b8f86f48ba16f79bba95eb246d6acb43989   # pinned spec SHA — bumped via bump-spec-ref.yml

  # Consumer that reads the env var (e.g. a Rust harness like acdp-rs/acdp-registry-rs):
  - run: cargo test --features conformance
    # $ACDP_SPEC_DIR is set for every step below this one in the job.

  # Consumer that takes a CLI flag instead (e.g. acdp-verifier-py):
  - run: python run_conformance.py --spec-dir ${{ steps.spec.outputs.path }}
```

Then add a thin `bump-spec.yml` caller so a spec release reaches this repo
automatically:

```yaml
name: bump spec
on:
  repository_dispatch:
    types: [spec-released]
  workflow_dispatch:
    inputs:
      sha:
        description: 'Spec SHA to adopt (blank = spec HEAD)'
        required: false
        default: ''
jobs:
  bump:
    uses: agentcontextdistributionprotocol/acdp-ci/.github/workflows/bump-spec-ref.yml@v1
    with:
      file: .github/workflows/ci.yml   # the file holding your checkout-spec step
      sha: ${{ github.event.inputs.sha }}
    secrets: inherit
```

**Ordering.** `actions/checkout` cleans its destination. Your own repo's
checkout must run **before** the `checkout-spec` step, or it will wipe the
spec checkout out from under it. See the action's own README for the full
input/output reference and the `fetch-depth: 0` remedy for an unreachable pin.

## Merge policy

Patch + minor auto-merge on a green pipeline; **majors are held** for a human
(Dependabot majors, and breaking SDK bumps — `major`, or a `minor` while
`0.x` — from `bump-consume`).

## CI baseline

Auto-merge only ships what CI vouches for, so every repo's `main` protection must
require a pipeline that meets this bar. **The principles are uniform; how each
ecosystem satisfies them is not** — do not port one repo's tooling into another
(a Rust repo's gate is clippy, not `ci-conventions.sh`).

Every repo:

- [ ] **Format** enforced, not advisory — rustfmt / ruff format / prettier
- [ ] **Lint** at zero warnings — clippy `-D warnings` / ruff / eslint `--max-warnings 0`
- [ ] **Type-check** — `tsc --noEmit` / mypy `--strict` (native to Rust)
- [ ] **Tests + coverage gate** — thresholds enforced in CI, not merely measured
- [ ] **Convention / supply-chain checks** where the repo defines them — e.g.
      control-plane `scripts/ci-conventions.sh`; acdp-rs `cargo-deny` + `cargo-vet`
      + `cargo-semver-checks`

Ships a container image → additionally:

- [ ] **`docker build` (no push) on PRs** — a broken Dockerfile fails at PR time,
      not release time
- [ ] **Boot / smoke before publish** — boot the built image (or run a
      golden-vector / conformance smoke) so an unbootable artifact never reaches
      the registry or a deploy

The jobs satisfying this bar are the **required status checks** on `main`
(configured by `scripts/standardize.sh`), so a red gate blocks the merge and
auto-merge never overrides it. All current repos meet this baseline (see the Repo
matrix); acdp-rs exceeds it. New SDK repos (Java / Go / Kotlin) inherit the bar,
satisfied by their own ecosystem's tools.

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

**The `acdp-deps-bot` App's `Workflows: Read/write` is org-wide** — it can push to
`.github/workflows/**` in every repo it's installed in, `acdp-ci` included. That
is exactly the class of actor `main` branch protection (`scripts/standardize.sh`)
and the `v*` tag ruleset (below) exist to bound: neither grants the App a bypass,
so a compromised or misbehaving bot run can propose a bump PR but cannot force a
merge past protection, and cannot touch the `v1` tag at all.

## Releasing `acdp-ci` (the `v1` tag)

Every consumer resolves `acdp-ci/.github/workflows/*@v1` and
`acdp-ci/actions/checkout-spec@v1` at that one **mutable** tag. Moving it is a
**human-assisted** operation — no agent or workflow ever runs these commands.
Run this **after** a PR to `acdp-ci` merges, and **before** creating/relying on
the `v*` tag ruleset below (rehearse the move first; a ruleset created before the
move has ever been exercised means the first failure mode is a rejected push
with no known-good remedy).

```sh
# 1. Record pre-move state FIRST — this is the only rollback anchor.
# NOTE: do NOT pass "v1" as a ls-remote pattern here — a refname pattern matches
# against the ref's last path component, and "v1" does not match "v1^{}", so a
# filtered `git ls-remote --tags origin v1` silently drops the peeled line you
# need. Always list unfiltered, then pick the two lines out with awk/grep.
git ls-remote --tags origin
#   <tag-object-sha>  refs/tags/v1      <- annotated tag object
#   <commit-sha>      refs/tags/v1^{}   <- commit v1 points at
OLD_V1_TAG_OBJ=$(git ls-remote --tags origin | awk '$2=="refs/tags/v1"{print $1}')
OLD_V1_COMMIT=$(git ls-remote --tags origin | awk '$2=="refs/tags/v1^{}"{print $1}')
# Do not proceed on an empty value, or step 6's rollback silently DELETES v1
# instead of restoring it (an empty $OLD_V1_TAG_OBJ makes the refspec "+:refs/tags/v1").
if [ -z "$OLD_V1_TAG_OBJ" ] || [ -z "$OLD_V1_COMMIT" ]; then
  echo "FAILED to capture pre-move state — STOP, do not proceed" >&2
  return 1 2>/dev/null || exit 1
fi
echo "OLD_V1_TAG_OBJ=$OLD_V1_TAG_OBJ  OLD_V1_COMMIT=$OLD_V1_COMMIT"
# Paste both into the PR thread.

# 2. Fetch (force, so the old tag object stays in the local object store) and identify the target.
git fetch origin main '+refs/tags/v1:refs/tags/v1'
NEW_SHA=$(gh pr view <PR_NUMBER> --repo agentcontextdistributionprotocol/acdp-ci \
  --json mergeCommit -q .mergeCommit.oid)
git log --oneline "$OLD_V1_COMMIT..$NEW_SHA"   # review EVERYTHING this move ships, not just the PR
git rev-parse origin/main                      # normally equals NEW_SHA

# 3. Verify the move is a fast-forward of the tag.
git merge-base --is-ancestor "$OLD_V1_COMMIT" "$NEW_SHA" && echo FAST-FORWARD-OK
# No FAST-FORWARD-OK => you would move v1 sideways/backwards. STOP and investigate.

# 4. Move the tag; force-push ONLY this ref. Keep it ANNOTATED.
git tag -f -a v1 -m "acdp-ci v1" "$NEW_SHA"
git push origin refs/tags/v1 --force     # equivalently: git push origin '+refs/tags/v1:refs/tags/v1'
# NEVER `git push --tags -f`: that force-pushes every local tag, silently clobbering or
# resurrecting others. The explicit refspec touches refs/tags/v1 and nothing else.

# 5. Verify. (Unfiltered again — see the note on step 1 for why "origin v1" drops
#    the ^{} line you need to check here.)
git ls-remote --tags origin   # the ^{} line for refs/tags/v1 must now show $NEW_SHA
gh api repos/agentcontextdistributionprotocol/acdp-ci/git/ref/tags/v1 -q '.object.sha'
# ^ returns the new TAG-OBJECT sha, which differs from $NEW_SHA — expected for an annotated
#   tag. Always compare the peeled ^{} line, or you will wrongly conclude the push failed.
# Smoke: re-run one consumer workflow (e.g. acdp-rs auto-merge or a bump dispatch) and confirm
# it resolves @v1 and passes.

# 6. Rollback — restores the exact original tag object (tagger/date/message included).
# NOTE: if the v* tag ruleset (below) is active, this step moves v1 BACKWARDS and is therefore
# NOT a fast-forward — non_fast_forward on the ruleset requires the bypass actor here even
# though step 4's forward move satisfied non_fast_forward on its own.
# GUARD — an empty OLD_V1_TAG_OBJ turns the refspec below into "+:refs/tags/v1", which
# DELETES v1 instead of restoring it. Never skip this check, even under pressure.
if [ -z "$OLD_V1_TAG_OBJ" ]; then
  echo "OLD_V1_TAG_OBJ is empty — STOP, re-derive it from step 1's output before rolling back" >&2
  return 1 2>/dev/null || exit 1
fi
# BRACE THE VARIABLE — in zsh (macOS's default shell), an unbraced "$VAR:refs/..."
# parses ":r" as the history-style "root" modifier and silently eats it, turning
# this into "+<sha>efs/tags/v1" — not a syntax error, just the wrong ref, and git
# rejects it with a confusing "src refspec ... does not match any". Confirmed via
# `zsh -c`. ${OLD_V1_TAG_OBJ} (braced) is unambiguous in both bash and zsh — do not
# "simplify" this back to the unbraced form.
git push origin "+${OLD_V1_TAG_OBJ}:refs/tags/v1"
git ls-remote --tags origin   # the ^{} line for refs/tags/v1 must show $OLD_V1_COMMIT again
```

**Not recoverable by rollback:** any consumer run that had already *started* resolved the new
commit and finishes on it. Actions resolves `uses: …@v1` at job start. Prefer a quiet window.

**Blast radius:** moving `v1` instantly retargets the reusable workflows consumed by all ~9
downstream repos; every consumer run that starts after the push executes the new commit, with
no staging, canary, or opt-in.

### The `v*` tag ruleset

Protects `refs/tags/v*` from deletion, force-push (`non_fast_forward`), an unreviewed
fast-forward `update`, and a spoofed `creation` — while leaving exactly one bypass: the
repository-admin role, which is not held by the `acdp-deps-bot` App (GitHub Apps cannot
inherit a `RepositoryRole` bypass — deliberate, given the App's org-wide `Workflows:write`).

```bash
# CREATE — a GitHub settings change. Run manually, after rehearsing the v1 move above.
gh api --method POST repos/agentcontextdistributionprotocol/acdp-ci/rulesets --input - <<'JSON'
{
  "name": "protect-v-tags",
  "target": "tag",
  "enforcement": "active",
  "bypass_actors": [
    { "actor_id": 5, "actor_type": "RepositoryRole", "bypass_mode": "always" }
  ],
  "conditions": {
    "ref_name": { "include": ["refs/tags/v*"], "exclude": [] }
  },
  "rules": [
    { "type": "creation" },
    { "type": "update" },
    { "type": "deletion" },
    { "type": "non_fast_forward" }
  ]
}
JSON
```

```bash
# VERIFY — mandatory. A wrong pattern (the API stores/matches the fully-qualified
# "refs/tags/v*", not the bare "v*" the UI displays) protects nothing, silently.
gh api repos/agentcontextdistributionprotocol/acdp-ci/rulesets \
  --jq '.[] | {id, name, target, enforcement}'
gh api repos/agentcontextdistributionprotocol/acdp-ci/rulesets/<RULESET_ID> \
  --jq '{name, target, enforcement, conditions, rules, bypass_actors, current_user_can_bypass}'
# Expect: conditions.ref_name.include == ["refs/tags/v*"]; current_user_can_bypass == "always".
# Also confirm the GitHub UI renders the bypass actor as "Repository admin".
# Functional smoke: the next routine forward v1 move must succeed and appear in the
# repo's rule-bypass audit view.
```

```bash
# ROLLBACK — restores today's exact state; acdp-ci has no other rulesets.
gh api --method DELETE repos/agentcontextdistributionprotocol/acdp-ci/rulesets/<RULESET_ID>
```

**Blast radius:** affects only refs matching `refs/tags/v*` in `acdp-ci`; the ~9 consumer repos
are read-side and unaffected; the sole repo admin retains full create/move/delete via
automatic, audit-logged bypass; rollback is one DELETE.

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
| acdp-ci | YAML/bash | n/a — `workflow_call`/composite only, zero check-runs on its own PRs | ❌ (protection-only, see `standardize.sh`) | ga (2 dirs: root + `actions/checkout-spec`) | — | — | **infra — this is the hub; every repo above consumes it at `@v1`** |
| `.github` | — | n/a — no `.github/workflows/` at all | ❌ (protection-only, see `standardize.sh`) | — | — | — | org profile + community health files |

## Extending to new SDKs (Java / Go / Kotlin)

Add a `bump-consume` ecosystem branch (`gradle`/`go`/…) and an `acdp-rs`
publish→dispatch step. The consumer repo gets the same thin `bump-acdp.yml`
caller. Nothing else changes.
