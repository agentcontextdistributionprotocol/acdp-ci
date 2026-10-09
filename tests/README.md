# Tests

Three offline bash harnesses, each shadowing the external tool it would otherwise call
(`gh`, `npm`) with a stub on `PATH` and asserting that the stub is the one in use (so a
real binary can never make a case vacuous). None needs network or credentials.

| Harness | Covers | Run |
|---|---|---|
| [`tests/standardize/`](standardize/README.md) | `scripts/standardize.sh` against JSON fixtures: drift guard, `--check`, registry baseline file, weakening guard, UNREGISTERED sweep, exit codes. `mutants.sh` is the mutation-coverage guard for it (needs `python3` and `jq`; **rewrites `scripts/standardize.sh` in place while running — start from a clean tree**). | `bash tests/standardize/run.sh` · `bash tests/standardize/mutants.sh` |
| [`tests/auto-merge/`](auto-merge/run.sh) | `actions/auto-merge-gate` (`decide.sh`, `disarm.sh`): table-driven eligibility cases including deny lists and fail-safes. | `bash tests/auto-merge/run.sh` |
| [`tests/bump-npm/`](bump-npm/run.sh) | `actions/npm-relock/relock.sh` against a shadow `npm` that models the publish race, plus wiring assertions on `bump-consume.yml`. Needs `shasum`, `node` and `jq`. `BUMP_NPM_LIVE=1` additionally runs one case against the real registry. | `bash tests/bump-npm/run.sh` |

There is also a manual **docs consistency checker**, [`tests/docs/check-docs.sh`](docs/check-docs.sh):
relative and sibling-repo links (file + heading anchor), line-number pins in prose, action
inputs/outputs named in the READMEs vs `action.yml`, the anchors other repos link to, the repo
matrix vs `standardize.sh`'s lists, and (with `DOCS_CHECK_MERMAID=1`, needs `npx` and network)
that every Mermaid block parses. It reports; it is not a CI guard.

Each harness prints one `PASS:`/`FAIL:` line per case and a summary; the exit status is
non-zero on any failure. **These suites are not wired into CI** (this repo's only workflows
are the reusable ones and `drift-check.yml`, which has no `pull_request` trigger by design —
see [DELIVERY-STANDARD.md](../DELIVERY-STANDARD.md)); run them locally before shipping a
change under `scripts/`, `actions/`, or `.github/workflows/`.
