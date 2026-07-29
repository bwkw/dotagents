#!/usr/bin/env bash
# Tests for the Stop gate. Hermetic: a scratch git repo and a scratch profile, no real builds.
#
# The gate is the one component that must fail *closed*, so its behaviour is asserted rather
# than assumed. Every case below has been a real failure mode in some tool or other:
# gates that fire when idle, gates that guess commands for repos they know nothing about,
# gates that accept "I asked the user to run it" as evidence.

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/dotagents-verify-gate.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
c_red=$'\033[31m'; c_green=$'\033[32m'; c_off=$'\033[0m'

check() { # check <name> <expected-exit> <actual-exit>
  if [[ "$2" == "$3" ]]; then
    printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1))
  else
    printf '%s✗%s %s (expected exit %s, got %s)\n' "$c_red" "$c_off" "$1" "$2" "$3"; fail=$((fail+1))
  fi
}

# The inline `&& { printf ...; pass=... } || { printf ...; fail=... }` pattern below predates these.
# New assertions use ok/no; the existing ones are left alone rather than churned.
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no() { printf '%s✗%s %s\n' "$c_red"   "$c_off" "$1"; fail=$((fail+1)); }

# --- scratch repo -----------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" remote add origin git@github.com:example/scratch.git
echo hello > "$REPO/a.txt"
git -C "$REPO" add -A
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm init

# --- scratch profiles -------------------------------------------------------
PROFILES="$TMP/profiles"
mkdir -p "$PROFILES"
write_profile() { cat > "$PROFILES/scratch.json"; }

