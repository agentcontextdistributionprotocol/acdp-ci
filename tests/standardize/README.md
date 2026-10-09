# `tests/standardize/` — offline test harness for `scripts/standardize.sh`

`scripts/standardize.sh` PUTs `required_status_checks.contexts` **wholesale**
from the hand-maintained `checks_for()` table. If live branch protection has a
required check that table doesn't declare, the next run of the script
silently deletes it. This harness proves that bug offline — no live GitHub
calls, ever — and now also carries Phase 2's regression tests for the fix.

## Why this harness is committed

Prior CI waves used scratch test harnesses that were discarded once the work
landed. This one is different on purpose: the defect it guards against is a
**silent regression** — `checks_for()` can drift out of sync with reality
again at any point in the future, and a discarded harness can't catch that a
second time. Keeping it in the repo means the next drift gets caught by
`tests/standardize/run.sh`, not by a production PUT quietly deleting a check.

## Running it

```sh
tests/standardize/run.sh
```

It prepends `tests/standardize/bin` to `PATH`, asserts `command -v gh`
resolves there (so the shadow binary is actually in effect and the run isn't
vacuously green), runs the case matrix, prints a `PASS`/`FAIL` line per
assertion and a summary, and exits non-zero if anything failed. It is
self-contained: every case gets its own temp `$GH_LOG`, cleaned up by the OS
temp directory (nothing is left behind that later runs depend on).

No arguments, no setup, no network access required.

## The shadow `gh` (`tests/standardize/bin/gh`)

It must be named exactly `gh` — a differently-named stub (e.g. `fake-gh`)
could never satisfy `command -v gh`, which is how `standardize.sh` (and this
harness's own PATH guard) finds it. Only `gh api ...` is implemented, since
that's the only subcommand `standardize.sh` calls.

It parses argv positionally and consumes the *arguments* of `-F`, `-f`, `-H`,
`--input`, `--jq`, `-X`, and `--method` so none of them is ever mistaken for
the API path — the path is the first non-flag, non-consumed token after
`api`. A `GET`'s `--jq <filter>` is applied with `jq -r`, exactly like real
`gh --jq` does, so a filter error (e.g. against malformed fixture JSON)
surfaces as a non-zero exit rather than silently producing empty output.

### Two modes

- **Block mode (default).** `GET` is served from fixtures. Any mutating call
  (`-X`/`--method` set to anything other than `GET`) prints
  `BLOCKED MUTATION <method> <path>` to stderr and exits `99`. This is the
  safe default: nothing mutating can ever slip through to a real API call,
  and `set -e` in `standardize.sh` means the script stops dead the instant it
  tries.

- **Record mode (`GH_STUB_RECORD=1`).** `GET` is still served from fixtures.
  A mutating call is instead **logged** (full argv, and the stdin body if
  `--input -` was used) to `$GH_LOG`, and the stub prints a minimal plausible
  success JSON (echoing the stdin body back for a PUT, or a JSON object built
  from the `-F`/`-f` pairs for a PATCH) and exits `0`.

  **Record mode is required, not optional.** `standardize.sh`'s first
  mutation is the `-X PATCH` (repo settings), which happens *before* the
  `-X PUT .../protection` call. In block mode that PATCH is blocked and
  `set -e` aborts the script right there — the protection PUT is never
  reached. Without record mode there is no way to observe what
  `standardize.sh` would actually PUT, which means the entire "show the
  script drops a live check" demonstration (and, in Phase 2, testing
  `--allow-check-removal`, which only matters at the mutation itself) would
  be unobservable.

Every invocation — GET or mutating, either mode — is appended to `$GH_LOG`
when that variable is set, so `run.sh` can assert on call counts and bodies
after the fact (e.g. "this case made zero mutating calls").

### Fixture resolution

- `$FIXTURES` must be set to a directory, or the stub errors and exits `1`.
- The fixture file for a `GET <path>` is `$FIXTURES/<path with / -> _>.json`.
  For example `GET repos/agentcontextdistributionprotocol/acdp-ci/branches/main`
  resolves to
  `$FIXTURES/repos_agentcontextdistributionprotocol_acdp-ci_branches_main.json`.
