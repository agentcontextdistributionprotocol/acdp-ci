#!/usr/bin/env bash
# standardize.sh — apply the uniform delivery guardrails to every acdp-* repo.
#
# Idempotent with respect to required_status_checks.contexts only — see
# "Known gaps" below for everything else this PUTs unconditionally. For each
# repo it: turns on squash + delete-branch-on-merge, and sets branch
# protection on the default branch with that repo's CI jobs as REQUIRED
# status checks (so auto-merge has something to wait on). Required-check
# names are per-repo (they must match each repo's real check-run names
# exactly) — declared in checks_for() below. Nothing in this script reads
# actual check-runs; an earlier version of this comment claimed checks were
# "verified against actual check-runs so a required check can never hang a
# PR" — that was never backed by code and is retracted. "Allow auto-merge"
# is enabled only for repos that have at least one required check — see the
# protection-only branch below.
#
# --- The drift guard ---
# PUT .../branches/{b}/protection replaces required_status_checks.contexts
# WHOLESALE. If checks_for() below has drifted out of sync with what's live
# on GitHub (a check added to CI and required by hand, or left behind by an
# earlier run of a since-edited table), the next run silently deletes it —
# manifesting as a green PR with a missing gate, not an error. Before the
# first mutating call, the script reads live required contexts from
# GET /repos/{o}/{r}/branches/{b} (the branch *summary* — the SAME endpoint
# the CI-6 guards in .github/workflows/auto-merge.yml and bump-consume.yml
# already use; deliberately NOT the separate .../branches/{b}/protection
# endpoint, which 404s for four different states — unprotected branch,
# missing branch, missing repo, insufficient scope — separable only by
# string-matching the error body. The summary instead returns 200 with
# .protected=false for an unprotected branch, so "unprotected" is a
# positive signal and every non-200 is unambiguously fatal) and refuses to
# proceed if any live required context is absent from checks_for()'s
# declared list for that repo, unless --allow-check-removal is passed. This
# is a set difference, not equality: order and duplicates never matter, so
# a live list that is the declared list merely reordered is NOT drift.
#
# This guard catches exactly ONE defect axis: a live required check that
# the next PUT would silently drop. It does NOT catch the opposite axis — a
# real PR gate (a check-run CI actually produces) that was never added to
# checks_for() and so was never required at all. That axis is invisible to
# both --check and normal apply; finding it means comparing checks_for()
# against each repo's CI workflow by hand.
#
# The set difference is computed BOTH ways, as two distinct code paths:
#   extras  = live - declared -- a live required check the next PUT would
#             silently DROP. Blocks apply (unless --allow-check-removal);
#             in --check, accumulates into DRIFT and the exit code.
#   missing = declared - live -- a name checks_for() declares that isn't
#             live yet (typically: checks_for() was edited ahead of the
#             post-merge apply runbook). This is exactly what the next PUT
#             is about to ADD, so it must NEVER block apply. In --check
#             mode only, it is reported with its own "!! PENDING:" marker
#             and accumulates into a third, separately-tracked condition
#             (PENDING) that also makes --check's exit code non-zero --
#             otherwise --check would report "all in sync" while a
#             declared requirement silently never goes live.
#
# --allow-check-removal
#   Overrides the guard for a single invocation: proceeds with the PUT even
#   though it would drop a live required check that checks_for() doesn't
#   declare. Use only for an intentional removal. Apply mode only: combined
#   with --check it is rejected outright (exit 2) rather than silently
#   suppressing --check's drift report.
#
# --check / --dry-run (synonyms)
#   Runs the same guard against every named repo (or all managed repos by
#   default) and reports drift and pending-apply status, without making any
#   mutating call. Prints the live required contexts it read for every
#   surveyed repo — including repos with no drift — because a permission-
#   degraded read (e.g. a token missing contents:read) can produce a
#   payload indistinguishable from a genuinely unprotected branch, and "no
#   drift reported" is also exactly what a broken token looks like. An
#   unreadable repo is recorded as an error, distinct from drift and from a
#   pending-apply, and the sweep continues to the remaining repos rather
#   than aborting; the exit status reflects whatever accumulated (drift
#   and/or errors and/or pending-apply) only after the whole sweep
#   completes. --check needs only contents:read; apply needs admin.
#
# Portable to macOS's stock bash 3.2 (no associative arrays).
#
# Excluded on purpose:
#   acdp-rs      — already protected with its own (richer) config; do not clobber.
#   acdp-website — private repo; branch protection needs GitHub Pro or public.
#
# Protection-only (managed here, but with zero required checks):
#   acdp-ci  — as of CI-8 (drift-check.yml), not every workflow here is
#              `workflow_call`-only any more -- but drift-check.yml triggers
#              only on `schedule`/`workflow_dispatch`, neither of which ever
#              runs as a PR-triggered event, and the scheduled run executes
#              on the default branch only -- so acdp-ci produces no
#              check-runs from PR events, and its protection-only status
#              (nothing to require) is unaffected. (A deliberate operator
#              `workflow_dispatch` run against a PR's head branch does
#              create check-runs on that head SHA, surfacing in that PR's
#              checks -- but that's an operator act, not something this
#              workflow's triggers do on their own, and acdp-ci requires
#              zero checks regardless.)
#              As of wave 5, this branch's body sets enforce_admins:true (the
#              other branch below, for repos with required checks, is
#              unchanged at enforce_admins:false — those repos' maintainer
#              would otherwise be blocked by their own CI). What this
#              protection body actually constrains: with
#              required_pull_request_reviews:null and restrictions:null, `main`
#              is NOT PR-gated and carries no push restriction -- this is
#              force-push and branch-deletion protection only (now asserted
#              explicitly, see allow_force_pushes/allow_deletions below), plus
#              (with enforce_admins:true) binding that to the maintainer too.
#              The acdp-deps-bot App still has Contents:write and CAN push a
#              normal (non-force) commit straight to `main` -- that gap is
#              real and not closed by this change; PR-gating would close it
#              but is out of scope here. And since the `v1` tag is
#              force-moved to wherever `main` points, protecting `main` from
#              force-push/deletion is the upstream half of protecting `v1`
#              (the ruleset in DELIVERY-STANDARD.md is the other half).
#   .github  — the org's `.github` repo has no `.github/workflows/` directory at
#              all (verified via the contents API) — same reasoning as acdp-ci.
# Neither gets allow_auto_merge=true: auto-merge.yml's `gh pr merge --auto` would
# merge a PR instantly on a branch with no required checks — a hazard, not a
# convenience, on a zero-check repo. auto-merge.yml and bump-consume.yml both
# now carry their own guard against exactly this (CI-6, Wave 4) — refusing to
# arm auto-merge unless this same script has configured required status checks
# on the target branch — but leaving allow_auto_merge:false here is still the
# right call for these two repos specifically, since neither script-managed
# option even applies (acdp-ci/.github have no CI job to require in the first
# place). Both repos are allow_auto_merge:false on GitHub today, so leaving
# auto-merge off here codifies the status quo rather than changing behaviour.
#
# Known gaps — every run also resets the following to GitHub's defaults,
# regardless of what was live before, because the protection PUT body below
# only ever sets required_status_checks, enforce_admins,
# required_pull_request_reviews, restrictions, allow_force_pushes, and
# allow_deletions (the last two now asserted explicitly as of wave 5, rather
# than relying on undocumented PUT defaults): strict (only set on the
# has-checks branch), required_status_checks.checks (the per-check app_id
# pinning: acdp-registry-rs is PUT with `checks`, each pinned to the app_id
# in its own committed baseline (see registry_baseline()); acdp-control-plane is MIXED live,
# one check pinned and two app_id:null — a prior contexts-only PUT already
# widened two of its checks to "any app", and every other repo still gets a
# contexts-only PUT that does the same),
# required_linear_history, required_conversation_resolution, lock_branch,
# block_creations, allow_fork_syncing. And, as noted above, the drift guard
# cannot see a real PR gate that was never added to checks_for() in the
# first place (axis C).
#
# enforce_admins is itself a known gap in the drift guard: live_contexts()
# and the drift comparison above look at required_status_checks.contexts
# only, so a future hand-edit or out-of-band PUT that flips enforce_admins
# back to false on a protection-only repo is invisible to both --check and
# a normal apply — nothing here would notice or restore it. Extending the
# guard to compare the full protection object (not just contexts) is a
# named wave-6 item, not attempted in this change.
# (Partial exception: for acdp-registry-rs, whose baseline file can be edited
# without review, apply refuses to LOWER enforce_admins or re-pin a live check to
# another app unless --allow-check-removal is passed; --check reports it as DRIFT.
# See baseline_regressions().)
#
# acdp-registry-rs's required checks are NOT declared in checks_for(): that repo
# commits its own baseline (.github/required-checks.json, which its daily
# protection-drift guard already enforces), and this script reads it via the
# contents API (checks_for() status 3 -> registry_baseline()). One source of
# truth: contexts, per-check app_id, strict and enforce_admins all come from
# that file, and a baseline that is unreadable, malformed, has an empty
# `required` list, a blank/control-character context, a non-positive or
# non-integer app_id, or a non-array advisory_pending is refused, never defaulted.
# Trust note: a merge to that repo's main now decides what an admin-token apply
# PUTs there; weakening the list shows up as DRIFT, an empty one is rejected.
#
# The repo list itself is checked too (acdp-ci#19): in the default --check
# sweep only (never when repos are named, never in apply), the org's repos are
# enumerated and any non-archived one that is in neither ALL_REPOS nor
# EXCLUDED_REPOS (each exclusion carries a reason, see excluded_reason()) is
# reported as `!! UNREGISTERED:` and makes --check exit 1. An unreadable or
# empty listing, or an accounted-for repo missing from it, is an ERRORS finding
# rather than a clean pass. Blind spot: if the App installation is ever
# narrowed to "selected repositories", an uninstalled new repo is invisible
# here; it is only noticed when an accounted-for repo drops out of the listing.
#
# Prereqs: gh auth with admin:org for apply; contents:read is enough to run
#          --check. Org secrets (App id/key) are set separately.
# Usage: ./standardize.sh [--check|--dry-run] [--allow-check-removal] [repo ...]
#        ./standardize.sh -h | --help
#        (default repo list, and order flags may appear in: see below)
set -euo pipefail

