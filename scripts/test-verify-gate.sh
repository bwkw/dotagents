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

# --- match.remote: owner-independent, and a list ----------------------------
# `match.remote` used to be one substring, so it named exactly one owner. Every fork and every
# re-clone under a different account therefore resolved NO profile, and the gate passed in silence --
# on repositories whose profile was written precisely to gate them. The fake origin here is
# git@github.com:example/scratch.git, so a profile naming only '/scratch' has to match it: that is
# the spelling that survives a fork, and it covers the https URL form too.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "/scratch" },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "a profile naming the repo without an owner matches (fork-portable)" 2 "$(invoke)"

# A list matches when any entry does -- for one repository reachable under several names.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": ["nobody/else", "example/scratch"] },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "a list of remotes matches on any entry" 2 "$(invoke)"

# ...and the list must not match on nothing. Accepting an array by concatenating it into a string
# would have made every list match every remote, which reads as a stricter gate and is a looser one.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": ["nobody/else"] },
  "checks": [ { "id": "x", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "a list that matches nothing resolves no profile" 0 "$(invoke)"

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
#   claude  .../<repo>/.worktrees/typecheck-perf  passed: armed elsewhere
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
echo "verify-gate — {files} is relative to where the command runs"
echo

# {files} came from `git -C "$repo_root"`, so the paths were repo-root-relative -- but the command runs
# in repo_root/<profile.cwd>. A profile setting "cwd": "v2" with "pnpm exec vitest run
# {files}" got a changed file as `v2/src/foo.ts`, handed to a vitest already running inside
# `v2/`. Depending on passWithNoTests that is either a permanent false failure or a vacuous pass.
# No existing case combined cwd with {files}, which is why it survived.
rm -rf "$GATE"
SUBREPO="$TMP/subrepo"; mkdir -p "$SUBREPO/pkg/src"
git -C "$SUBREPO" init -q
git -C "$SUBREPO" remote add origin git@github.com:example/sub.git
echo base > "$SUBREPO/pkg/src/a.ts"
git -C "$SUBREPO" add -A
git -C "$SUBREPO" -c user.email=t@t -c user.name=t commit -qm init
echo changed >> "$SUBREPO/pkg/src/a.ts"
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" arm "$SUBREPO" >/dev/null
cat > "$PROFILES/sub.json" <<'JSON'
{ "match": { "remote": "example/sub" },
  "cwd": "pkg",
  "checks": [ { "id": "unit", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
check "a profile with cwd + scope:changed -> runs and can block" 2 "$(invoke_at "$SUBREPO")"
grep -q 'files=src/a.ts' "$TMP/stderr" \
  && ok "   the path is relative to cwd, so the runner in pkg/ can open it" \
  || no "   wrong base directory: $(grep -o 'files=[^ ]*' "$TMP/stderr" | head -1)"
rm -f "$PROFILES/sub.json"

echo
echo "verify-gate — a check that rewrites the tree cannot report green"
echo

# Real profiles commonly gate on `lint:fix` and `format:fix`, scope: all. So the
# hook rewrites the working tree after the agent has decided it is done -- and if the fixer succeeds
# the gate goes green, hiding the fact that it changed code. In a loop the next iteration then reads a
# tree it did not write. The gate reports; it does not repair silently.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "fixer", "cmd": "echo autofixed >> touched-by-the-gate.txt", "gate": true,
                "agent_may_run": true, "mutates": true } ] }
JSON
check "a mutating check that changes the tree -> blocks instead of going green" 2 "$(invoke)"
grep -qi 'changed the working tree' "$TMP/stderr" \
  && ok "   says the gate itself changed files" \
  || no "   silent about the modification: $(tr '\n' '|' < "$TMP/stderr" | head -c 250)"

# ...and once there is nothing left to fix, it must get out of the way.
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "fixer", "cmd": "true", "gate": true, "agent_may_run": true, "mutates": true } ] }
JSON
check "   a mutating check that changes nothing -> passes" 0 "$(invoke)"
rm -f "$REPO/touched-by-the-gate.txt"

echo
echo "verify-gate — a forbidden command is not run, even by the gate"
echo

