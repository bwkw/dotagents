#!/usr/bin/env bash
# Tests for the SKILL.md frontmatter lint hook and the linter's disable-model-invocation scope.
#
# These exist because a first attempt at the scope check matched on the wrong variable and silently
# never fired: the guardrail looked installed and enforced nothing. That is the failure class this
# repository is about, so the scope is asserted rather than assumed.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$REPO/hooks/dotagents-lint-skill-frontmatter.sh"
LINTER="$REPO/scripts/verify-skills.sh"

pass=0 fail=0
c_green=$'\033[32m'; c_red=$'\033[31m'; c_off=$'\033[0m'
ok()  { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
bad() { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }

command -v node >/dev/null || { echo "node is required"; exit 1; }

# Emit the real hook envelope. Claude Code sends hook_event_name; Cursor does not, and the payload
# is nested under tool_input in both. A test that puts fields at the top level passes vacuously.
payload() { # name dialect body_lines...
  local name="$1" dialect="$2"; shift 2
  node -e '
    const [name, dialect, ...lines] = process.argv.slice(1);
    const ev = { tool_input: { file_path: `/probe/skills/${name}/SKILL.md`,
                               content: lines.join("\n") + "\n" } };
    if (dialect === "claude") ev.hook_event_name = "PreToolUse";
    process.stdout.write(JSON.stringify(ev));
  ' "$name" "$dialect" "$@"
}

decision() { # reads hook stdout, prints deny|ask|allow
  node -e '
    let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
      if (!s.trim()) return console.log("empty");
      try { const j=JSON.parse(s);
            console.log(j.hookSpecificOutput?.permissionDecision ?? j.permission ?? "allow"); }
      catch { console.log("parse-error"); }
    });'
}

probe_dmi() { # name expect dialect
  local name="$1" expect="$2" dialect="$3" got
  got="$(payload "$name" "$dialect" \
    "---" "name: $name" "description: Use when testing this." \
    "disable-model-invocation: true" "---" "body" \
    | bash "$HOOK" 2>/dev/null | decision)"
  [[ "$got" == "$expect" ]] \
    && ok "hook/$dialect: disable-model-invocation on '$name' -> $got" \
    || bad "hook/$dialect: disable-model-invocation on '$name' -> $got (expected $expect)"
}

echo "lint hook: disable-model-invocation scope"

# Denied: something reaches these by name, so the field breaks them silently.
for d in claude cursor; do
  probe_dmi da-verify          deny "$d"
  probe_dmi da-review-backend  deny "$d"
  probe_dmi da-review-frontend deny "$d"
  probe_dmi da-review-infra    deny "$d"
done

# Allowed with a warning: legitimate for a user-invoked workflow. Officially recommended, and free.
for d in claude cursor; do
  probe_dmi da-pr-describe  ask "$d"
  probe_dmi da-skills-audit ask "$d"
  probe_dmi anything-else ask "$d"
done

echo
echo "lint hook: the deny reason names the actual consequence"
reason() { payload "$1" claude "---" "name: $1" "description: Use when testing." \
  "disable-model-invocation: true" "---" "b" | bash "$HOOK" 2>/dev/null \
  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const j=JSON.parse(s);
      process.stdout.write(j.hookSpecificOutput?.permissionDecisionReason ?? "");}catch{}})'; }

grep -q 'fails OPEN' <<<"$(reason da-verify)" \
  && ok "verify: the reason says the gate fails OPEN" \
  || bad "verify: the reason does not mention failing open"
grep -q 'reviewing nothing' <<<"$(reason da-review-backend)" \
  && ok "review-backend: the reason says the layer would be reported as covered" \
  || bad "review-backend: the reason does not say what breaks"

echo
echo "lint hook: the pre-existing checks still hold"

got="$(payload foo claude "---" "name: foo" "---" "b" | bash "$HOOK" 2>/dev/null | decision)"
[[ "$got" == "deny" ]] && ok "a missing description is denied" || bad "a missing description -> $got"

got="$(payload foo claude "---" "description: Use when x." "---" "b" | bash "$HOOK" 2>/dev/null | decision)"
[[ "$got" == "deny" ]] && ok "a missing name is denied" || bad "a missing name -> $got"

got="$(payload foo claude "---" "name: foo" "description: Formats spreadsheets." "---" "b" \
  | bash "$HOOK" 2>/dev/null | decision)"
[[ "$got" == "ask" ]] && ok "a description with no 'when' asks" || bad "a description with no 'when' -> $got"

got="$(node -e 'process.stdout.write(JSON.stringify({hook_event_name:"PreToolUse",
  tool_input:{file_path:"/probe/src/index.ts",content:"---\nname: x\n---\n"}}))' \
  | bash "$HOOK" 2>/dev/null | decision)"
[[ "$got" == "allow" ]] && ok "a non-SKILL.md path is left alone" || bad "a non-SKILL.md path -> $got"

got="$(node -e 'process.stdout.write("not json")' | bash "$HOOK" 2>/dev/null | decision)"
[[ "$got" == "allow" ]] && ok "unparseable input falls through open (this hook only inspects)" \
                        || bad "unparseable input -> $got"

echo
echo "verify-skills.sh: the same scope, in the linter"

PROBE="$(mktemp -d "${TMPDIR:-/tmp}/dotagents-lint-test.XXXXXX")" || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$PROBE"' EXIT

mk() { # name
  mkdir -p "$PROBE/$1"
  { printf '%s\n' "---" "name: $1" "description: Use when testing the linter scope." \
      "disable-model-invocation: true" "metadata:" "  source: bwkw/dotagents" "---" "" \
      "## Preconditions" "| Condition | If unmet |" "|---|---|" "| x | stop |"; } > "$PROBE/$1/SKILL.md"
}
for n in da-verify da-review-backend da-review-frontend da-review-infra da-pr-describe da-skills-audit; do mk "$n"; done

# Strip ANSI colour before matching -- the marker and the text are separated by a reset sequence,
# so a literal "✗ skills/x" pattern never matches the raw output.
out="$("$LINTER" "$PROBE" 2>&1 | sed $'s/\033\\[[0-9;]*m//g')"
for n in da-verify da-review-backend da-review-frontend da-review-infra; do
  grep -q "^✗ skills/$n:" <<<"$out" \
    && ok "linter errors on '$n'" || bad "linter did NOT error on '$n'"
done
for n in da-pr-describe da-skills-audit; do
  grep -q "^✗ skills/$n:" <<<"$out" \
    && bad "linter wrongly errors on '$n'" || ok "linter allows '$n'"
done

"$LINTER" "$PROBE" >/dev/null 2>&1 && bad "linter exit code was 0 despite errors" \
                                   || ok "linter exits non-zero on the denied cases"

echo
if (( fail )); then
  printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"
  exit 1
fi
printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