ORG=agentcontextdistributionprotocol
# Word-split unquoted below (`for repo in $repos`) under default globbing — every
# name here must stay free of whitespace and glob metacharacters. `.github`'s
# leading dot is not one (no unquoted glob expands it), but this is a property of
# the specific names, not something the script enforces.
ALL_REPOS="acdp-control-plane acdp-registry-rs acdp-playground acdp-verifier-py acdp-ui-console agentcontextdistributionprotocol acdp-ci .github"

# Org repos that are DELIBERATELY not managed here, each with a reason. This is
# what makes the UNREGISTERED check (acdp-ci#19) mean something: a repo absent
# from ALL_REPOS is either listed here with a reason, or it is reported. If the
# exclusions were merely "whatever is not in ALL_REPOS" the check would compare
# a list against itself.
EXCLUDED_REPOS="acdp-rs acdp-website"
excluded_reason() {
  case "$1" in
    acdp-rs) echo "self-governed: its own required checks and crypto-critical Dependabot gate (acdp-rs#351); a contexts-only PUT from here would replace them wholesale" ;;
    acdp-website) echo "private repo on a free plan: branch protection and rulesets both 403" ;;
    *) return 1 ;;
  esac
}
# Config self-check: an excluded repo that is also managed would make the
# check contradict itself, and an exclusion without a reason is not an
# exclusion. A config error is exit 2 (not a result), like a bad flag.
for _x in $EXCLUDED_REPOS; do
  case " $ALL_REPOS " in
    *" $_x "*) echo "standardize.sh: config error: '$_x' is in both ALL_REPOS and EXCLUDED_REPOS" >&2; exit 2 ;;
  esac
  excluded_reason "$_x" >/dev/null || { echo "standardize.sh: config error: EXCLUDED_REPOS entry '$_x' has no excluded_reason()" >&2; exit 2; }