# `forbidden` was prose only. It appears in profiles/_schema.json, in the profiles, and in
# da-verify/SKILL.md -- and nowhere in hooks/ or scripts/. The gate read the profile's `cmd` and
# `eval`ed it. So a repository could declare `cdk deploy` forbidden and have the gate run it at the end
# of every turn, which is the shape docs/mechanisms.md warns about: "a rule written in a skill is a
# request, not a guarantee. Guardrails go in hooks."
rm -rf "$GATE"; arm
# Evidence is a side effect on disk, not a string in the report: the command text appears in the
# ordinary failure detail too, so grepping stderr for it cannot distinguish "ran" from "was quoted".
rm -f "$TMP/forbidden-ran"
cat > "$PROFILES/scratch.json" <<JSON
{ "match": { "remote": "example/scratch" },
  "forbidden": [ "prisma migrate deploy", "git push --force" ],
  "checks": [ { "id": "danger", "cmd": "touch $TMP/forbidden-ran; prisma migrate deploy",
                "gate": true, "agent_may_run": true } ] }
JSON
check "a check whose cmd is forbidden -> blocks" 2 "$(invoke)"
[[ -e "$TMP/forbidden-ran" ]] \
  && no "   the forbidden command was executed" \
  || ok "   ...without running it"
# Deliberately not grepping for the command text: it appears in the ordinary failure report too, so
# that assertion passed before the fix existed. The word `forbidden` only appears if the gate declined.
grep -qi 'forbidden' "$TMP/stderr" \
  && ok "   ...and says it declined because the profile forbids it" \
  || no "   reported a failed check, not a refusal: $(tr '\n' '|' < "$TMP/stderr" | head -c 200)"

# A profile with no `forbidden` must behave exactly as before.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "no forbidden list -> unaffected" 0 "$(invoke)"

# And a substring that merely resembles one must not trip it -- the match is on the command, and a
# check called `deploy-docs` is not `cdk deploy`.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "forbidden": [ "cdk deploy" ],
  "checks": [ { "id": "docs", "cmd": "echo deploying docs is fine", "gate": true, "agent_may_run": true } ] }
JSON
check "a command that does not contain a forbidden phrase still runs" 0 "$(invoke)"

echo
echo "verify-gate — a subagent finishing is not the end of a turn"
echo

# Official docs: "For subagents, `Stop` hooks are automatically converted to `SubagentStop` since that
# is the event that fires when a subagent completes." So this hook has been running at every subagent
# completion all along -- da-review-all dispatches three layer subagents, which meant three extra full
# runs of the gating suite per review, exit 2 *preventing a review subagent from stopping* because the
# repo's tests were red, and three spurious increments of the attempt budget.
#
# The gate is about whether the user's turn may end. A subagent finishing is not that.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
check "SubagentStop with a red check -> passes, does not block the subagent" 0 \
  "$(invoke_at "$REPO" '"hook_event_name":"SubagentStop"')"
check "   a Stop payload carrying agent_id -> also passes" 0 \
  "$(invoke_at "$REPO" '"hook_event_name":"Stop","agent_id":"a1","agent_type":"x-review-backend"')"
trace_has 'subagent' \
  && ok "   and says so, so the trace does not look like a clean pass" \
  || no "   passed silently: $(cat "$GATE/trace.log" 2>/dev/null | tr '\n' '|' | tail -c 160)"

# The real turn end must still block, or the fix would have removed the gate.
check "   the user's own turn end still blocks" 2 "$(invoke)"

# A subagent stop must not spend the attempt budget either.
rm -rf "$GATE"; arm
invoke_at "$REPO" '"hook_event_name":"SubagentStop"' >/dev/null
invoke_at "$REPO" '"hook_event_name":"SubagentStop"' >/dev/null
invoke >/dev/null
grep -qi 'attempt 1 of' "$TMP/stderr" \
  && ok "   subagent stops do not consume the attempt budget" \
  || no "   the budget was spent by subagent stops: $(grep -o 'attempt [0-9] of [0-9]' "$TMP/stderr" | head -1)"

echo
echo "verify-gate — an unexpected crash must not read as permission to stop"
echo

