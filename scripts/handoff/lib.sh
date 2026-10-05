#!/usr/bin/env bash
# Copied from seam/scripts/handoff/lib.sh; the only change: preflight.sh is optional (acdp-ci has none).
# Shared helpers for agent-authored handoff scripts (see docs/delivery/10-agent-standing-rules.md).
# A handoff script is written by Claude, reviewed and RUN BY A HUMAN for sensitive steps.
# Source this, then declare steps with `step "<what>" <cmd...>`; finish with `handoff_done`.
#
# Safety defaults: dry-run unless --apply; prod needs --apply AND typing the target name;
# every step logged to ~/.cache/seam/handoff/<script>-<ts>.log; secrets never echoed; set -euo pipefail.
set -euo pipefail

HANDOFF_NAME="${HANDOFF_NAME:-$(basename "${BASH_SOURCE[1]:-handoff}" .sh)}"
HANDOFF_TARGET="${HANDOFF_TARGET:-}"          # e.g. "prod:seam-runtime"; non-empty => typed confirmation
HANDOFF_APPLY=0; [ "${1:-}" = "--apply" ] && HANDOFF_APPLY=1
LOG_DIR="$HOME/.cache/seam/handoff"; mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/$HANDOFF_NAME-$(date +%Y%m%dT%H%M%S).log"
STEP_N=0

say()  { printf '%s\n' "$*" | tee -a "$LOG"; }
die()  { say "✗ $*"; exit 1; }

handoff_begin() {   # handoff_begin "<one-line purpose>" "<what could go wrong / rollback>"
  say "== $HANDOFF_NAME — $1"
  say "   rollback: ${2:-none stated}"
  say "   mode: $([ $HANDOFF_APPLY = 1 ] && echo APPLY || echo 'DRY-RUN (pass --apply to execute)')"
  if [ -x "$(dirname "${BASH_SOURCE[0]}")/../preflight.sh" ]; then "$(dirname "${BASH_SOURCE[0]}")/../preflight.sh" >/dev/null || die "preflight failed — run: scripts/preflight.sh --login"; fi
  if [ $HANDOFF_APPLY = 1 ] && [ -n "$HANDOFF_TARGET" ]; then
    printf 'Type the target to confirm [%s]: ' "$HANDOFF_TARGET"; read -r ans
    [ "$ans" = "$HANDOFF_TARGET" ] || die "confirmation mismatch — nothing changed"
  fi
}

step() {            # step "<description>" cmd args...   (idempotent commands only)
  local desc="$1"; shift; STEP_N=$((STEP_N+1))
  say "[$STEP_N] $desc"; say "    \$ $*"
  if [ $HANDOFF_APPLY = 1 ]; then "$@" 2>&1 | tee -a "$LOG"; else say "    (dry-run: skipped)"; fi
}

verify() {          # verify "<description>" cmd args...   (read-only; ALWAYS runs, even in dry-run)
  say "[verify] $1"; shift
  if "$@" >>"$LOG" 2>&1; then say "    ✓ ok"; else die "verification failed — see $LOG"; fi
}

handoff_done() { say "== done. log: $LOG"; }
