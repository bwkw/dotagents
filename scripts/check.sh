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

# Colour only when someone is looking. Unconditional ANSI is noise in an unattended log and corruption
# in anything that captures this output into a file.
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then
  c_green=''; c_red=''; c_dim=''; c_off=''
else
  c_green=$'\033[32m'; c_red=$'\033[31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
fi
failed=()

# $TMPDIR is honoured -- the gate hook does this and documents why, and a hardcoded /tmp path ignored
# it. A predictable name under a world-writable directory is also a symlink-follow target for `>`.
# Full template because BSD mktemp treats `-t x` as a prefix and GNU coreutils demands XXXXXX.
LOG="$(mktemp "${TMPDIR:-/tmp}/dotagents-check.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -f "$LOG"' EXIT INT TERM

step() { # step <label> <command...>
  local label="$1"; shift
  printf '%s── %s%s\n' "$c_dim" "$label" "$c_off"
  if "$@" >"$LOG" 2>&1; then
    printf '%s✓%s %s\n' "$c_green" "$c_off" "$label"
  else
    printf '%s✗%s %s\n' "$c_red" "$c_off" "$label"
    # Head and tail, not `tail -25`. The first error of a long verify-skills.sh run was being cut off,
    # which is the one you actually need: the rest are usually consequences of it.
    if [[ "$(wc -l < "$LOG")" -gt 40 ]]; then
      head -20 "$LOG" | sed 's/^/    /'
      printf '    %s... (%s lines omitted) ...%s\n' "$c_dim" "$(( $(wc -l < "$LOG") - 40 ))" "$c_off"
      tail -20 "$LOG" | sed 's/^/    /'
      # The suites print one ✓/✗ per assertion, and with a hundred of them every failure lands in the
      # omitted middle -- which is the only part worth reading. Twice this hid a CI-only failure that
      # could not be reproduced locally, so the head/tail stays (it carries the first error of a long
      # lint run) and the failures are listed as well.
      if grep -q '✗' "$LOG"; then
        printf '    %sfailures:%s\n' "$c_red" "$c_off"
        # The line after a failure carries the suites' `detail` -- the actual output that explains it.
        # Listing the ✗ lines alone still hid why, which cost another CI round trip.
        grep -A2 '✗' "$LOG" | sed 's/^/      /'
      fi
    else
      sed 's/^/    /' "$LOG"
    fi
    failed+=("$label")
  fi
  : > "$LOG"
}

syntax() {
  local f
  for f in scripts/*.sh hooks/*.sh; do bash -n "$f" || return 1; done
  # macOS ships bash 3.2. These constructs parse on the CI runner and fail on the laptop.
  # This file is excluded because the pattern below names them, and a sweep that matches its own
  # pattern reports a failure that is not there -- which it did on the first run.
  ! grep -rqE --exclude=check.sh \
    '^[^#]*\b(mapfile|readarray)\b|declare -A|\$\{[a-zA-Z_]+\^\^\}|\$\{[a-zA-Z_]+,,\}' scripts/ hooks/ || return 1

  # A full-width character immediately after an unbraced variable is absorbed INTO THE VARIABLE NAME by
  # bash 3.2 under a UTF-8 locale, so the lookup is of a name that does not exist and the run dies with
  # `unbound variable`. macOS ships bash 3.2, so this passed on Linux, passed locally under the C locale,
  # and failed ONLY on the macOS CI runner -- the one place nobody reads first. Braces fix it.
  #
  # perl, not `grep -P`: BSD grep on macOS has no -P and this has to run on both runners.
  # Comments are skipped, because the comment you are reading describes the pattern it forbids.
  # `close ARGV if eof` resets $. per file, or the numbers are cumulative and point at nothing.
  local mb
  mb="$(perl -ne 'close ARGV if eof; next if /^\s*#/; print "$ARGV:$.\n" if /\$[A-Za-z_]\w*[^\x00-\x7F]/' \
        scripts/*.sh hooks/*.sh 2>/dev/null)"
  if [[ -n "$mb" ]]; then
    printf 'a variable expansion is followed directly by a multibyte character -- brace it as ${var}:\n%s\n' "$mb"
    return 1
  fi
  return 0
}

# Any repo-wide rewrite must skip symlinks. `perl -pi` on one replaces it with a regular file, which
# has silently broken CLAUDE.md three times. Use this to build the file list instead of `git ls-files`.
#
#   for f in $(scripts/check.sh --rewritable); do perl -pi -e '...' "$f"; done
rewritable() { git ls-files | while read -r f; do [[ -f "$f" && ! -L "$f" ]] && printf '%s\n' "$f"; done; }
[[ "${1:-}" == "--rewritable" ]] && { rewritable; exit 0; }

# Every shipped script has to be executable. The suites all invoke through `bash <file>`, so a lost
# +x bit passes every test here and in CI -- and then `scripts/gate.sh arm`, which is how the README
# tells you to run it, fails with permission denied. Lost for real by a rewrite that wrote to a new
# file and renamed it over the original, which is how a new file gets 644.
executable_bits() {
  local bad
  bad="$(git ls-files -s scripts/*.sh hooks/*.sh | awk '$1!="100755"{print $4}')"
  [[ -z "$bad" ]] && return 0
  printf 'not executable (mode should be 100755):\n%s\n' "$bad"
  return 1
}

symlink_intact() {
  # Claude Code does not read AGENTS.md, so if CLAUDE.md stops being a symlink the always-loaded
  # layer silently drifts. `perl -pi` on a symlink replaces it with a regular file; this caught it.
  [[ "$(git ls-files -s CLAUDE.md | awk '{print $1}')" == "120000" ]] \
    && [[ "$(readlink CLAUDE.md)" == "AGENTS.md" ]]
}

step "shell syntax, and no bash 4 constructs" syntax
step "CLAUDE.md is still a symlink to AGENTS.md" symlink_intact
step "every shipped script is executable" executable_bits
step "skills lint (invariants, budget, agents, override scope)" ./scripts/verify-skills.sh
step "da-review-all Canvas output contract" ./scripts/test-da-review-all-canvas.sh
# In the fast lane on purpose: it is a static cross-check, it costs milliseconds, and the thing it
# guards is edited by docs-only changes -- which are exactly the changes that skip the behavioural
# suites.
step "halt reasons: loop.sh and docs/loops.md agree" ./scripts/verify-halt-docs.sh

if (( ! FAST )); then
  # The installer suite has to create and delete a skill inside this repository, because pruning is
  # what it exercises. So the tree is compared before and after: a suite that leaves something behind
  # is a suite that gets its droppings committed by the next loop iteration.
  tree_before="$(git status --porcelain 2>/dev/null)"

  step "verify-gate behaviour"    ./scripts/test-verify-gate.sh
  step "lint-hook and lint scope" ./scripts/test-lint-hook.sh
  step "installer behaviour"      ./scripts/test-setup.sh
  step "loop driver behaviour"    ./scripts/test-loop.sh
  step "nothing waits for a human" ./scripts/test-non-interactive.sh

  tree_clean() { [[ "$(git status --porcelain 2>/dev/null)" == "$tree_before" ]]; }
  step "the suites left the working tree as they found it" tree_clean
fi

echo
if (( ${#failed[@]} )); then
  printf '%s%d failed:%s %s\n' "$c_red" "${#failed[@]}" "$c_off" "${failed[*]}"
  exit 1
fi
printf '%s✓ all checks passed%s%s\n' "$c_green" "$( (( FAST )) && printf ' (fast: behavioural suites skipped)')" "$c_off"