# Official docs: "Claude Code treats exit code 1 as a non-blocking error and proceeds, even though 1 is
# the conventional Unix failure code." Only exit 2 blocks. This hook runs under `set -u`, so an unbound
# variable exits 1 -- non-blocking -- and the turn ends with nothing checked. That class already bit
# this repo once (a cwd containing a space made an arithmetic comparison exit 127).
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
# Injected fault: a copy of the hook with an unbound variable reference partway through.
CRASH="$TMP/crashing-hook.sh"
sed 's|^payload="\$(cat <&3)"|payload="$(cat <\&3)"; : "$DOTAGENTS_DELIBERATELY_UNSET_FOR_TEST"|' \
  "$HOOK" > "$CRASH"
crash_code="$(printf '{"cwd":"%s","hook_event_name":"Stop"}' "$REPO" \
  | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$CRASH" 2>/dev/null; echo $?)"
[[ "$crash_code" == "2" ]] \
  && ok "an armed gate that crashes exits 2, not 1 -- only 2 blocks" \
  || no "a crash exited $crash_code, which Claude Code treats as non-blocking: the turn ends unchecked"

echo
echo "verify-gate — a killed check leaves nothing behind"
echo

# The watchdog kills the subshell running `eval`, not its descendants. A check that backgrounds work --
# `pnpm test` spawning node, a dev server, a docker run -- left it alive after the timeout, holding
# ports and CPU for as long as it felt like. Written before the fix, because the fix moves the
# {files} + eval execution boundary and this is what says the move was worth making.
rm -rf "$GATE"; arm
rm -f "$TMP/orphan.pid"
cat > "$PROFILES/scratch.json" <<JSON
{ "match": { "remote": "example/scratch" },
  "max_attempts": 1,
  "checks": [ { "id": "spawns", "timeout": 1, "gate": true, "agent_may_run": true,
                "cmd": "sh -c 'sleep 60 & echo \$! > $TMP/orphan.pid; sleep 60'" } ] }
JSON
invoke >/dev/null
orphan="$(cat "$TMP/orphan.pid" 2>/dev/null || true)"
if [[ -z "$orphan" ]]; then
  no "the probe never recorded a child pid -- the orphan case did NOT run"
else
  # A moment for the kill to propagate before deciding.
  sleep 1
  if kill -0 "$orphan" 2>/dev/null; then
    no "a backgrounded child survived the timeout (pid $orphan) -- it holds ports and CPU after the gate gave up"
    kill -9 "$orphan" 2>/dev/null || true
  else
    ok "a backgrounded child is killed along with the check"
  fi
fi

echo
echo "verify-gate — {files} is data, never code"
echo

# One assertion used to stand between `{files}` + eval and remote code execution by anything that can
# write a filename into the work tree. Widened before the execution path moves, because that is the
# boundary being moved.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "unit", "cmd": "echo got={files}", "gate": true,
                "agent_may_run": true, "scope": "changed" } ] }
JSON
git -C "$REPO" checkout -q -- . 2>/dev/null || true
rm -f "$REPO"/pwned-* 2>/dev/null || true
made=0
for evil in 'a;touch pwned-semi;b.ts' \
            'a`touch pwned-backtick`b.ts' \
            'a$(touch pwned-dollar)b.ts' \
            "a'; touch pwned-quote; 'b.ts" \
            'a|touch pwned-pipe|b.ts' \
            'a&&touch pwned-and&&b.ts' \
            '--touch=pwned-dash.ts'; do
  : > "$REPO/$evil" 2>/dev/null && made=$((made+1))
done
if (( made == 0 )); then
  no "could not create any adversarial filename -- the injection cases did NOT run"
else
  invoke >/dev/null
  hits="$(ls -1 "$REPO" 2>/dev/null | grep '^pwned-' | tr '\n' ' ' || true)"
  [[ -z "${hits// /}" ]] \
    && ok "$made adversarial filenames reach the command as data ($(basename "$REPO") is clean)" \
    || no "INJECTION: a filename executed -- $hits"
