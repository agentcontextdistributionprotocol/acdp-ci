#!/usr/bin/env bash
# decide.sh — should the shared auto-merge workflow arm auto-merge on this
# Dependabot PR? (acdp-ci#30)
#
# Default (no deny inputs) is EXACTLY the workflow's historical rule: arm iff
# ALLOW_MAJOR=true or update-type is semver-patch/-minor. The deny inputs only
# ever ADD holds:
#   EXCLUDE_DEPENDENCIES  globs matched against every dependency name the PR updates
#   EXCLUDE_GROUPS        globs matched against the Dependabot group name
# Fail-safe: if a dependency deny list is set but the PR's dependency names
# cannot be determined, HOLD — never arm on a deny list that could not be
# evaluated.
#
# Limit (by design, documented): fetch-metadata only lists the dependencies
# Dependabot set out to update, not transitive lockfile movement. A name list
# is therefore weaker than a lockfile-diff gate (acdp-rs's
# scripts/dependabot-crypto-gate.sh); a repo that needs that keeps its own
# workflow rather than this one.
#
# Env in:  UPDATE_TYPE GROUP DEPS_JSON DEP_NAMES ALLOW_MAJOR EXCLUDE_DEPENDENCIES EXCLUDE_GROUPS
# Out ($GITHUB_OUTPUT if set, always stdout):
#   eligible=true|false   held_by_deny=true|false   reason=<text>
set -euo pipefail

UPDATE_TYPE="${UPDATE_TYPE:-}"
GROUP="${GROUP:-}"
DEPS_JSON="${DEPS_JSON:-}"
DEP_NAMES="${DEP_NAMES:-}"
ALLOW_MAJOR="${ALLOW_MAJOR:-false}"
EXCLUDE_DEPENDENCIES="${EXCLUDE_DEPENDENCIES:-}"
EXCLUDE_GROUPS="${EXCLUDE_GROUPS:-}"

emit() {
  echo "eligible=$1"
  echo "held_by_deny=$2"
  echo "reason=$3"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    { echo "eligible=$1"; echo "held_by_deny=$2"; echo "reason=$3"; } >> "$GITHUB_OUTPUT"
  fi
}

# Newline/comma separated list -> one pattern per line; trims, drops blanks and
# `# comments`; CR (CRLF or bare) is a line break.
patterns() {
  printf '%s\n' "$1" | tr ',\r' '\n\n' | sed -e 's/#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d'
}

# 1. The historical type rule.
if ! { [ "$ALLOW_MAJOR" = "true" ] || [ "$UPDATE_TYPE" = "version-update:semver-patch" ] || [ "$UPDATE_TYPE" = "version-update:semver-minor" ]; }; then
  emit false false "update-type '$UPDATE_TYPE' is held (majors wait for a human)"
  exit 0
fi

# 2. Group deny list.
if [ -n "$(patterns "$EXCLUDE_GROUPS")" ] && [ -n "$GROUP" ]; then
  while IFS= read -r pat; do
    # shellcheck disable=SC2053  # unquoted on purpose: $pat is a glob
    if [[ "$GROUP" == $pat ]]; then
      emit false true "dependency group '$GROUP' matches exclude-groups pattern '$pat'"
      exit 0
    fi
  done < <(patterns "$EXCLUDE_GROUPS")
fi

# 3. Dependency deny list.
if [ -n "$(patterns "$EXCLUDE_DEPENDENCIES")" ]; then
  names=""
  if [ -n "$DEPS_JSON" ]; then
    names="$(printf '%s' "$DEPS_JSON" | jq -r 'if type=="array" then .[].dependencyName // empty else empty end' 2>/dev/null || true)"
  fi
  if [ -z "$names" ] && [ -n "$DEP_NAMES" ]; then
    names="$(printf '%s' "$DEP_NAMES" | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sed '/^$/d')"
  fi
  if [ -z "$names" ]; then
    emit false true "exclude-dependencies is set but the PR's dependency names could not be determined — holding (fail-safe)"
    exit 0
  fi
  while IFS= read -r name; do
    while IFS= read -r pat; do
      # shellcheck disable=SC2053
      if [[ "$name" == $pat ]]; then
        emit false true "dependency '$name' matches exclude-dependencies pattern '$pat'"
        exit 0
      fi
    done < <(patterns "$EXCLUDE_DEPENDENCIES")
  done <<<"$names"
fi

emit true false "eligible"