- A missing fixture file is a loud failure: the stub prints the exact path it
  expected to stderr and exits `1`. It never silently returns empty output.

## Fixtures (`tests/standardize/fixtures/<case>/`)

Each case directory holds, per repo involved:

- `repos_<org>_<repo>.json` — `{"default_branch":"main"}`
- `repos_<org>_<repo>_branches_main.json` — a branch-summary payload (the
  shape returned by `GET /repos/{owner}/{repo}/branches/{branch}`, i.e. the
  same endpoint the CI-6 guards in `auto-merge.yml`/`bump-consume.yml`
  already use).

The registry cases additionally carry the two payloads only that repo needs:
`..._branches_main_protection.json` (the `branches/{b}/protection` read behind the
weakening guard — the one place `standardize.sh` reads that endpoint) and
`..._contents_.github_required-checks.json.json` (its committed baseline file,
served raw).

**Provenance.** The branch-summary shapes (both the unprotected form and the
protected form with `enforcement_level`/`checks[].app_id`) were captured live
against the real `agentcontextdistributionprotocol` org on **2026-09-05** and
are reproduced verbatim for the unprotected case. The protected fixtures
combine that same real shape with the declared-check names taken verbatim
from `checks_for()` in `scripts/standardize.sh`. No fixture contains a
credential, token, or private-repo payload.

### The 11 committed fixture cases

| Case | Purpose |
|---|---|
| `registry-rs-drift` | `acdp-registry-rs` live with 4 contexts (`rustfmt`, `clippy`, `tests`, `conformance (spec fixtures)`) — the original defect's shape (a live check the old hand-maintained table did not declare). Now only used by the fixture-serving assertions (the stub serves it read-only); the registry's declared checks come from its baseline file, not `checks_for()`. |
| `registry-rs-insync` | The canonical in-sync registry fixture: 11 live contexts, the branch-protection payload, and the committed baseline file. Reused as the base for most scratch fixtures the baseline/weakening tests build. |
| `control-plane-reorder` | `acdp-control-plane`'s same 3 declared checks, in a shuffled live order — the false-positive trap; order must never read as drift. |
| `playground-exact` | `acdp-playground`'s live branch has 2 contexts while `checks_for()` declares 3 — a declared-but-not-live check (pending-apply) never blocks. |
| `unprotected` | `acdp-ci` unprotected (`protected:false`) — the normal first-apply case. |
| `protected-no-rsc` | `protected:true` with no `required_status_checks` key at all — a permission-degraded-looking read. |
| `contexts-null` | `required_status_checks.contexts` is `null`. |
| `contexts-not-array` | `required_status_checks.contexts` is a string, not an array. |
| `invalid-json` | The branch fixture file is not valid JSON (`{oops`). |
| `api-failure` | The branch fixture file is absent entirely (repo fixture still present) — simulates a failed `gh api` call. |
| `unmanaged` | `acdp-rs`: `checks_for()` returns 1 (not in the managed set) — `standardize.sh` skips it before making any `gh` call at all. |

### Scratch fixtures (most of the assertions)

Most assertions do not use the committed cases above: `run.sh` builds throwaway fixtures
(`mktemp -d`, helpers such as `write_insync_fixture`, `write_org_listing`,
`write_registry_baseline`) so each test can vary exactly one thing. The sections of `run.sh`
(search for its `echo "== …"` banners) are: fixture-serving, full-script cases, `checks_for()`
corrections and the drift guard, pending-apply reporting (`G*`), stub honesty / `enforce_admins`
bodies / `acdp-rs` never touched (`#22`/`#30`), the UNREGISTERED org-listing sweep (`B*`), and the
registry baseline file and weakening guard (`#33`). Test IDs (`B2`, `G4b`, …) are stable labels
that `mutants.sh` names in its declared killer sets.

`acdp-ci` and `.github` are protection-only in `checks_for()` (zero declared
checks); `unprotected` fixtures them using `acdp-ci`.

## What this phase proves