fi
rm -f "$REPO"/pwned-* 2>/dev/null || true
git -C "$REPO" clean -qfd 2>/dev/null || true
git -C "$REPO" checkout -q -- . 2>/dev/null || true

echo
echo "verify-gate — the gate owns its own clock"
echo

# The most severe fail-open there was. Neither settings snippet declared a hook `timeout`, and nothing
# bounded `eval "$cmd"`. A hook killed by the harness's own timeout exits with neither 0 nor 2, which
# is non-blocking -- so a slow suite turned the gate into a silent no-op. And a frontend profile that
# runs `typecheck` plus the full test suite does that at every single turn end.
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
echo "gate.sh verify — check without ending a turn, and without touching the gate"
echo

# Until now the only way to run a repository's checks was to end a turn. So an agent could not verify
# its own work mid-implementation, and da-verify re-implemented the hook's loop in prose -- which had
# already drifted: the skill told the model to use `git diff --name-only HEAD` while the hook also
# includes untracked files, deliberately, because "a turn that only adds new files produced an empty
# list, which skipped the check entirely". The skill would skip a check the gate runs.
#
# So `verify` drives the hook rather than reimplementing it. One implementation, no second copy to
# drift -- and nothing to delete later, which removes a planned one-way door.
verify() { # verify [--json] [dir]
  DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    bash "$GATE_SH" verify "$@" >"$TMP/vout" 2>"$TMP/verr"
  echo $?
}

rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "ok", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
check "verify with everything green -> exit 0" 0 "$(verify "$REPO")"

# The point of the whole thing: it works with no gate armed. Verifying is what you do *while* working.
[[ ! -e "$GATE" ]] || [[ -z "$(find "$GATE" -name ACTIVE 2>/dev/null)" ]] \
  && ok "   ...with nothing armed, which is when you actually want it" \
  || no "   verify armed something"

write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "echo the-real-failure; false", "gate": true, "agent_may_run": true } ] }
JSON
vrc="$(verify "$REPO")"
[[ "$vrc" != "0" ]] \
  && ok "verify with a red check -> non-zero" \
  || no "verify reported success on a red check"
grep -q 'boom' "$TMP/vout" "$TMP/verr" 2>/dev/null \
  && ok "   ...and names the check" || no "   did not name the failing check"
grep -q 'the-real-failure' "$TMP/vout" "$TMP/verr" 2>/dev/null \
  && ok "   ...and shows its output" || no "   did not show the check output"

# It must not spend the gate's state. A self-check that consumed an attempt would make the budget
# depend on how often you checked your own work, which is the opposite of encouraging it.
rm -rf "$GATE"; arm
armed_dir="$(gate_dir_for "$REPO")"
hb_before="$(cat "$armed_dir/HEARTBEAT" 2>/dev/null)"
verify "$REPO" >/dev/null
att="$(find "$armed_dir" -name attempts.json | head -1)"
[[ "$(tr -d ' \n' < "$att" 2>/dev/null)" == "{}" ]] \
  && ok "verify does not consume an attempt" \
  || no "verify spent the attempt budget: $(cat "$att" 2>/dev/null | tr -d '\n')"
[[ -z "$(find "$armed_dir" -name VERDICT 2>/dev/null)" ]] \
  && ok "   ...and writes no verdict" || no "   verify wrote a VERDICT"
[[ "$(cat "$armed_dir/HEARTBEAT" 2>/dev/null)" == "$hb_before" ]] \
  && ok "   ...and does not refresh the heartbeat" \
  || no "   verify refreshed the heartbeat, so checking your work would keep a stale gate alive"
[[ -f "$armed_dir/ACTIVE" ]] \
  && ok "   ...and leaves the gate armed" || no "   verify disarmed the gate"

# --json for a driver, same as status --json.
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
verify --json "$REPO" >/dev/null
vj() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { console.log(String(JSON.parse(s)[process.argv[1]])) } catch { console.log("parse-error") }
  });' "$1" < "$TMP/vout"; }
[[ "$(vj ok)" == "false" ]] \
  && ok "verify --json reports ok=false" || no "verify --json ok=$(vj ok) (raw: $(head -c 120 "$TMP/vout"))"