done

usage() {
  cat <<'EOF'
Usage: standardize.sh [--check|--dry-run] [--allow-check-removal] [repo ...]
       standardize.sh -h | --help

  --check, --dry-run     Read-only: report required-check drift per repo,
                          make zero mutating calls. Needs only contents:read.
  --allow-check-removal  Apply mode only: proceed with the protection PUT
                          even if it would drop a live required check that
                          checks_for() doesn't declare.
  -h, --help             Show this help and exit 0.
  --                      End of flags; every following argument is a repo.

With no repo arguments, all managed repos are processed. Apply mode (the
default, no --check) needs gh auth with admin:org.

Exit codes (a contract -- .github/workflows/drift-check.yml routes on these):
  0  --check only: surveyed everything, nothing drifted, nothing pending.
  1  A RESULT. The survey ran and found something worth reporting: drift,
     a pending declared check, an UNREGISTERED org repo (neither managed nor
     deliberately excluded; full sweep only), or some (but not all) repos
     unreadable.
     drift-check.yml files/updates a tracking issue and leaves the job green.
  2  NOT a result. The check could not run or learned nothing: bad flags, an
     explicitly-named unmanaged repo, a missing dependency, or every surveyed
     repo unreadable. drift-check.yml hard-fails the job.
Keep 1 and 2 distinct. Collapsing them makes a monitor that cannot see report
identically to one that looked and found nothing.
EOF
}

# Emits one required check-name per line for the given repo (non-zero if unknown).
# A repo may legitimately have zero required checks: printing nothing and
# returning 0 means "protection-only, no required checks" — distinct from
# returning 1, which means "not in the managed set at all, skip entirely".
# Returning 3 means "managed, and its required checks live in the repo's own
# committed baseline" (see registry_baseline()) — the list is NOT printed here.
# This is a distinct status on purpose: if a caller ever treated 3 as 0, the
# empty output would read as "protection-only" and PUT required_status_checks
# :null onto a repo with real checks.
checks_for() {
  case "$1" in
    acdp-control-plane)
      printf '%s\n' "lint + tsc + jest (unit, coverage-gated)" "jest integration (Postgres)" "docker build (no push)" ;;
    acdp-registry-rs)  # remote baseline: its committed .github/required-checks.json
      return 3 ;;
    acdp-playground)
      printf '%s\n' "pytest + smoke (py3.12)" "pytest + smoke (py3.13)" "docker image builds" ;;
    acdp-verifier-py)
      printf '%s\n' "conformance + tests + types (3.11)" "conformance + tests + types (3.12)" "conformance + tests + types (3.13)" "conformance + tests + types (3.14)" ;;
    acdp-ui-console)
      printf '%s\n' "Lint · Typecheck · Test · Build" ;;
    agentcontextdistributionprotocol)  # the spec/RFC repo
      printf '%s\n' "All Validations Passed" "Validate Schemas, Examples, and Conformance" ;;
    acdp-ci|.github)  # protection-only — see header comment
      return 0 ;;
    *) return 1 ;;
  esac
}

