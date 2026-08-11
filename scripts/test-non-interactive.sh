#!/usr/bin/env bash
# Asserts that nothing here waits for a human.
#
# There is deliberately no --non-interactive flag. A flag only helps if something branches on it, and
# nothing in these scripts prompts today -- so adding one would create a second path exercised only
# when it is set, which means the default path can regress into prompting while the flag-gated tests
# stay green. That is the believing-you-are-protected shape this repository keeps finding. This file
# already deleted two flags for being modes nobody turned on (--statusline, --advisor).
#
# The property wanted is *there is no interactive path*, and that is asserted, not selected.
#
# Two kinds of check: run every entrypoint with stdin closed and no TTY, and sweep the sources for the
# constructs that block on a person. Both, because a construct can be added without being reached, and
# a path can be reached without any of those constructs in it.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then c_red=''; c_green=''; c_off=''
else c_red=$'\033[31m'; c_green=$'\033[32m'; c_off=$'\033[0m'; fi
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no() { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }

# macOS has no `timeout`. A hang here would hang CI, which is the one outcome this file must not have.
with_deadline() { # <seconds> <command...>  -> exit status, or 124 when it had to be killed
  local secs="$1"; shift
  "$@" >"$TMP/out" 2>&1 &
  local pid=$! ticks=0
  # Fifths of a second, not whole ones. At one-second granularity the floor cost was a second per
  # entrypoint whether or not it had already finished, which made the suite look like it was hanging.
  local limit=$(( secs * 5 ))
  while [[ $ticks -lt $limit ]]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return $?; }
    sleep 0.2
    ticks=$((ticks+1))
  done
  kill -KILL "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  return 124
}

# stdin CLOSED, not /dev/null. Closed is harsher and more realistic: a hook invoked by an agent that
# has already exited has no stdin at all, and a `read` against a closed descriptor behaves differently
# from one against an empty file.
run_headless() { # <label> <command...>
  local label="$1"; shift
  local code
  TERM=dumb NO_COLOR=1 with_deadline 30 "$@" <&- ; code=$?
  if [[ $code -eq 124 ]]; then
    no "$label did not terminate with stdin closed -- something is waiting for input"
  else
    ok "$label terminates with stdin closed and no TTY (exit $code)"
  fi
}

echo "non-interactive"
echo

FAKE="$TMP/home"; mkdir -p "$FAKE/.claude" "$FAKE/.cursor"

# Read-only or dry-run entrypoints only. `setup.sh install` writes to $HOME, and pointing it at a fake
# one is what test-setup.sh is for; this file is about whether things block, not what they write.
run_headless "check.sh --fast"          env HOME="$FAKE" bash "$REPO/scripts/check.sh" --fast
run_headless "verify-skills.sh"         bash "$REPO/scripts/verify-skills.sh"
run_headless "gate.sh -h"               bash "$REPO/scripts/gate.sh" -h
run_headless "gate.sh status"           env HOME="$FAKE" bash "$REPO/scripts/gate.sh" status "$REPO"
run_headless "gate.sh status --json"    env HOME="$FAKE" bash "$REPO/scripts/gate.sh" status --json "$REPO"
run_headless "gate.sh gc"               env DOTAGENTS_GATE_DIR="$TMP/gate" bash "$REPO/scripts/gate.sh" gc
run_headless "loop.sh (usage)"          env HOME="$FAKE" bash "$REPO/scripts/loop.sh"
run_headless "loop.sh status"           env HOME="$FAKE" DOTAGENTS_LOOP_DIR="$TMP/loop" bash "$REPO/scripts/loop.sh" status
run_headless "loop.sh report"           env HOME="$FAKE" DOTAGENTS_LOOP_DIR="$TMP/loop" bash "$REPO/scripts/loop.sh" report
# The design phase is the one place a prompt is tempting: every stage of it needs a human, so "just ask
# which one you did" looks reasonable. It must still terminate with stdin closed.
run_headless "loop.sh design"           env HOME="$FAKE" DOTAGENTS_LOOP_DIR="$TMP/loop" bash "$REPO/scripts/loop.sh" design
run_headless "setup.sh status"          env HOME="$FAKE" bash "$REPO/scripts/setup.sh" status
run_headless "setup.sh doctor"          env HOME="$FAKE" bash "$REPO/scripts/setup.sh" doctor
run_headless "setup.sh install --dry-run" env HOME="$FAKE" bash "$REPO/scripts/setup.sh" install --dry-run