Running the **unmodified** `scripts/standardize.sh` (i.e. before Phase 2's
`checks_for()` correction) in **record mode** against
`fixtures/registry-rs-drift` and inspecting the `PUT
.../branches/main/protection` request body in `$GH_LOG` shows
`contexts: ["rustfmt","clippy","tests"]` — three items. The live branch has a
fourth (`conformance (spec fixtures)`); it is silently absent from the PUT.
That is the bug, and [`baseline-drift-demo.txt`](./baseline-drift-demo.txt)
is the captured evidence of it.

**`baseline-drift-demo.txt` is FROZEN pre-fix evidence — `run.sh` no longer
regenerates it.** It was captured once, against the script as it stood
before Phase 2's `checks_for()` fix. Now that `checks_for()` no longer drops
any of `acdp-registry-rs`'s live checks, re-running that same demonstration
against the fixed script would no longer show a drop — it would just
overwrite the proof the bug ever existed with a post-fix negative result.
So `run.sh` only *asserts* the frozen file is still present and still shows
the original evidence (see the "HEADLINE" assertion); it must never
regenerate the file's contents. Phase 2's own drift-guard behaviour is
proven separately, by the cases below, using a scratch fixture with a
hypothetical check the now-corrected table still doesn't know about — not
by reverting the `checks_for()` fix to manufacture drift again.

## bash 3.2 compatibility

`scripts/standardize.sh` targets macOS's stock bash 3.2.57, and so does
everything in this directory. The `bash` on `PATH` here is 5.x, so `run.sh`
also invokes `standardize.sh` at least once via explicit `/bin/bash` to catch
a 3.2 incompatibility mechanically rather than relying on code review alone.
Banned constructs: `declare -A`, `local -n`/`declare -n`, `mapfile`/
`readarray`, `${var^^}`/`${var,,}`, `[[ -v ]]`, `&>>`. (`${var//pat/rep}` *is*
valid in bash 3.2 and is used freely.)

## `mutants.sh` — proving the assertions still bite

`run.sh` proves `standardize.sh` behaves correctly. It cannot prove its own
assertions would *notice* if `standardize.sh` stopped behaving correctly. A
test that passes with the bug injected is worth nothing, and from the outside
it is indistinguishable from one that works — green either way.

`./tests/standardize/mutants.sh` injects the known bugs listed below (thirty-two as of 2026-10-09; the run prints the live count) and requires the
suite to fail on each (killer sets for all but the original four were *measured*, not guessed):

| mutant | assertions that catch it |
|---|---|
| drift detection disabled (extras always empty) | 6 |
| fail-closed jq replaced by the B4 // [] defaulting | 5 |
| wholly-failed survey downgraded from fatal (2) to finding (1) | 3 |
| partial failure over-escalated to fatal (any unreadable, not all) | 2 |
| checks_for tri-state: unmanaged collapsed into protection-only | 7 |
| mutual exclusion removed (--check honours --allow-check-removal) | 2 |
| mutual exclusion downgraded from exit 2 to exit 1 | 1 |
| G4: explicitly-named unmanaged repo no longer an error | 3 |
| G4: EXPLICIT_REPOS tracking lost after the -- terminator | 3 |
| protection-only body: enforce_admins true -> false | 1 |
| has-checks default: enforce_admins false -> true | 1 |
| registry enforce_admins ignores the baseline (hardcoded false) | 2 |
| protection PUT attempted before the settings PATCH | 3 |
| registry app_id pinning dropped (checks -> contexts) | 5 |
| UNREGISTERED: repo found but flag never accumulated | 2 |
| UNREGISTERED: exclusion subtraction removed (excluded repos reported) | 5 |
| UNREGISTERED: unreadable org listing no longer an error (fail-open) | 2 |
| UNREGISTERED: escalated to fatal exit 2 | 2 |
| UNREGISTERED: org enumerated even when repos are named | 6 |
| UNREGISTERED: accounted-for-repo sanity check removed | 2 |
| baseline: empty required accepted (would wipe every check) | 1 |
| baseline: status 3 (remote baseline) treated as protection-only (0) | 46 |
| baseline: app_id validation removed (any value accepted) | 6 |
| baseline: unreadable baseline not an error in --check | 1 |
| baseline: apply carries on silently when the baseline is unreadable | 23 |
| baseline: strict hardcoded true | 1 |
| baseline: raw media type not requested | 24 |
| baseline: control characters in a context accepted | 1 |
| baseline: app_id -1 / 0 accepted (positive check removed) | 3 |
| weakening guard: enforce_admins lowering not detected | 2 |
| weakening guard: app_id re-pin not detected | 1 |
| weakening guard: unreadable protection read not fatal | 1 |