# registry_baseline <repo> — for a repo whose required checks live in ITS OWN
# committed baseline (checks_for() returns 3; today only acdp-registry-rs, whose
# .github/required-checks.json is already compared daily by its own drift
# guard), read and validate that file and set the globals the protection PUT
# is built from:
#   BASE_CONTEXTS  one required context per line
#   BASE_BODY      {strict, enforce_admins, pending_settings, required:[{context,app_id}]}
# Returns non-zero (message on stderr) if the file is unreadable or anything
# about it is malformed. Never defaults: a baseline that cannot be trusted must
# not become a protection PUT. In particular an empty `required` would read as
# "no checks" and `required_status_checks` would be wiped, and an `app_id` of
# null has no faithful PUT mapping (omitted = "auto-select the newest app",
# -1 = "any app"), so both are rejected rather than guessed. Unknown top-level
# keys (`_comment`, `tag_ruleset`, …) are tolerated.
# Called as `if ! registry_baseline "$repo"; then …`, so -e is OFF for the body.
registry_baseline() {
  local repo="$1" raw
  # The raw media type returns the file itself; without it the contents API
  # returns a base64 envelope, which fails validation below (fail closed).
  if ! raw=$(gh api "repos/$ORG/$repo/contents/.github/required-checks.json" -H 'Accept: application/vnd.github.raw' 2>/dev/null); then
    echo "!! $repo: cannot read .github/required-checks.json (missing file, missing repo, or insufficient scope)" >&2
    return 1
  fi
  if ! BASE_BODY=$(printf '%s' "$raw" | jq -c '
    def bad(m): error(m);
    if type != "object" then bad("not a JSON object") else . end
    | if (.strict | type) != "boolean" then bad("strict must be a boolean") else . end
    | if (.enforce_admins | type) != "boolean" then bad("enforce_admins must be a boolean") else . end
    | if (.pending_settings | type) != "boolean" then bad("pending_settings must be a boolean") else . end
    | if (.required | type) != "array" or (.required | length) == 0 then bad("required must be a non-empty array") else . end
    | if (.required | map(.context | type == "string" and length > 0 and (test("^\\s*$") | not) and (explode | map(. < 32 or . == 127) | any | not)) | all | not) then bad("every required context must be a non-empty string with no control characters (a newline would split into several names in the drift guard)") else . end
    | if (.required | map(.app_id | type == "number" and . == floor and . > 0 and . < 4503599627370496) | all | not) then bad("every required app_id must be a positive integer (null, 0, -1 = any app, and non-integers are rejected)") else . end
    | if ((.required | map(.context) | unique | length) != (.required | length)) then bad("duplicate required contexts") else . end
    | ((if has("advisory_pending") then .advisory_pending else [] end) as $adv
       | if ($adv | type) != "array" or ($adv | map(type == "string") | all | not) then bad("advisory_pending must be an array of strings") else . end
       | if ([.required[].context] - ([.required[].context] - $adv) | length) > 0 then bad("a context is both required and advisory_pending") else . end)
    | {strict, enforce_admins, pending_settings, required: (.required | map({context, app_id}))}
  ' 2>/dev/null); then
    echo "!! $repo: .github/required-checks.json is not a valid baseline (unparseable, wrong shape, empty required, blank/control-character context, bad app_id, or bad advisory_pending) — refusing to derive protection from it" >&2
    return 1
  fi
  BASE_CONTEXTS=$(printf '%s' "$BASE_BODY" | jq -r '.required[].context')
}

# default_branch <repo> — echoes the repo's default branch name on stdout;
# returns 1 (prints nothing usable) if the repo can't be read, or if
# .default_branch resolves empty/null, so callers never PUT to
# branches/null/protection.
#
# Called as `if ! branch=$(default_branch "$repo"); then …`, so -e is OFF
# for this entire function body (see live_contexts() below for why) — every
# command here checks its own exit status explicitly.
default_branch() {
  local repo="$1"
  local errfile
  errfile=$(mktemp) || return 1
  trap 'rm -f "$errfile"' RETURN
  local raw
  if ! raw=$(gh api "repos/$ORG/$repo" --jq '.default_branch // empty' 2>"$errfile"); then
    echo "!! $repo: repos/$repo read failed: $(cat "$errfile")" >&2
    return 1
  fi
  if [ -z "$raw" ]; then
    echo "!! $repo: default_branch is empty/null -- refusing to protect branches/null" >&2
    return 1
  fi
  printf '%s\n' "$raw"
  return 0
}

# live_contexts <repo> <branch> — echoes the live required-status-check
# contexts for that branch as a compact JSON array on stdout; returns 1
# (NEVER prints "[]" on failure) when live state can't be determined for
# any reason: unreadable branch, malformed payload, or a permission-
# degraded read. Reads GET /repos/{o}/{r}/branches/{b} — see the header
# comment for why that endpoint and not .../protection.
#
# Call site MUST be `if ! live=$(live_contexts …); then …` (never a bare
# assignment) — but that same construction means `set -e` is suppressed for
# this ENTIRE function body, including the gh/jq calls inside it: a failing
# `gh api` would otherwise fall through silently into `jq` on empty input.
# So every command below checks its own exit status explicitly instead of
# relying on -e, and `local var` / assignment are kept on separate lines so
# `local`'s own (always-zero) exit status can never mask a failed
# substitution.
live_contexts() {
  local repo="$1" branch="$2"
  local errfile
  errfile=$(mktemp) || return 1
  trap 'rm -f "$errfile"' RETURN

  local raw
  if ! raw=$(gh api "repos/$ORG/$repo/branches/$branch" 2>"$errfile"); then
    echo "!! $repo: branches/$branch read failed: $(cat "$errfile")" >&2
    return 1
  fi

  local result
  if ! result=$(printf '%s' "$raw" | jq -c '
        if (.protected|type) != "boolean" then error("no .protected -- unexpected payload")
        elif .protected == false then []
        elif (.protection.required_status_checks|type) != "object"
          then error("protected=true but no required_status_checks object -- read may be permission-degraded")
        elif (.protection.required_status_checks.contexts|type) != "array"
          then error("contexts is not an array")
        else .protection.required_status_checks.contexts end
      ' 2>"$errfile"); then
    echo "!! $repo: live required checks unreadable: $(cat "$errfile")" >&2
    return 1
  fi

  # A 200 with an empty body makes jq produce no output at all: $result is
  # then "" with an exit status of 0, which would otherwise fall through to
  # `return 0` below and violate this function's own contract ("never
  # prints [] on failure" -- an empty string isn't "[]" literally, but it's
  # just as unusable to the caller, and today's safety net downstream is
  # only the `--argjson` call rejecting empty input by accident). Fail
  # closed on purpose instead of relying on that accident.
  if [ -z "$result" ]; then
    echo "!! $repo: live required checks read produced empty output -- cannot determine live state" >&2
    return 1
  fi

  printf '%s\n' "$result"
  return 0
}

# baseline_regressions REPO BRANCH -> prints one line per way the repo's own
# baseline file would WEAKEN live protection: enforce_admins true -> false, or a
# live check pinned to app X re-pinned to a different app Y. (Null -> pinned is a
# strengthening and not reported.) Needs the protection endpoint because the
# branch payload carries no enforce_admins. Fails closed (return 1) when either
# read is unusable: a guard that cannot see live state must not wave a PUT through.
baseline_regressions() {
  local repo="$1" branch="$2" prot br
  if ! prot=$(gh api "repos/$ORG/$repo/branches/$branch/protection" 2>/dev/null); then
    echo "!! $repo: branches/$branch/protection read failed" >&2
    return 1
  fi
  if ! br=$(gh api "repos/$ORG/$repo/branches/$branch" 2>/dev/null); then
    echo "!! $repo: branches/$branch read failed" >&2
    return 1
  fi
  jq -nr --argjson base "$BASE_BODY" --argjson prot "$prot" --argjson br "$br" '
    ( if ($prot.enforce_admins.enabled | type) != "boolean" then error("no enforce_admins.enabled in protection payload") else . end
    | [ (if $prot.enforce_admins.enabled == true and $base.enforce_admins == false
         then "enforce_admins true -> false" else empty end),
        ( ($br.protection.required_status_checks.checks // [])[] as $l
        | ($base.required[] | select(.context == $l.context)) as $b
        | select($l.app_id != null and $l.app_id != $b.app_id)
        | "check \"\($l.context)\" app_id \($l.app_id) -> \($b.app_id)" ) ]
    | .[] )' 2>/dev/null
}

# --- flag parsing: every argument, not just leading ones -----------------
CHECK_MODE=0
ALLOW_CHECK_REMOVAL=0
end_of_flags=0
repos=""
# EXPLICIT_REPOS distinguishes "repo(s) named on the command line" from "no
# repo args, fell back to the default ALL_REPOS sweep" -- see the CHECK_MODE
# use below (an explicitly-named unmanaged repo must not exit 0 having read
# nothing; the default full sweep must not change behaviour).
EXPLICIT_REPOS=0
for arg in "$@"; do
  if [ "$end_of_flags" -eq 1 ]; then
    if [ -z "$repos" ]; then repos="$arg"; else repos="$repos $arg"; fi
    EXPLICIT_REPOS=1
    continue
  fi
  case "$arg" in
    --)
      end_of_flags=1
      ;;
    --check|--dry-run)
      CHECK_MODE=1
      ;;
    --allow-check-removal)
      ALLOW_CHECK_REMOVAL=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "standardize.sh: unknown flag: $arg" >&2
      usage >&2
      exit 2
      ;;
    *)
      if [ -z "$repos" ]; then repos="$arg"; else repos="$repos $arg"; fi
      EXPLICIT_REPOS=1
      ;;
  esac