GATE="$TMP/gate"
GATE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gate.sh"
# Arm through the real script. A hand-rolled helper here is what let the gate ship with nothing
# in the repository able to arm it: the tests passed by simulating the mechanism they were meant
# to exercise.
arm()   { DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$REPO" >/dev/null; }
disarm(){ DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" disarm "$REPO" >/dev/null 2>&1 || true; rm -rf "$GATE"; }

# trace() in the hook returns early unless $GATE_DIR exists, and several cases below `rm -rf "$GATE"`.
# So an absent log means "nothing was traced", which is a legitimate answer, not an error.
trace_has() { grep -q "$1" "$GATE/trace.log" 2>/dev/null; }

# A linked worktree of $REPO. Detached rather than on a branch: the name is irrelevant to what these
# cases test, and --detach has none to collide with a later case.
mk_worktree() { # mk_worktree <name> -> prints the worktree path, or fails
  local p="$TMP/wt-$1"
  git -C "$REPO" worktree add -q --detach "$p" >/dev/null 2>&1 || return 1
  printf '%s' "$p"
}

# The armed directory whose ACTIVE names this repo. The slug is documented as never parsed, so these
# tests must not derive it either -- they find it by content, the way the hook does. Nothing here
# recomputes the worktree key: a test that re-implements the mechanism it is checking is how this
# suite once passed while nothing in the repository could arm the gate at all.
gate_dir_for() { # gate_dir_for <repo>
  local want f
  want="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$1")"
  for f in "$GATE"/*/ACTIVE; do
    [[ -f "$f" ]] || continue
    [[ "$(cat "$f")" == "$want" ]] && { dirname "$f"; return 0; }
  done
  return 1
}

invoke_at() { # invoke_at <dir> [extra-json-fields]
  printf '{"cwd":"%s"%s}' "$1" "${2:+,$2}" \
    | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>"$TMP/stderr"
  echo $?
}

invoke() { invoke_at "$REPO"; }

# Cursor's stop hook sends {status, loop_count} and no cwd, so the hook falls back to $PWD.
# It cannot block; it answers with {"followup_message": ...} on stdout.
invoke_cursor() { # invoke_cursor [loop_count]
  printf '{"status":"completed","loop_count":%s}' "${1:-0}" \
    | (cd "$REPO" && DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
        bash "$HOOK" 2>"$TMP/stderr" >"$TMP/stdout")
  echo $?
}

echo "verify-gate"
echo

# 1. No sentinel: an unarmed session must never be interrupted, whatever the repo state.
disarm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "always-fails", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "no sentinel armed -> does not fire" 0 "$(invoke)"

# 2. Armed and the check passes.
arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "armed, check passes -> allows finish" 0 "$(invoke)"

# 3. Armed and the check fails: this is the whole point.
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo 'type error on line 4'; false", "gate": true, "agent_may_run": true } ] }
JSON
check "armed, check fails -> blocks" 2 "$(invoke)"
grep -q "boom" "$TMP/stderr" && grep -q "type error on line 4" "$TMP/stderr" \
  && { printf '%s✓%s   reports the failing check and its output\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   stderr lacks the check id or its output\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 4. Second consecutive failure escalates from "fix it" to "stop and clear".
invoke >/dev/null
grep -qi "clear" "$TMP/stderr" \
  && { printf '%s✓%s   second failure escalates to /clear\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   second failure did not escalate\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 5. gate:false must not block, however loudly it fails.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "advisory", "cmd": "false", "gate": false, "agent_may_run": true } ] }
JSON
check "non-gating check fails -> still allows finish" 0 "$(invoke)"

# 6. A repo with no profile: we have no basis for a command, so we must not invent one.
write_profile <<'JSON'
{ "match": { "remote": "somebody/else" },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "no matching profile -> does not guess, allows finish" 0 "$(invoke)"

# 7. A delegated check with no recorded result must block, or "I asked the user" becomes an exit.
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs 8GB of heap" } ] }
JSON
check "delegated check unconfirmed -> blocks" 2 "$(invoke)"
grep -q "8GB of heap" "$TMP/stderr" \
  && { printf '%s✓%s   surfaces the delegation reason\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   delegation reason missing from stderr\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 8. Once recorded, it stops blocking.
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$REPO" >/dev/null
check "delegated check confirmed -> allows finish" 0 "$(invoke)"

# 9. {files} with nothing changed is a no-op, not a failure.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "test -n '{files}'", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "scope:changed with a clean tree -> skipped, allows finish" 0 "$(invoke)"

# 10. ...and runs once something has actually changed.
echo modified >> "$REPO/a.txt"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "scope:changed with a dirty tree -> runs and can block" 2 "$(invoke)"
grep -q "files=a.txt" "$TMP/stderr" \
  && { printf '%s✓%s   substitutes the changed files\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   {files} not substituted (stderr: %s)\n' "$c_red" "$c_off" "$(tr '\n' ' ' <"$TMP/stderr")"; fail=$((fail+1)); }

echo
echo "verify-gate — fail-closed on malfunction"
echo

# A repo whose path contains a space. Space-separated field passing truncated cwd here, git then
# failed, and the gate opened -- with nothing printed.
SPACED="$TMP/my project"
mkdir -p "$SPACED"
git -C "$SPACED" init -q
git -C "$SPACED" remote add origin git@github.com:example/scratch.git
echo x > "$SPACED/a.txt"
git -C "$SPACED" add -A
git -C "$SPACED" -c user.email=t@t -c user.name=t commit -qm init

rm -rf "$GATE"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$SPACED" >/dev/null
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
spaced_exit="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$SPACED" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>/dev/null; echo $?)"
check "a repo path containing a space -> still blocks" 2 "$spaced_exit"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" disarm "$SPACED" >/dev/null

# node missing must block, not pass. Empty PATH plus an absolute bash.
rm -rf "$GATE"; arm
# /usr/bin:/bin keeps cat, sed and git but not node, which lives under a package manager.
if PATH=/usr/bin:/bin command -v node >/dev/null 2>&1; then
  printf '%s!%s node is on /usr/bin:/bin here -- skipping the node-missing case\n' "$c_red" "$c_off"
else
  node_exit="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$REPO" \
    | env PATH=/usr/bin:/bin DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
      /bin/bash "$HOOK" 2>/dev/null; echo $?)"
  check "node unavailable -> blocks (does not fail open)" 2 "$node_exit"
fi

# A profiles directory that has gone missing (repo moved) must block.
moved_exit="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$REPO" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$TMP/gone" bash "$HOOK" 2>/dev/null; echo $?)"
check "profiles directory missing -> blocks" 2 "$moved_exit"

# A malformed profile used to abort the search loop, hiding every profile after it in readdir
# order -- so the gate opened for repositories whose profile was perfectly fine.
rm -rf "$GATE"; arm
printf '{ "match": { "remote": "x" }, "checks": [ ,,, ] }' > "$PROFILES/aaa-broken.json"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "a malformed profile does not hide the one that matches" 2 "$(invoke)"

# ...but when nothing matches and something is unparseable, we cannot claim to have checked.
write_profile <<'JSON'
{ "match": { "remote": "nobody/else" },
  "checks": [ { "id": "x", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "no match + a malformed profile -> blocks rather than assuming none applies" 2 "$(invoke)"
grep -q 'aaa-broken.json' "$TMP/stderr" \
  && { printf '%s✓%s   names the malformed file\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   did not name the malformed file\n' "$c_red" "$c_off"; fail=$((fail+1)); }
rm -f "$PROFILES/aaa-broken.json"

# A filename with shell metacharacters must not execute. Unquoted {files} + eval ran it.
rm -rf "$GATE"; arm
evil='a;touch pwned-by-filename;b.ts'
: > "$REPO/$evil" 2>/dev/null || evil=""
if [[ -n "$evil" ]]; then
  write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo got={files}", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
  invoke >/dev/null
  [ ! -f "$REPO/pwned-by-filename" ] \
    && { printf '%s✓%s a filename with metacharacters is not executed\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
    || { printf '%s✗%s INJECTION: the filename executed\n' "$c_red" "$c_off"; fail=$((fail+1)); }
  rm -f "$REPO/$evil" "$REPO/pwned-by-filename"
fi

# An untracked new file must be checked, not skipped. This turn adds only new files.
rm -rf "$GATE"; arm
git -C "$REPO" checkout -q -- . 2>/dev/null || true
echo 'brand new' > "$REPO/newfile.ts"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "an untracked new file -> is checked, not skipped" 2 "$(invoke)"
grep -q 'newfile.ts' "$TMP/stderr" \
  && { printf '%s✓%s   the new file reaches the command\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   new file missing from {files}\n' "$c_red" "$c_off"; fail=$((fail+1)); }
rm -f "$REPO/newfile.ts"

# Cursor sends no cwd, and its process cwd is ~/.cursor rather than the workspace. With one
# sentinel armed the gate must infer the repository instead of comparing against the wrong one --
# without this it passed every Cursor turn in silence.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
noc="$(printf '{"status":"completed","loop_count":0}' \
  | (cd "$TMP" && DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
      bash "$HOOK" 2>/dev/null >"$TMP/stdout"); echo $?)"
check "no cwd in payload, one armed -> infers the repo and applies the gate" 0 "$noc"
grep -q followup_message "$TMP/stdout" \
  && { printf '%s✓%s   still produces a follow-up rather than passing silently\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   passed silently (stdout: %s)\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# Two armed and no cwd: guessing would check one repo and report against another.
SECOND="$TMP/second"; mkdir -p "$SECOND"; git -C "$SECOND" init -q
git -C "$SECOND" remote add origin git@github.com:example/second.git
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$SECOND" >/dev/null 2>&1 || true
amb="$(printf '{"cwd":"","hook_event_name":"Stop"}' \
  | (cd "$TMP" && DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
      bash "$HOOK" 2>"$TMP/stderr"); echo $?)"
check "no cwd, several armed -> blocks rather than guessing" 2 "$amb"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" disarm "$SECOND" >/dev/null 2>&1 || true

# On re-entry (stop_hook_active) the gate must hand control back once, or the agent is trapped:
# it cannot reach the user without ending a turn, and every turn is being blocked.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
reentry="$(printf '{"cwd":"%s","hook_event_name":"Stop","stop_hook_active":true}' "$REPO" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>"$TMP/stderr"; echo $?)"
check "re-entry after a block -> releases once so the user is reachable" 0 "$reentry"
grep -qi 'still failing' "$TMP/stderr" \
  && { printf '%s✓%s   says the checks are still red while releasing\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   released without saying why\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# ...and the release must reach the trace log. It is the release, not the block, that decides whether
# a red turn ends -- so a trace that records only blocks is silent about the gate's most frequent and
# most consequential event, and "nothing happened" cannot be told apart from "never ran".
if trace_has 'RELEASED'; then ok "   the release is traced, not only the block"
else no "   released without a trace line (trace: $(cat "$GATE/trace.log" 2>/dev/null | tr '\n' '|' | tail -c 200))"; fi
if trace_has 'boom'; then ok "   the trace names the check that was still red"
else no "   the release trace does not name the failing check"; fi

# The block message must not teach the agent how to forge the delegated result.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs a lot of heap" } ] }
JSON
invoke >/dev/null
grep -q 'delegated.json' "$TMP/stderr" \
  && { printf '%s✗%s block message still hands out a way to forge the record\n' "$c_red" "$c_off"; fail=$((fail+1)); } \
  || { printf '%s✓%s block message does not hand out a forgery recipe\n' "$c_green" "$c_off"; pass=$((pass+1)); }

echo
echo "verify-gate — worktrees inherit the gate"
echo

# `using-git-worktrees` is a shipped skill whose stated purpose is isolation before executing a plan,
# so the moment work is serious enough to want a gate is the moment it moves into a worktree. Matching
# the sentinel against the *toplevel* meant a gate armed in the main checkout answered
# "armed elsewhere" for every one of them. Observed in the real trace log, not hypothetical:
#   claude  .../dresscode-backend/.worktrees/typecheck-perf  passed: armed elsewhere
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
WT1="$(mk_worktree one)" || WT1=""
WT2="$(mk_worktree two)" || WT2=""

if [[ -z "$WT1" || -z "$WT2" ]]; then
  no "could not create linked worktrees -- the worktree cases did NOT run"
else
  check "armed in the main checkout -> the gate holds a linked worktree" 2 "$(invoke_at "$WT1")"

  # Inheriting the gate must not mean sharing its counters. Attempts belong to a working tree: two
  # worktrees are two pieces of work, and carrying a count across them would escalate at a repo whose
  # own first attempt had not happened yet.
  invoke_at "$WT1" >/dev/null              # WT1 now at two consecutive failures
  grep -qi '2 times' "$TMP/stderr" \
    && ok "   a second failure in the same worktree escalates" \
    || no "   second failure in the same worktree did not escalate"
  invoke_at "$WT2" >/dev/null              # a different worktree, first failure
  grep -qi '2 times' "$TMP/stderr" \
    && no "   attempts leaked across worktrees (WT2 escalated on its first failure)" \
    || ok "   attempts are per worktree, not shared across them"

  # A delegated record is evidence about one working tree. Honouring it everywhere would let a check
  # confirmed in the main checkout wave through a worktree nobody ran it in.
  rm -rf "$GATE"; arm
  write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs 8GB of heap" } ] }
JSON
  DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$REPO" >/dev/null
  check "   a record in the main checkout does not satisfy a worktree" 2 "$(invoke_at "$WT1")"
  check "   ...and still satisfies the checkout it was made in" 0 "$(invoke)"

  # gate.sh reaches the same conclusion as the hook. Two implementations that must agree forever is
  # the coupling gate.sh's own header warns about, so it is asserted rather than assumed.
  # Captured, not piped into grep. `armed` is the first line status prints, so `grep -q` matches and
  # exits before gate.sh has finished writing -- gate.sh takes SIGPIPE, and under `pipefail` the
  # pipeline reports 141 even though the assertion held. The older `| grep -q` cases below get away
  # with it only because the string they look for is on the last line.
  wt_status="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$WT1" 2>&1)"
  grep -q '^armed' <<<"$wt_status" \
    && ok "   gate.sh status sees the inherited gate from inside the worktree" \
    || no "   gate.sh status reports not-armed inside a worktree of an armed repo: $(tr '\n' '|' <<<"$wt_status")"

  # Recording from inside the worktree must land where the hook looks for it.
  DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$WT1" >/dev/null 2>&1
  check "   a record made in the worktree satisfies that worktree" 0 "$(invoke_at "$WT1")"
fi

# An unrelated repository must still be none of our business -- inheritance widens the gate to
# worktrees of the armed repo, and to nothing else.
UNREL="$TMP/unrelated"; mkdir -p "$UNREL"; git -C "$UNREL" init -q
git -C "$UNREL" remote add origin git@github.com:example/scratch.git
echo z > "$UNREL/a.txt"; git -C "$UNREL" add -A
git -C "$UNREL" -c user.email=t@t -c user.name=t commit -qm init
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "a different repository with the same remote -> still armed elsewhere" 0 "$(invoke_at "$UNREL")"

echo
echo "verify-gate — the gate owns its own clock"
echo

# The most severe fail-open there was. Neither settings snippet declared a hook `timeout`, and nothing
# bounded `eval "$cmd"`. A hook killed by the harness's own timeout exits with neither 0 nor 2, which
# is non-blocking -- so a slow suite turned the gate into a silent no-op. And dresscode-frontend.json
# runs `pnpm run typecheck` and the full test suite at every single turn end.
#
# A timeout is a malfunction of the gate, not a finding about the code, so it blocks and is recorded
# as its own reason. It also counts toward the bound: otherwise a genuinely hanging check would block
# forever, which is the thing being fixed.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "max_attempts": 1,
  "checks": [ { "id": "hangs", "cmd": "sleep 30", "gate": true, "agent_may_run": true, "timeout": 1 } ] }
JSON
check "a check that outruns its timeout -> blocks, not passes" 2 "$(invoke)"
grep -qi 'timed out' "$TMP/stderr" \
  && ok "   says it timed out rather than reporting a failed check" \
  || no "   does not mention the timeout: $(tr '\n' '|' < "$TMP/stderr" | head -c 250)"
verdict="$(find "$GATE" -name VERDICT | head -1)"
[[ -n "$verdict" && "$(sed -n 2p "$verdict")" == "timeout" ]] \
  && ok "   recorded as 'timeout', not as 'red' -- it says nothing about the code" \
  || no "   wrong verdict reason: $(sed -n 2p "${verdict:-/dev/null}")"

# A fast check must be unaffected. A watchdog that changed the normal path would be worse than none.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "quick", "cmd": "true", "gate": true, "agent_may_run": true, "timeout": 30 } ] }
JSON
check "a check inside its timeout -> still passes" 0 "$(invoke)"

rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "slow-but-fine", "cmd": "sleep 1; echo done", "gate": true,
                "agent_may_run": true, "timeout": 30 } ] }
JSON
check "a check that takes a second but succeeds -> passes" 0 "$(invoke)"

# N checks x per-check timeout can exceed the harness ceiling, and exceeding THAT is the one failure
# we cannot observe. So the gate stops starting checks once its own total budget is gone -- and an
# unrun gating check is not a pass.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "timeout_total": 1,
  "checks": [ { "id": "first",  "cmd": "sleep 2", "gate": true, "agent_may_run": true, "timeout": 30 },
              { "id": "second", "cmd": "true",    "gate": true, "agent_may_run": true, "timeout": 30 } ] }
JSON
check "the total budget running out -> blocks rather than reporting green" 2 "$(invoke)"
grep -qi 'not run' "$TMP/stderr" \
  && ok "   names what it never got to run" \
  || no "   silent about the checks it skipped: $(tr '\n' '|' < "$TMP/stderr" | head -c 250)"
grep -q 'second' "$TMP/stderr" \
  && ok "   ...by check id" \
  || no "   did not name the unrun check by id"

echo
echo "verify-gate — blocking is bounded, and giving up is recorded"
echo

# `attempts >= 2` only ever escalated the *message*, and what it escalated to was "run /clear and
# restart" -- an action no unattended loop can take. The gate blocked once per turn cycle forever,
# which for a human is a nudge and for a loop is a wall with no door.
#
# So blocking is bounded. But silence would be a lie: the terminal state has to be a file that is
# PRESENT, because if giving up only removed ACTIVE the next session's status would say "not armed",
# which is indistinguishable from work nobody ever gated.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo 'still broken'; false", "gate": true, "agent_may_run": true } ] }
JSON
check "attempt 1 of 3 -> blocks" 2 "$(invoke)"
grep -qi 'attempt 1 of 3' "$TMP/stderr" \
  && ok "   states the budget, so the agent is not thrashing blind" \
  || no "   does not say which attempt this is: $(tr '\n' '|' < "$TMP/stderr" | head -c 200)"
check "attempt 2 of 3 -> still blocks" 2 "$(invoke)"
check "attempt 3 of 3 -> blocks once more, and this is the last one" 2 "$(invoke)"

# The invocation that crosses the threshold must exit 2, not release. exit 2 is what feeds stderr to
# the model; a non-blocking exit does not reliably. Releasing on the crossing turn would let the agent
# stop without ever learning the gate gave up.
grep -qi 'not verified' "$TMP/stderr" \
  && ok "   the terminal message says the work is not verified" \
  || no "   terminal message does not say the work is unverified: $(tr '\n' '|' < "$TMP/stderr" | head -c 300)"
grep -qi '/clear' "$TMP/stderr" \
  && no "   terminal message still tells an unattended loop to run /clear" \
  || ok "   terminal message does not prescribe /clear, which is unreachable unattended"

verdict="$(find "$GATE" -name VERDICT | head -1)"
[[ -n "$verdict" ]] \
  && ok "   a VERDICT file is written" \
  || no "   no VERDICT file anywhere under the gate dir"
if [[ -n "$verdict" ]]; then
  [[ "$(sed -n 2p "$verdict")" == "red" ]] \
    && ok "   its reason is 'red' -- the check kept failing" \
    || no "   wrong reason: $(sed -n 2p "$verdict")"
  [[ "$(sed -n 3p "$verdict")" == "boom" ]] \
    && ok "   it names the check" \
    || no "   verdict does not name the check: $(sed -n 3p "$verdict")"
fi
grep -q 'red' "$GATE/verdicts.log" 2>/dev/null \
  && ok "   and it is appended to verdicts.log" \
  || no "   nothing in verdicts.log"
trace_has 'GAVE UP' \
  && ok "   the give-up is traced" \
  || no "   gave up without a trace line"

# From here the gate must stop blocking -- that is the whole point -- but it must not look green.
check "after giving up -> stops blocking" 0 "$(invoke)"
trace_has 'gave up earlier' \
  && ok "   and the pass is textually distinct from 'all gating checks green'" \
  || no "   a given-up pass is indistinguishable from a clean pass in the trace"

# Re-arming is the one code path a new session is guaranteed to reach, via /da-verify. So it is where
# a prior verdict has to surface.
arm_out="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$REPO" 2>&1)"
grep -qi 'verdict' <<<"$arm_out" \
  && ok "re-arming echoes the verdict the previous session left" \
  || no "re-arming says nothing about the prior verdict: $(tr '\n' '|' <<<"$arm_out" | head -c 200)"
check "   ...and the gate blocks again after re-arming" 2 "$(invoke)"

# A delegated check nobody confirms is the unattended case with no door at all: it blocked and never
# counted. Bounded by the same budget, but recorded as a different finding -- "the human has not
# confirmed" is not "the code is broken".
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs 8GB of heap" } ] }
JSON
invoke >/dev/null; invoke >/dev/null
check "an unconfirmed delegated check is bounded too" 2 "$(invoke)"
check "   ...and then stops blocking" 0 "$(invoke)"
verdict="$(find "$GATE" -name VERDICT | head -1)"
[[ -n "$verdict" && "$(sed -n 2p "$verdict")" == "needs_human" ]] \
  && ok "   recorded as needs_human, not as red" \
  || no "   wrong reason for an unconfirmed delegated check: $(sed -n 2p "${verdict:-/dev/null}")"

# The budget is configurable, because the tests need it short and a slow repo may want it longer.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "DOTAGENTS_GATE_MAX_ATTEMPTS=1 -> gives up on the first failure" 2 "$(DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke)"
check "   ...and stops blocking immediately after" 0 "$(DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke)"

rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "max_attempts": 1,
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "a profile may set max_attempts" 2 "$(invoke)"
check "   ...and it is honoured" 0 "$(invoke)"

# Giving up in one worktree must not release the gate for another. The counters are per worktree, so
# the verdict has to be too, or one dead end would open the gate for every parallel piece of work.
if [[ -n "${WT1:-}" ]]; then
  rm -rf "$GATE"; arm
  write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
  DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke >/dev/null          # main checkout gives up
  check "giving up in one working tree does not release another" 2 "$(invoke_at "$WT1")"
fi

echo
echo "verify-gate — an idle gate is reclaimed"
echo

# Disarming was prose in da-verify/SKILL.md, so a session that ended without reaching step 6 left the
# repository armed forever. The gate dir on the author's machine had exactly that: a sentinel from a
# finished session, running five checks at every turn end for hours.
#
# Idle time, not time since arming. A TTL from arm would kill the thing being enabled -- a six-hour
# unattended run would expire mid-flight and the gate would open in silence.
NOW="$(date +%s)"
LATER=$(( NOW + 13 * 3600 ))     # past the 12h default
SOON=$(( NOW + 60 ))

# The invariant that makes expiry structurally unable to fail open: no single invocation both expires
# a sentinel and passes on the basis of that expiry. The only invocation that can expire gate G is one
# that is not G's -- and that one was never the invocation G was protecting.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
ex_own="$(DOTAGENTS_GATE_NOW=$LATER invoke_at "$REPO")"
check "the gate being enforced is never expired by its own invocation" 2 "$ex_own"
[[ -f "$(gate_dir_for "$REPO")/ACTIVE" ]] \
  && ok "   ...and its sentinel is still there afterwards" \
  || no "   the invocation expired the very gate it was enforcing"

# Enforcing it refreshes the heartbeat, which is what lets a long unattended run survive.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
DOTAGENTS_GATE_NOW=$SOON invoke_at "$REPO" >/dev/null
hb="$(cat "$(gate_dir_for "$REPO")/HEARTBEAT" 2>/dev/null || echo 0)"
[[ "$hb" == "$SOON" ]] \
  && ok "a turn that ends green refreshes the heartbeat" \
  || no "heartbeat not refreshed (wanted $SOON, got $hb)"

# Another repository's turn end is the sweeper. It runs several times a minute across all sessions,
# which is why no cron job is needed -- and a background process whose job is to un-arm guardrails
# would be a fail-open machine that runs when nobody is watching.
rm -rf "$GATE"; arm
STRANGER="$TMP/stranger"; mkdir -p "$STRANGER"; git -C "$STRANGER" init -q
git -C "$STRANGER" remote add origin git@github.com:example/stranger.git
echo s > "$STRANGER/a.txt"; git -C "$STRANGER" add -A
git -C "$STRANGER" -c user.email=t@t -c user.name=t commit -qm init
armed_dir="$(gate_dir_for "$REPO")"
check "a stranger's turn end passes (it was never gated)" 0 "$(DOTAGENTS_GATE_NOW=$LATER invoke_at "$STRANGER")"
[[ ! -f "$armed_dir/ACTIVE" ]] \
  && ok "   ...and reclaims the idle sentinel it found on the way" \
  || no "   the idle sentinel survived a sweep"
trace_has 'expired' \
  && ok "   the eviction is traced" \
  || no "   evicted without a trace line"
[[ -s "$GATE/verdicts.log" ]] \
  && ok "   and recorded in verdicts.log, which the trace trimmer does not touch" \
  || no "   nothing written to verdicts.log"
[[ -f "$armed_dir/ROOT" ]] \
  && ok "   ROOT survives the eviction, so status can still say whose gate it was" \
  || no "   ROOT is gone, so an expired gate is indistinguishable from a clean session"

# A gate that has not been idle long enough must be left alone.
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
DOTAGENTS_GATE_NOW=$SOON invoke_at "$STRANGER" >/dev/null
[[ -f "$armed_dir/ACTIVE" ]] \
  && ok "a gate inside its idle window is not reclaimed" \
  || no "reclaimed a gate that was still fresh"

# A sentinel written by an older gate.sh has no heartbeat at all. Treating that as infinitely idle
# would evict a gate somebody armed a minute ago, so it is backfilled instead: the upgrade migrates
# itself, with no command for anyone to remember to run.
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
rm -f "$armed_dir/HEARTBEAT" "$armed_dir/ARMED_AT"
DOTAGENTS_GATE_NOW=$LATER invoke_at "$STRANGER" >/dev/null
if [[ -f "$armed_dir/ACTIVE" && "$(cat "$armed_dir/HEARTBEAT" 2>/dev/null)" == "$LATER" ]]; then
  ok "a pre-upgrade sentinel is given a heartbeat, not evicted"
else
  no "a pre-upgrade sentinel was evicted or left without a heartbeat"
fi

echo
echo "gate.sh — reclaiming and reporting"
echo

# status must never be the thing that opens a gate. Reading state is not a licence to change it.
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
DOTAGENTS_GATE_NOW=$LATER DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$REPO" >/dev/null 2>&1
[[ -f "$armed_dir/ACTIVE" ]] \
  && ok "status reports staleness without evicting" \
  || no "status evicted the gate -- reading it was enough to open it"
st="$(DOTAGENTS_GATE_NOW=$LATER DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$REPO" 2>&1)"
grep -qi 'idle' <<<"$st" \
  && ok "   ...and says how long it has been idle" \
  || no "   status does not mention idleness: $(tr '\n' '|' <<<"$st")"

# gc is the explicit path, for a driver or CI that wants the sweep without waiting for a turn to end.
gc_out="$(DOTAGENTS_GATE_NOW=$LATER DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" gc 2>&1)"
[[ ! -f "$armed_dir/ACTIVE" ]] \
  && ok "gc reclaims an idle gate" \
  || no "gc left the idle gate armed"
grep -q "$(basename "$REPO")" <<<"$gc_out" \
  && ok "   ...and names what it reclaimed" \
  || no "   gc was silent about what it did: $(tr '\n' '|' <<<"$gc_out")"

# After eviction, "not armed" alone would be indistinguishable from a session that never armed
# anything. The whole point of keeping ROOT is that this question has an answer.
st="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status "$REPO" 2>&1)"
grep -qi 'expired' <<<"$st" \
  && ok "status explains that the gate expired rather than just 'not armed'" \
  || no "status hides the expiry: $(tr '\n' '|' <<<"$st")"

echo
echo "gate.sh — the arming mechanism"
echo

g() { DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" "$@"; }

rm -rf "$GATE"
g status "$REPO" 2>/dev/null | grep -q '^not armed' \
  && { printf '%s✓%s reports not-armed before anything is armed\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s status did not report not-armed\n' "$c_red" "$c_off"; fail=$((fail+1)); }

g arm "$REPO" >/dev/null
# The sentinel must carry the repo root, which is what decouples it from any slug derivation.
sentinel="$(find "$GATE" -name ACTIVE | head -1)"
[ -n "$sentinel" ] && [ "$(cat "$sentinel")" = "$(git -C "$REPO" rev-parse --show-toplevel)" ] \
  && { printf '%s✓%s the sentinel records the repository root\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s sentinel missing or does not hold the repo root\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# Arming twice must not create a second directory to reason about.
g arm "$REPO" >/dev/null
[ "$(find "$GATE" -name ACTIVE | wc -l | tr -d ' ')" = "1" ] \
  && { printf '%s✓%s arming twice is idempotent\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s arming twice produced multiple sentinels\n' "$c_red" "$c_off"; fail=$((fail+1)); }

g record typecheck "$REPO" >/dev/null
g status "$REPO" | grep -q typecheck \
  && { printf '%s✓%s record lands where status can see it\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s recorded check not visible to status\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# A gate armed for another repository must not hold this one.
OTHER="$TMP/other"; mkdir -p "$OTHER"; git -C "$OTHER" init -q
git -C "$OTHER" remote add origin git@github.com:example/other.git
g arm "$OTHER" >/dev/null
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
g disarm "$REPO" >/dev/null    # only the other repo stays armed
check "armed for another repo only -> does not hold this one" 0 "$(invoke)"

g disarm "$OTHER" >/dev/null
g status "$REPO" | grep -q '^not armed' \
  && { printf '%s✓%s disarm removes the sentinel\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s disarm left the gate armed\n' "$c_red" "$c_off"; fail=$((fail+1)); }

echo
echo "verify-gate — Cursor dialect"
echo

json_field() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { const v = JSON.parse(s)[process.argv[1]]; console.log(v === undefined ? "" : v) }
    catch { console.log("") }
  });' "$1" < "$TMP/stdout"; }

# 11. Cursor cannot be blocked, so a failure must still exit 0 -- but carry a followup_message.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo 'type error'; false", "gate": true, "agent_may_run": true } ] }
JSON
check "cursor: failing check -> exit 0 (cannot block)" 0 "$(invoke_cursor 0)"
msg="$(json_field followup_message)"
[ -n "$msg" ] && grep -q "boom" <<<"$msg" \
  && { printf '%s✓%s   emits a followup_message naming the check\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   no usable followup_message (stdout: %s)\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# The injected message arrives as a user message. Without attribution the agent cannot tell it from
# the human, and may treat a hook's demand as the user's intent.
msg="$(json_field followup_message)"
grep -q 'dotagents' <<<"$msg" && grep -qi 'user did not write this' <<<"$msg" \
  && { printf '%s✓%s   the follow-up says it is automated, not the user\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   follow-up is indistinguishable from a user message\n' "$c_red" "$c_off"; fail=$((fail+1)); }

# 12. Nothing may go to stderr on the Cursor path -- Cursor reads stdout, and stray stderr is noise.
[ ! -s "$TMP/stderr" ] \
  && { printf '%s✓%s   writes nothing to stderr\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   wrote to stderr: %s\n' "$c_red" "$c_off" "$(head -1 "$TMP/stderr")"; fail=$((fail+1)); }

# 13. Passing check -> valid empty JSON, so Cursor does not treat it as a malformed response.
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "cursor: passing check -> exit 0" 0 "$(invoke_cursor 0)"
[ "$(cat "$TMP/stdout")" = "{}" ] \
  && { printf '%s✓%s   emits {} rather than an empty body\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   expected {}, got: %s\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# 14. Cursor caps its own follow-up loop at 5. Stop feeding it before that, or the gate silently
#     consumes the whole budget and the user sees an agent that will not settle.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
invoke_cursor 3 >/dev/null
[ "$(cat "$TMP/stdout")" = "{}" ] \
  && { printf '%s✓%s   stops injecting once loop_count reaches 3\n' "$c_green" "$c_off"; pass=$((pass+1)); } \
  || { printf '%s✗%s   still injecting at loop_count=3: %s\n' "$c_red" "$c_off" "$(cat "$TMP/stdout")"; fail=$((fail+1)); }

# 15. Unarmed sessions stay untouched on this path too.
disarm
check "cursor: no sentinel armed -> does not fire" 0 "$(invoke_cursor 0)"

echo
if (( fail )); then
  printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
