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