done
if [ -z "$repos" ]; then repos="$ALL_REPOS"; fi

# --check is read-only by contract; --allow-check-removal only ever matters
# at a mutation. Honoring both together (checks_for BEFORE CHECK_MODE) would
# let --check --allow-check-removal report "all repos in sync" while
# suppressing a real DRIFT report -- a monitor that can be told to lie is
# worse than no monitor. Reject the combination outright instead of merely
# reordering the precedence, so the contradiction can't happen at all.
if [ "$CHECK_MODE" -eq 1 ] && [ "$ALLOW_CHECK_REMOVAL" -eq 1 ]; then
  echo "standardize.sh: --check and --allow-check-removal are mutually exclusive (--allow-check-removal is apply-mode only)" >&2
  exit 2
fi

# A missing tool is NOT a finding. Without this preflight, an absent `gh` or
# `jq` makes every repo's read fail, which sets ERRORS and exits 1 -- the same
# code as "surveyed everything, found drift". drift-check.yml treats exit 1 as
# a reportable result, so the job would go GREEN and file a routine-looking
# issue while the check had in fact never run. Exit 2 instead: the workflow's
# case statement already routes anything outside {0,1} to a hard job failure.
for _tool in gh jq; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    echo "standardize.sh: required command '$_tool' not found -- the check cannot run (this is a broken environment, not a drift finding)" >&2
    exit 2
  fi
done

