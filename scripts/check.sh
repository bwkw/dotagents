#!/usr/bin/env bash
# Every check this repository has, in one command.
#
#   scripts/check.sh          run everything
#   scripts/check.sh --fast   skip the behavioural suites (syntax and lint only)
#
# There are four checkers rather than one because they verify different things and fail for different
# reasons. This script exists so that is one thing to remember instead of four.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

FAST=0
[[ "${1:-}" == "--fast" ]] && FAST=1

c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
failed=()

step() { # step <label> <command...>
  local label="$1"; shift
  printf '%s── %s%s\n' "$c_dim" "$label" "$c_off"
  if "$@" >/tmp/dotagents-check.$$ 2>&1; then
    printf '%s✓%s %s\n' "$c_green" "$c_off" "$label"
  else
    printf '%s✗%s %s\n' "$c_red" "$c_off" "$label"
    sed 's/^/    /' /tmp/dotagents-check.$$ | tail -25
    failed+=("$label")
  fi
  rm -f /tmp/dotagents-check.$$
}

syntax() {
  local f
  for f in scripts/*.sh hooks/*.sh; do bash -n "$f" || return 1; done
  # macOS ships bash 3.2. These constructs parse on the CI runner and fail on the laptop.
  # This file is excluded because the pattern below names them, and a sweep that matches its own
  # pattern reports a failure that is not there -- which it did on the first run.
  ! grep -rqE --exclude=check.sh \
    '^[^#]*\b(mapfile|readarray)\b|declare -A|\$\{[a-zA-Z_]+\^\^\}|\$\{[a-zA-Z_]+,,\}' scripts/ hooks/
}

symlink_intact() {
  # Claude Code does not read AGENTS.md, so if CLAUDE.md stops being a symlink the always-loaded
  # layer silently drifts. `perl -pi` on a symlink replaces it with a regular file; this caught it.
  [[ "$(git ls-files -s CLAUDE.md | awk '{print $1}')" == "120000" ]] \
    && [[ "$(readlink CLAUDE.md)" == "AGENTS.md" ]]
}

step "shell syntax, and no bash 4 constructs" syntax
step "CLAUDE.md is still a symlink to AGENTS.md" symlink_intact
step "skills lint (invariants, budget, agents, override scope)" ./scripts/verify-skills.sh

if (( ! FAST )); then
  step "verify-gate behaviour"    ./scripts/test-verify-gate.sh
  step "lint-hook and lint scope" ./scripts/test-lint-hook.sh
  step "installer behaviour"      ./scripts/test-setup.sh
fi

echo
if (( ${#failed[@]} )); then
  printf '%s%d failed:%s %s\n' "$c_red" "${#failed[@]}" "$c_off" "${failed[*]}"
  exit 1
fi
printf '%s✓ all checks passed%s%s\n' "$c_green" "$( (( FAST )) && printf ' (fast: behavioural suites skipped)')" "$c_off"