[[ "$(vj check)" == "boom" ]] \
  && ok "   ...and names the check in a field, not in prose" || no "   check=$(vj check)"

# --- what the gate DID, as fields ------------------------------------------------
# `ok: true` never meant "verified": a check that never executed reported the same thing as one that
# passed, and the only way to tell them apart was to match the sentence "all gating checks green"
# against "nothing blocking". scripts/loop.sh carried a comment calling that "the SECOND prose
# coupling". These fields are what replaced it.
[[ "$(vj ran)" == "1" ]] \
  && ok "   ...and reports how many gating checks actually ran" || no "   ran=$(vj ran), expected 1"
[[ "$(vj checked)" == "true" ]] \
  && ok "   ...and checked is true when one ran" || no "   checked=$(vj checked)"
[[ "$(vj profile)" == *"scratch"* || "$(vj profile)" == *".json" ]] \
  && ok "   ...and names the resolved profile, so nothing greps for 'no profile matches'" \
  || no "   profile=$(vj profile)"

# A clean tree with only {files}-scoped gating checks. The check is SKIPPED, and this used to be
# reported byte-identically to a real pass (docs/loops.md:546). Still non-blocking -- on a clean tree
# there is genuinely nothing to check -- but it must no longer be indistinguishable.
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "only-changed", "cmd": "false {files}", "gate": true, "agent_may_run": true,
                "scope": "changed" } ] }
JSON
git -C "$REPO" add -A >/dev/null 2>&1; git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm clean >/dev/null 2>&1
verify --json "$REPO" >/dev/null
[[ "$(vj ran)" == "0" ]] \
  && ok "a clean tree runs no {files} check, and says ran=0" \
  || no "   ran=$(vj ran) on a clean tree, expected 0"
[[ "$(vj checked)" == "false" ]] \
  && ok "   ...so checked is false -- 'nothing ran' is not 'green'" || no "   checked=$(vj checked)"
node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o=null; try { o=JSON.parse(s) } catch {}
    const sk=(o&&o.skipped)||[];
    process.exit(sk.some(x=>x.id==="only-changed"&&x.reason==="no_files")?0:1);
  });' < "$TMP/vout" \
  && ok "   ...and names the skipped check with its reason, instead of vanishing" \
  || no "   skipped did not name only-changed:no_files (raw: $(head -c 200 "$TMP/vout"))"

# Fail closed. A missing or unreadable sidecar is "I could not tell", and this repository's own rule is
# that an absent answer is never a yes. `verify` always writes the sidecar itself, so the shape that
# needs pinning is the MERGE's reaction to a bad one -- asserted directly on the sanity test below
# rather than through a contrived failure of the writer.
# --- `paths`: a check runs only when it claims something that changed ------------
# The two ways a test here could pass for the wrong reason, both closed by construction:
#   1. the skipped check would have PASSED anyway -> so the skipped one is `exit 1`, which can only be
#      green by not running
#   2. nothing changed, so nothing ran for an unrelated reason -> so a real file is written first
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src",  "cmd": "exit 1", "gate": true, "agent_may_run": true,
                "paths": ["src/**"] },
              { "id": "needs-docs", "cmd": "true",   "gate": true, "agent_may_run": true,
                "paths": ["docs/**"] } ] }
JSON
mkdir -p "$REPO/docs"; printf 'x\n' > "$REPO/docs/x.md"
rc="$(verify --json "$REPO")"
[[ "$rc" == "0" ]] \
  && ok "paths: a docs change does not run the src-only check (which would have failed)" \
  || no "   verify exited $rc -- the src check ran, or something else blocked (raw: $(head -c 200 "$TMP/verr"))"
[[ "$(vj ran)" == "1" ]] \
  && ok "   ...and exactly one check ran" || no "   ran=$(vj ran), expected 1"
node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    let o=null; try { o=JSON.parse(s) } catch {}
    const sk=(o&&o.skipped)||[];
    process.exit(sk.some(x=>x.id==="needs-src"&&x.reason==="paths")?0:1);
  });' < "$TMP/vout" \
  && ok "   ...and the skip is named with reason=paths, not silent" \
  || no "   skipped did not name needs-src:paths (raw: $(head -c 200 "$TMP/vout"))"