DRIFT=0
ERRORS=0
PENDING=0
UNREGISTERED=0
# ERRORS is a flag, so one unreadable repo and every repo unreadable look
# identical in the summary. Count them: total unreadable == total surveyed
# means the survey as a whole failed (a degraded token, a network blackhole),
# which must not be reported as a per-repo finding. See the SURVEYED check
# at the end of --check.
SURVEYED=0
UNREADABLE=0

for repo in $repos; do
  cf_rc=0
  lines=$(checks_for "$repo") || cf_rc=$?
  if [ "$cf_rc" -ne 0 ] && [ "$cf_rc" -ne 1 ] && [ "$cf_rc" -ne 3 ]; then
    echo "!! $repo: checks_for() returned unexpected status $cf_rc — internal error" >&2
    exit 2
  fi
  if [ "$cf_rc" -eq 1 ]; then
    echo "!! $repo: not in the standard set (excluded/unknown) — skipping"
    # An explicitly-named repo (not the default ALL_REPOS sweep) that turns
    # out to be unmanaged is almost always a typo -- e.g. `--check
    # acdp-registryrs` -- and CHECK_MODE must not exit 0 having surveyed
    # nothing. The default no-arg sweep is unaffected: it never names an
    # unmanaged repo in the first place (ALL_REPOS excludes acdp-rs and
    # acdp-website on purpose), and checks_for()'s tri-state skip itself is
    # unchanged either way.
    if [ "$CHECK_MODE" -eq 1 ] && [ "$EXPLICIT_REPOS" -eq 1 ]; then
      ERRORS=1
    fi
    continue
  fi
  SURVEYED=$((SURVEYED + 1))

  # Remote baseline (checks_for() == 3): the repo's own committed file is the
  # source of truth. Read BEFORE the drift guard / any mutation. In --check an
  # unreadable or invalid baseline is an unreadable repo (a single-repo run
  # exits 2, a sweep exits 1 naming it); in apply it aborts with zero mutations.
  baseline=0
  declared_src="checks_for()"
  if [ "$cf_rc" -eq 3 ]; then
    declared_src=".github/required-checks.json"
    baseline=1
    if ! registry_baseline "$repo"; then
      if [ "$CHECK_MODE" -eq 1 ]; then
        ERRORS=1
        UNREADABLE=$((UNREADABLE + 1))
        continue
      else
        echo "!! $repo: aborting before any mutation" >&2
        exit 1
      fi
    fi
    lines="$BASE_CONTEXTS"
    # Defense in depth: validation rejects an empty/whitespace-only list, but if
    # the derived list were ever empty the protection-only branch below would
    # PUT required_status_checks:null onto a repo that has real checks.
    if [ -z "$lines" ]; then
      echo "!! $repo: baseline produced no required contexts — refusing the protection-only path" >&2
      if [ "$CHECK_MODE" -eq 1 ]; then
        ERRORS=1
        UNREADABLE=$((UNREADABLE + 1))
        continue
      fi
      exit 1
    fi
  fi

  if ! branch=$(default_branch "$repo"); then
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      UNREADABLE=$((UNREADABLE + 1))
      continue
    else
      echo "!! $repo: cannot determine default branch — aborting before any mutation" >&2
      exit 1
    fi
  fi
  echo "== $repo (@$branch) =="

  if [ -z "$lines" ]; then
    # Protection-only: no required checks to gate on, so no auto-merge
    # either (see "Protection-only" in the header comment above). This PUT
    # sets required_status_checks:null, i.e. removes every required check —
    # so contexts_json must be the empty set here too: any live required
    # check on a "protection-only" repo MUST still block below, and
    # contexts_json is otherwise only assigned in the `else` branch — under
    # `set -u` a skipped assignment here would abort the script instead.
    auto_merge=false
    contexts_json='[]'
    protection_json='{"required_status_checks":null,"enforce_admins":true,"required_pull_request_reviews":null,"restrictions":null,"allow_force_pushes":false,"allow_deletions":false}'
  else
    auto_merge=true
    contexts_json=$(printf '%s' "$lines" | jq -R . | jq -sc .)
    if [ "$baseline" -eq 1 ]; then
      # strict, enforce_admins and every check's app_id come from the repo's
      # own baseline; PUT takes `checks` (pinned) OR `contexts`, not both.
      echo "   $repo: baseline read from .github/required-checks.json ($(printf '%s' "$BASE_BODY" | jq -r '"\(.required | length) checks, enforce_admins=\(.enforce_admins), pending_settings=\(.pending_settings)"'))"
      protection_json=$(printf '%s' "$BASE_BODY" | jq -c '{
        required_status_checks: { strict: .strict, checks: .required },
        enforce_admins: .enforce_admins,
        required_pull_request_reviews: null,
        restrictions: null,
        allow_force_pushes: false,
        allow_deletions: false
      }')
    else
      protection_json=$(jq -nc --argjson ctx "$contexts_json" '{
        required_status_checks: { strict: true, contexts: $ctx },
        enforce_admins: false,
        required_pull_request_reviews: null,
        restrictions: null,
        allow_force_pushes: false,
        allow_deletions: false
      }')
    fi
  fi

  # --- drift guard: must run BEFORE the first mutating call, so --check
  # mutates nothing and a blocked apply never leaves allow_auto_merge=true
  # half-set against stale required checks. ---
  if ! live=$(live_contexts "$repo" "$branch"); then
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      UNREADABLE=$((UNREADABLE + 1))
      continue
    else
      echo "!! $repo: cannot determine live required checks — aborting before any mutation" >&2
      exit 1
    fi
  fi
  echo "   $repo: live required checks = $live"

  if ! extras=$(jq -nc --argjson live "$live" --argjson want "$contexts_json" '$live - $want'); then
    echo "!! $repo: could not compute required-check drift (unexpected JSON)" >&2
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      UNREADABLE=$((UNREADABLE + 1))
      continue
    else
      exit 1
    fi
  fi
  extras_len=$(printf '%s' "$extras" | jq 'length')

  if [ "$extras_len" -gt 0 ]; then
    extras_list=$(printf '%s' "$extras" | jq -r 'join(", ")')
    if [ "$ALLOW_CHECK_REMOVAL" -eq 1 ]; then
      echo "!! $repo: --allow-check-removal set — proceeding despite live required check(s) not in $declared_src: $extras_list"
    elif [ "$CHECK_MODE" -eq 1 ]; then
      echo "!! DRIFT: $repo: live required check(s) not declared in $declared_src — would be DROPPED by the next PUT: $extras_list"
      DRIFT=1
      # Deliberately NOT `continue` here: --check must still compute and
      # report `missing` (below) for this same repo before moving on, so a
      # repo with BOTH extras and missing prints both markers in one pass.
      # Apply mode never reaches this branch without exiting above (drift
      # blocks apply unconditionally, same as before this change).
    else
      echo "!! DRIFT: $repo: live required check(s) not declared in $declared_src — would be DROPPED by the next PUT: $extras_list (use --allow-check-removal to override)" >&2
      exit 1
    fi
    # extras_len > 0: something live either isn't declared (DRIFT, reported
    # above) or was explicitly allowed via --allow-check-removal — either
    # way "nothing live would be dropped" is not a true claim, so the
    # extras-axis message below is suppressed for this repo.
    extras_clean=0
  else
    extras_clean=1
  fi

  # --- weakening guard (baseline repos): the repo's own file may not quietly
  # lower enforce_admins or re-pin a live check to another app. Same override
  # and same DRIFT/exit contract as the extras axis above. ---
  if [ "$baseline" -eq 1 ]; then
    if ! regress=$(baseline_regressions "$repo" "$branch"); then
      if [ "$CHECK_MODE" -eq 1 ]; then
        ERRORS=1
        UNREADABLE=$((UNREADABLE + 1))
        continue
      fi
      echo "!! $repo: cannot compare the baseline against live protection — aborting before any mutation" >&2
      exit 1
    fi
    if [ -n "$regress" ]; then
      regress_list=$(printf '%s' "$regress" | paste -sd ';' - | sed 's/;/; /g')
      if [ "$ALLOW_CHECK_REMOVAL" -eq 1 ]; then
        echo "!! $repo: --allow-check-removal set — proceeding despite the baseline weakening live protection: $regress_list"
      elif [ "$CHECK_MODE" -eq 1 ]; then
        echo "!! DRIFT: $repo: $declared_src would WEAKEN live protection on the next apply: $regress_list"
        DRIFT=1
      else
        echo "!! DRIFT: $repo: $declared_src would WEAKEN live protection: $regress_list (use --allow-check-removal to override)" >&2
        exit 1
      fi
    fi
  fi

  # --- missing = declared - live: checks_for() lists a name that isn't
  # live yet (e.g. checks_for() was edited ahead of the post-merge apply
  # runbook). This is the OPPOSITE axis from extras and must never be
  # conflated with it: extras is what the next PUT would silently DROP;
  # missing is what the next PUT is about to ADD. Computed the same way
  # (jq array subtraction) and with the same fail-closed handling — a jq
  # failure here is recorded as an error / aborts, never treated as an
  # empty "nothing missing" result. ---
  if ! missing=$(jq -nc --argjson live "$live" --argjson want "$contexts_json" '$want - $live'); then
    echo "!! $repo: could not compute pending-apply status (unexpected JSON)" >&2
    if [ "$CHECK_MODE" -eq 1 ]; then
      ERRORS=1
      UNREADABLE=$((UNREADABLE + 1))
      continue
    else
      exit 1
    fi
  fi
  missing_len=$(printf '%s' "$missing" | jq 'length')

  if [ "$missing_len" -gt 0 ]; then
    missing_list=$(printf '%s' "$missing" | jq -r 'join(", ")')
    # A repo can be reported here with a declared-but-not-live check, so
    # the extras-axis message must not claim "in sync" — that would read
    # as contradicting the PENDING line below. State only what the extras
    # check actually verified (nothing live would be dropped), scoped to
    # that one axis.
    if [ "$extras_clean" -eq 1 ]; then
      echo "   $repo: no live check would be dropped"
    fi
    # In --check mode ONLY this accumulates into the exit code: it is a
    # report consumed by the monitor, not a block. In APPLY mode this must
    # NEVER block — the upcoming PUT is exactly what adds these, so the
    # message below is informational and PENDING is never set.
    echo "!! PENDING: $repo: declared but not yet live (run apply): $missing_list"
    if [ "$CHECK_MODE" -eq 1 ]; then
      PENDING=1
    fi
  else
    # Nothing extra and nothing missing: the repo genuinely is in sync.
    if [ "$extras_clean" -eq 1 ]; then
      echo "   $repo: required checks in sync (nothing live would be dropped)"
    fi
    echo "   $repo: nothing pending (every declared check is already live)"
  fi

  if [ "$CHECK_MODE" -eq 1 ]; then
    continue
  fi

  # Named window (not a blocked apply — the drift guard above already
  # covers that case): if this PATCH succeeds and the PUT below then fails,
  # `set -e` aborts the script leaving allow_auto_merge=true applied on a
  # repo whose branch protection was NOT updated to match. Not closed here
  # — swapping the call order would just trade it for the opposite gap
  # (protection updated, auto-merge flag stale) — but contained: the CI-6
  # guards in auto-merge.yml and bump-consume.yml both refuse to arm
  # auto-merge on a branch without a live required status check, so a repo
  # caught in this window can't actually auto-merge unsupervised, and
  # `apply` (no --check) is a supervised manual operation, not something
  # that runs unattended.
  gh api -X PATCH "repos/$ORG/$repo" \
    -F allow_auto_merge="$auto_merge" -F allow_squash_merge=true -F delete_branch_on_merge=true \
    --jq '"  auto-merge=\(.allow_auto_merge) squash=\(.allow_squash_merge) delete-branch=\(.delete_branch_on_merge)"'

  printf '%s' "$protection_json" | gh api -X PUT "repos/$ORG/$repo/branches/$branch/protection" --input - \
      --jq 'if .required_status_checks then "  required checks: \((.required_status_checks.contexts // [.required_status_checks.checks[].context]) | join(", "))" else "  required checks: (none — protection-only)" end'