(The 46-killer row is deliberately broad: if status 3 were ever read as 0 the
empty list would mean "protection-only" and `required_status_checks:null` would
wipe every registry check. It is a hazard guard, not a precision mutant.)

**Honest coverage:** only the assertions named in the table above are mutation-measured (acdp-ci#22 asked for the guards with zero coverage, not one mutant per assertion); every other assertion is unmeasured, not known-good. The per-mutant counts are as of 2026-10-09 and are re-measured on every run — the declared killer set must match exactly, so a stale count fails `mutants.sh` rather than rotting silently.

**The stub must log before it can refuse.** `bin/gh` used to exit on an unset
`$FIXTURES` *before* logging, which made every "makes zero gh calls at all"
assertion that runs without `$FIXTURES` pass whether or not the script called
gh. It now logs first; a direct stub test pins that.

Several of those counts (the original drift mutant's, the `enforce_admins`
and `app_id` bodies, the PATCH/PUT ordering) come from assertions that a
mutating call actually reached the `gh` stub — the strongest available form,
since they prove the destructive PUT happens rather than merely that an exit
code changed.

Each mutant **declares which tests must kill it**, and the killer set must
match exactly. Over-killing fails as loudly as under-killing: a mutant that
kills more than it should has usually broken something broader than the guard
it names, and the inflated number reads as extra confidence. A count is not
evidence.

Names come from a side channel (`FAILNAME_LOG`), never parsed out of the
`FAIL:` line — several test names legitimately contain `" -- "` themselves (the
`G4: --check -- <typo'd repo>` cases and the `#30` sweep name), so splitting on
that separator would truncate them, merge distinct tests into one, and make
the comparison quietly wrong in both directions.

A **control run** requires the unmutated suite to be green first. Without it,
every kill count could be an artifact of an already-red tree rather than of
the injected bug.

**The trap this harness is built around.** A mutation that fails to apply runs
the suite against unmodified code, sees zero failures, and reports "not
caught" — identical output to a genuinely missed bug, and wrong in the more
alarming direction. Every substitution therefore asserts it matched exactly
once, and an unapplied mutant exits 2 as a hard error rather than producing a
result. This is not hypothetical: it happened three times while writing this
file, each time reading as a clean pass.

All three failure paths are themselves verified: a wrong declared set reports
`MISMATCH` in both directions and exits 1, a red suite fails the control and
exits 2, and a stale anchor exits 2 leaving the target restored.

Same reason the fourth mutant exists at all. The third pins "a run that
learned nothing must not look like a finding"; the fourth pins the opposite
direction, that a *partial* failure must stay a finding. Pinning only one side
lets exit 1 and 2 collapse back together later, which is the failure being
guarded — an assertion of merely "non-zero" would accept either.

**Writing a new mutant.** Anchor on text unique enough to match exactly once,
and substitute the *whole* expression a guard depends on, not one branch of
it. Disabling a single `elif` in the fail-closed jq is not the B4 bug: the
next branch still rejects the same fixture (`null|type` is `"null"`, not
`"array"`), so the guard holds and the mutant proves nothing while appearing
to pass. That mistake initially reported 22 kills instead of the true 5,
because the crude splice broke jq outright — a trivially-caught mutant wearing
the costume of a subtle one.

Requires `python3` and `jq` (a missing one exits 2 as a broken environment, not a result).

Not wired into CI: this repo produces no check-runs on its own PRs, and the
harness rewrites `scripts/standardize.sh` in place (restored via `trap`, and
on abort). Run it by hand when changing a guard or an assertion around one.

**Known limit (UNREGISTERED, acdp-ci#19):** the stub ignores `--paginate`, so
"more than one page of org repos" is not exercised offline. It relies on real
`gh --paginate --jq` applying the filter per page (checked live with
`?per_page=2`: all repos still returned).