# Files changed and NO gating check claims them. The check here WOULD PASS if it ran, so a block cannot
# be attributed to redness -- it can only mean "nothing was checked".
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src", "cmd": "true", "gate": true, "agent_may_run": true,
                "paths": ["src/**"] } ] }
JSON
rc="$(verify --json "$REPO")"
[[ "$rc" != "0" ]] \
  && ok "changed files that no check claims BLOCK, even though that check would have passed" \
  || no "   verify exited 0 -- 'nothing ran' was reported as green, which is the whole failure"
[[ "$(vj kind)" == "not_checked" ]] \
  && ok "   ...with kind=not_checked, which is not the same as red" || no "   kind=$(vj kind)"
[[ "$(vj ran)" == "0" ]] \
  && ok "   ...and ran=0 says so in a field" || no "   ran=$(vj ran)"

# Backwards compatibility: the same profile without `paths` runs and passes. One field, opposite result.
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src", "cmd": "true", "gate": true, "agent_may_run": true } ] }
JSON
rc="$(verify --json "$REPO")"
[[ "$rc" == "0" && "$(vj ran)" == "1" ]] \
  && ok "a check with no paths behaves exactly as before -- it always runs" \
  || no "   exit=$rc ran=$(vj ran); the no-paths path regressed"

# A clean tree with a `paths` check is the OTHER branch: nothing changed, so nothing to check, and the
# Stop hook must not block turns that only read code.
git -C "$REPO" add -A >/dev/null 2>&1
git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm docs >/dev/null 2>&1
rm -rf "$GATE"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "needs-src", "cmd": "true", "gate": true, "agent_may_run": true,
                "paths": ["src/**"] } ] }
JSON
rc="$(verify --json "$REPO")"
[[ "$rc" == "0" ]] \
  && ok "a clean tree with a paths check passes -- read-only turns are not blocked" \
  || no "   verify exited $rc on a clean tree; the gate would get switched off"
[[ "$(vj changed_files)" == "0" ]] \
  && ok "   ...and changed_files=0 distinguishes it from 'nothing was checked'" \
  || no "   changed_files=$(vj changed_files)"

# `paths` is ROOT-relative while `{files}` stays cwd-relative. Both halves in one case, because getting
# either backwards is silent.
rm -rf "$GATE"
mkdir -p "$REPO/pkg/src"; printf 'a\n' > "$REPO/pkg/src/a.ts"; printf 'b\n' > "$REPO/other.txt"
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" }, "cwd": "pkg",
  "checks": [ { "id": "pkg-only", "cmd": "echo files={files}; false", "gate": true,
                "agent_may_run": true, "scope": "changed", "paths": ["pkg/src/**"] } ] }
JSON
rc="$(verify --json "$REPO")"
# Read from `detail` in the JSON, NOT from stderr: in --json mode gate.sh folds the hook's report into
# the document and prints nothing on stderr. The first version of these two assertions grepped
# $TMP/verr -- which is empty here, so the "no leak" one passed by finding nothing in nothing.
[[ "$rc" != "0" ]] && grep -q 'files=src/a.ts' "$TMP/vout" \
  && ok "paths matches root-relative while {files} stays cwd-relative (files=src/a.ts)" \
  || no "   expected files=src/a.ts (exit=$rc ran=$(vj ran) changed=$(vj changed_files) kind=$(vj kind))"
grep -q 'other.txt' "$TMP/vout" \
  && no "   {files} leaked a path outside the check's paths" \
  || ok "   ...and {files} is the INTERSECTION -- other.txt was not handed to it"
git -C "$REPO" checkout -q -- . 2>/dev/null; rm -rf "$REPO/pkg" "$REPO/other.txt" "$REPO/docs"

printf 'not json at all' > "$TMP/mangled"
node -e '
  // The exact merge gate.sh performs, against a mangled sidecar: ok must be forced false and the
  // fields must be null rather than optimistic.
  const fs=require("fs");
  let rep=null; try { rep=JSON.parse(fs.readFileSync(process.argv[1],"utf8")) } catch {}
  const sane = rep && typeof rep === "object" && Number.isInteger(rep.ran);
  process.exit(sane ? 1 : 0);
