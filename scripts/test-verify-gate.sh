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
arm()   { mkdir -p "$GATE/slug"; : > "$GATE/slug/ACTIVE"; }
disarm(){ rm -rf "$GATE"; }

invoke() {
  printf '{"cwd":"%s"}' "$REPO" \
    | DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" bash "$HOOK" 2>"$TMP/stderr"
  echo $?
}

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
echo '{"typecheck": "passed"}' > "$GATE/slug/delegated.json"
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