echo

# The hooks read stdin from the harness, which is legitimate -- the rule is "nothing waits for a
# *person*", not "nothing reads stdin". So they are checked for the property that matters: with no
# input at all they must still terminate, and the gate must still fail closed rather than wave a turn
# through because it could not read its payload.
run_headless "the lint hook, no payload"  bash "$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
run_headless "the gate hook, no payload"  env DOTAGENTS_GATE_DIR="$TMP/empty-gate" \
  bash "$REPO/hooks/dotagents-verify-gate.sh"

# With a gate armed and no readable payload, the gate must block. Passing here would mean an agent
# that closes stdin gets a free turn end.
GATE="$TMP/armed-gate"
PROFILES="$TMP/profiles"; mkdir -p "$PROFILES"
SCRATCH="$TMP/scratch"; mkdir -p "$SCRATCH"
git -C "$SCRATCH" init -q
git -C "$SCRATCH" remote add origin git@github.com:example/headless.git
echo x > "$SCRATCH/a.txt"; git -C "$SCRATCH" add -A
git -C "$SCRATCH" -c user.email=t@t -c user.name=t commit -qm init
cat > "$PROFILES/headless.json" <<'JSON'
{ "match": { "remote": "example/headless" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
DOTAGENTS_GATE_DIR="$GATE" bash "$REPO/scripts/gate.sh" arm "$SCRATCH" >/dev/null 2>&1

( cd "$SCRATCH" && TERM=dumb DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    bash "$REPO/hooks/dotagents-verify-gate.sh" >/dev/null 2>&1 <&- )
armed_code=$?
[[ "$armed_code" == "2" ]] \
  && ok "an armed gate with no readable payload blocks (exit 2), rather than passing" \
  || no "an armed gate with stdin closed exited $armed_code -- closing stdin should not buy a turn end"

echo

# The sweep. A construct can be added without ever being reached by the runs above, so the sources are
# read as well. `read` fed by a redirect or a here-string is fine -- that is how the gate walks its
# work file; a bare `read` with nothing behind it is what blocks.
offenders=""
for f in "$REPO"/scripts/*.sh "$REPO"/hooks/*.sh; do
  base="$(basename "$f")"
  # This file names every construct it forbids, so a sweep that included it would report itself.
  [[ "$base" == "test-non-interactive.sh" ]] && continue
  hits="$(grep -nE 'read[[:space:]]+-[a-zA-Z]*p|/dev/tty|[^a-zA-Z_-]stty[[:space:]]|[^a-zA-Z_-]tput[[:space:]]' "$f" \
          | grep -v '^[[:space:]]*[0-9]*:[[:space:]]*#' || true)"
  [[ -n "$hits" ]] && offenders="$offenders
$base: $hits"
done
if [[ -z "${offenders// /}" ]]; then
  ok "no script reads from a terminal (no read -p, /dev/tty, stty or tput)"
else
  no "something reads from a terminal:$offenders"
fi

# `select` is a bash builtin whose whole purpose is an interactive menu. There is no non-blocking use.
if grep -qnE '^[[:space:]]*select[[:space:]]+[a-zA-Z_]' "$REPO"/scripts/*.sh "$REPO"/hooks/*.sh 2>/dev/null; then
  no "a script uses 'select', which exists only to prompt"
else
  ok "no script uses 'select'"
fi

echo
if (( fail )); then
  printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