' "$TMP/mangled" \
  && ok "an unparseable sidecar is not treated as sane, so verify --json forces ok=false" \
  || no "a mangled sidecar passed the sanity test"

# The gate's own control variables must not reach the check. Found by running `gate.sh verify` against
# this repository: DOTAGENTS_GATE_DRY=1 was inherited by ./scripts/test-verify-gate.sh, which then ran
# every one of its hook invocations in dry mode, so verifying the repo reported its own gate suite as
# failing. A check is repository code, not gate internals.
rm -rf "$GATE"
cat > "$PROFILES/scratch.json" <<JSON
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "env-leak",
                "cmd": "printenv DOTAGENTS_GATE_DRY > $TMP/leaked 2>&1; printenv DOTAGENTS_GATE_NOW >> $TMP/leaked 2>&1; true",
                "gate": true, "agent_may_run": true } ] }
JSON
rm -f "$TMP/leaked"
DOTAGENTS_GATE_NOW=1 verify "$REPO" >/dev/null
[[ ! -s "$TMP/leaked" ]] \
  && ok "the gate's control variables do not reach the check" \
  || no "leaked into the check: $(tr '\n' ' ' < "$TMP/leaked")"

echo
echo "gate.sh — the machine-readable surface"
echo

# One surface a driver may parse. Prose gets reworded; new exit codes mean litigating what each one
# means. Read-only, like `status` itself -- reading state must never be what changes it.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "typecheck", "cmd": "true", "gate": true, "agent_may_run": false,
                "delegate_reason": "needs heap" } ] }
JSON
DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" record typecheck "$REPO" >/dev/null
js="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status --json "$REPO" 2>/dev/null)"
jf() { node -e '
  let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { const v = process.argv[1].split(".").reduce((o,k)=>o?.[k], JSON.parse(s));
          console.log(typeof v === "object" ? JSON.stringify(v) : String(v)); }
    catch { console.log("parse-error"); }
  });' "$1" <<<"$js"; }
[[ "$(jf armed)" == "true" ]] \
  && ok "status --json reports armed" \
  || no "status --json armed=$(jf armed) (raw: $(head -c 120 <<<"$js"))"
[[ "$(jf gave_up)" == "false" ]] && ok "   gave_up is false while it is still holding" \
                                 || no "   gave_up=$(jf gave_up)"
grep -q typecheck <<<"$(jf recorded)" && ok "   the delegated record is listed" \
                                      || no "   recorded=$(jf recorded)"
[[ "$(jf ttl_seconds)" == "43200" ]] && ok "   the reclaim window is stated, not implied" \
                                     || no "   ttl_seconds=$(jf ttl_seconds)"

# ...and after giving up, a driver can see that without reading any prose.
rm -rf "$GATE"; arm
write_profile <<'JSON'
{ "match": { "remote": "example/scratch" },
  "checks": [ { "id": "boom", "cmd": "false", "gate": true, "agent_may_run": true } ] }
JSON
DOTAGENTS_GATE_MAX_ATTEMPTS=1 invoke >/dev/null
js="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status --json "$REPO" 2>/dev/null)"
[[ "$(jf gave_up)" == "true" ]] && ok "status --json reports the give-up" \
                                || no "   gave_up=$(jf gave_up) after the gate gave up"
[[ "$(jf verdict.reason)" == "red" ]] && ok "   ...with the reason" \
                                      || no "   verdict.reason=$(jf verdict.reason)"
[[ "$(jf verdict.check)" == "boom" ]] && ok "   ...and the check" \
                                      || no "   verdict.check=$(jf verdict.check)"

# Not armed at all must still be valid JSON, or a driver has to special-case it.
disarm
js="$(DOTAGENTS_GATE_DIR="$GATE" bash "$GATE_SH" status --json "$REPO" 2>/dev/null)"
[[ "$(jf armed)" == "false" ]] && ok "an unarmed repo still answers with valid JSON" \
                               || no "   armed=$(jf armed) (raw: $(head -c 120 <<<"$js"))"

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
