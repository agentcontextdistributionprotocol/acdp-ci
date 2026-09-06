# `checkout-spec`

Composite action: check out the ACDP spec repo
(`agentcontextdistributionprotocol/agentcontextdistributionprotocol`) at a
SHA-verified pinned ref, inside your own job, and export it both as an env
var and as a step output.

## Why a composite action, not a reusable workflow

A `workflow_call` reusable workflow runs as a **separate job on a separate
runner** — its checkout can't reach your job's later steps. This action runs
as a `uses:` step *inside* your job instead, so `ACDP_SPEC_DIR` and the
checked-out files are available to whatever you run next in the same job.

## Usage

```yaml
steps:
  # Your own checkout MUST come first — see "Ordering" below.
  - uses: actions/checkout@v4

  - uses: agentcontextdistributionprotocol/acdp-ci/actions/checkout-spec@015910153b61c32abbe018afe85d44868897bf3b # v1
    id: spec
    with:
      ref: f5b66b8f86f48ba16f79bba95eb246d6acb43989 # pinned spec SHA — bumped via bump-spec-ref.yml

  # Consumer that reads the env var:
  - run: cargo test --features conformance
    # $ACDP_SPEC_DIR is set for every step below this one in the job.

  # Consumer that takes a CLI flag instead:
  - run: python run_conformance.py --spec-dir ${{ steps.spec.outputs.path }}
```

## Inputs

| Input | Default | Purpose |
|---|---|---|
| `ref` | *(required)* | The pinned spec commit. **Must be 40-hex lowercase; anything else is a hard error** before any network call. |
| `repository` | `agentcontextdistributionprotocol/agentcontextdistributionprotocol` | Spec repo. |
| `path` | `acdp-spec` | Checkout path, relative to the workspace. |
| `fetch-depth` | `1` | Passed through to `actions/checkout`. Use `0` if `ref` is unreachable from any ref at the default shallow depth (e.g. the spec force-pushed it away). |
| `set-env` | `true` | Export `ACDP_SPEC_DIR` to `$GITHUB_ENV`. |
| `require-conformance` | `true` | Export `ACDP_REQUIRE_CONFORMANCE=1` to `$GITHUB_ENV`. **Hard error if `true` while `set-env` is `false`** — family consumers (e.g. `acdp-rs`) treat `ACDP_REQUIRE_CONFORMANCE` set without `ACDP_SPEC_DIR` as a failure, so this action refuses to produce that combination. Set both or neither. |

## Outputs

| Output | Purpose |
|---|---|
| `path` | Absolute path to the checkout — for consumers that take a CLI flag rather than reading the env var. |
| `ref` | The verified SHA, for pasting into evidence blocks. |

## Ordering

`actions/checkout` cleans its destination directory. If your own repo's
checkout runs **after** this action, in the workspace root, it will wipe the
spec checkout. Always run your own `actions/checkout` step **before** this
action.

## Notes

- **Matrix jobs** re-run this action once per matrix leg, on a fresh runner
  each time. That's correct, not wasteful enough to justify artifact
  plumbing between jobs.
- **No `secrets:` input.** Composite actions can't accept secrets from the
  caller directly, and none is needed — the spec repo is public.
- There is deliberately **no `allow-unpinned` escape hatch**. If a repo
  genuinely needs a floating spec checkout, write your own `actions/checkout`
  step and own that choice visibly, rather than laundering it through this
  action.