done

if [ "$CHECK_MODE" -eq 1 ]; then
  # Every surveyed repo failed to read. That is not eight independent findings
  # -- it is one systemic failure (a degraded/expired token, gh unauthenticated,
  # the API unreachable), and reporting it as a finding would file an issue and
  # leave the job green, which is precisely the permission-degraded case this
  # guard exists to make visible. Exit 2 so drift-check.yml hard-fails instead.
  if [ "$SURVEYED" -gt 0 ] && [ "$UNREADABLE" -eq "$SURVEYED" ]; then
    echo "--check: FATAL: all $SURVEYED surveyed repo(s) were unreadable -- this is a broken run, not a drift result (check gh auth and the token's contents:read grant); see '!!' lines above." >&2
    exit 2
  fi
  # The org-level registry check (acdp-ci#19). Only for the default full sweep:
  # naming repos on the command line is a targeted check, not a claim about the
  # whole org. Never in apply mode (that is the branch above). Runs AFTER the
  # all-unreadable fatal check so a dead token is still exit 2, not a finding.
  if [ "$EXPLICIT_REPOS" -eq 0 ]; then
    if ! listing=$(gh api --paginate "orgs/$ORG/repos" --jq '.[] | [.name, .archived, .fork] | @tsv' 2>/dev/null) || [ -z "$listing" ]; then
      echo "!! cannot enumerate org repos (orgs/$ORG/repos) -- UNREGISTERED check did not run"
      ERRORS=1
    else
      org_names=$(printf '%s\n' "$listing" | cut -f1)
      # Every repo we account for must exist in the listing; otherwise the
      # listing is truncated (token scope shrank), a repo was renamed, or an
      # exclusion went stale -- and "nothing unregistered" would be a guess.
      for acct in $ALL_REPOS $EXCLUDED_REPOS; do
        if ! printf '%s\n' "$org_names" | grep -qxF -- "$acct"; then
          echo "!! org listing does not contain accounted-for repo '$acct' (renamed/deleted/stale exclusion, or the listing is incomplete) -- UNREGISTERED check is not trustworthy"
          ERRORS=1
        fi
      done
      while IFS=$'\t' read -r name archived fork; do
        [ -z "$name" ] && continue
        case " $ALL_REPOS $EXCLUDED_REPOS " in *" $name "*) continue ;; esac
        if [ "$archived" = "true" ]; then
          echo "   ignoring archived org repo: $name"
          continue
        fi
        echo "!! UNREGISTERED: $name is in the org but neither managed (ALL_REPOS) nor deliberately excluded (EXCLUDED_REPOS, with a reason) -- add it to one of them"
        UNREGISTERED=1
      done <<<"$listing"
    fi
  fi

  if [ "$DRIFT" -ne 0 ] || [ "$ERRORS" -ne 0 ] || [ "$PENDING" -ne 0 ] || [ "$UNREGISTERED" -ne 0 ]; then
    # Three independent conditions, tracked separately -- report exactly
    # which fired instead of a single blended "drift and/or errors" line
    # that would blur a pending-apply into a drift report (or vice versa).
    found=""
    if [ "$DRIFT" -ne 0 ]; then
      found="${found}drift (a live required check would be dropped); "
    fi
    if [ "$ERRORS" -ne 0 ]; then
      found="${found}unreadable repo(s); "
    fi
    if [ "$PENDING" -ne 0 ]; then
      found="${found}declared-but-not-yet-live check(s) pending an apply; "
    fi
    if [ "$UNREGISTERED" -ne 0 ]; then
      found="${found}unregistered org repo(s); "
    fi
    echo "--check: found: ${found}see '!!' lines above."
    exit 1
  fi
  echo "--check: all repos in sync -- nothing would be dropped, nothing pending apply."
  exit 0
fi

echo "done."
