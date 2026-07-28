#!/usr/bin/env bash
# Tests for the installer, against a fake HOME. Nothing here touches the real one.
#
# The installer is the component that edits files it does not own -- agent settings holding
# credentials, hooks registered by other tools. It had syntax checks and nothing else, while the
# gate had 42 behavioural tests. That was the wrong way round.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
c_red=$'\033[31m'; c_green=$'\033[32m'; c_off=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no()   { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }
check(){ if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected [$2], got [$3])"; fi; }

FAKE="$TMP/home"
mkdir -p "$FAKE/.claude" "$FAKE/.cursor"

# A settings file that looks like a real one: a secret we must never touch, and another tool's hook.
cat > "$FAKE/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "env": { "SECRET_TOKEN": "do-not-touch-me" },
  "hooks": {
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "other-tool hook" } ] } ],
    "Stop": [ { "matcher": "", "hooks": [ { "type": "command", "command": "~/notify.sh" } ] } ]
  }
}
JSON
cp "$FAKE/.claude/settings.json" "$TMP/settings.before"
printf '{ "version": 1, "hooks": { "preToolUse": [ { "command": "other-tool", "matcher": "Shell" } ] } }\n' \
  > "$FAKE/.cursor/hooks.json"
cp "$FAKE/.cursor/hooks.json" "$TMP/cursor.before"

run_setup() { HOME="$FAKE" bash "$REPO/scripts/setup.sh" "$@" 2>&1; }
j() { node -e 'const f=process.argv[1];try{console.log(JSON.stringify(require(f)))}catch{console.log("{}")}' "$1"; }

echo "installer"
echo

run_setup install >/dev/null
check "install links every shipped skill" \
  "$(ls "$REPO/skills" | grep -vc '^_')" "$(ls "$FAKE/.claude/skills" | wc -l | tr -d ' ')"

grep -q 'do-not-touch-me' "$FAKE/.claude/settings.json" \
  && ok "a secret we did not write is untouched" || no "THE SECRET WAS ALTERED"

grep -q 'other-tool hook' "$FAKE/.claude/settings.json" \
  && ok "another tool's PreToolUse hook survives" || no "another tool's hook was dropped"
grep -q 'notify.sh' "$FAKE/.claude/settings.json" \
  && ok "another tool's Stop hook survives" || no "another tool's Stop hook was dropped"
grep -q 'other-tool' "$FAKE/.cursor/hooks.json" \
  && ok "another tool's Cursor hook survives" || no "another tool's Cursor hook was dropped"

# Hook commands must be absolute, or the shell cannot start them and the guardrail fails open.
grep -q '\$HOME' "$FAKE/.claude/settings.json" \
  && no "a hook command still contains an unexpanded \$HOME" \
  || ok "hook commands are absolute"

# install twice must change nothing further.
cp "$FAKE/.claude/settings.json" "$TMP/after1"
run_setup install >/dev/null
cmp -s "$TMP/after1" "$FAKE/.claude/settings.json" \
  && ok "install is idempotent" || no "a second install changed settings again"

# The reason this file exists: a skill removed from the repo must stop being installed, with no flag.
mkdir -p "$REPO/skills/_ephemeral-probe"
cat > "$REPO/skills/_ephemeral-probe/SKILL.md" <<'SK'
---
name: ephemeral-probe
description: Temporary. Use when testing the installer.
metadata:
  source: bwkw/dotagents
---
## Preconditions
none
SK
mv "$REPO/skills/_ephemeral-probe" "$REPO/skills/ephemeral-probe"
run_setup install >/dev/null
[ -e "$FAKE/.claude/skills/ephemeral-probe" ] && ok "a new skill is picked up" || no "new skill not linked"
rm -r "$REPO/skills/ephemeral-probe"
run_setup install >/dev/null
[ -e "$FAKE/.claude/skills/ephemeral-probe" ] \
  && no "a deleted skill is still installed -- pruning is not automatic" \
  || ok "a deleted skill is pruned without a flag"
[ -L "$FAKE/.claude/skills/ephemeral-probe" ] \
  && no "a dangling symlink was left behind" || ok "no dangling symlink left behind"

# uninstall must take back exactly what was added, and nothing else.
run_setup uninstall >/dev/null

# Content, not bytes. The merge rewrites JSON with a fixed 2-space layout, so an original formatted
# any other way cannot come back identical -- the README used to claim it did, which was false.
# JSON.parse, not require: require() decides how to read a file from its extension, and these
# fixtures have none -- so it parsed them as JavaScript and threw.
pretty() { node -e '
  const fs = require("fs");
  console.log(JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1], "utf8")), null, 2));
' "$1"; }

same_content() { # same_content <before> <after> <label>
  if node -e '
    const fs = require("fs");
    const load = (f) => JSON.parse(fs.readFileSync(f, "utf8"));
    const deep = (x, y) => {
      if (x === y) return true;
      if (typeof x !== typeof y || x === null || y === null || typeof x !== "object") return false;
      if (Array.isArray(x) !== Array.isArray(y)) return false;
      const kx = Object.keys(x), ky = Object.keys(y);
      return kx.length === ky.length && kx.every((k) => deep(x[k], y[k]));
    };
    process.exit(deep(load(process.argv[1]), load(process.argv[2])) ? 0 : 1);
  ' "$1" "$2"; then ok "$3"; else no "$3"; diff <(pretty "$1") <(pretty "$2") | head -8; fi
}
same_content "$TMP/settings.before" "$FAKE/.claude/settings.json" \
  "uninstall restores every settings key to its original value"
same_content "$TMP/cursor.before" "$FAKE/.cursor/hooks.json" \
  "uninstall restores Cursor hooks to their original value"

grep -q 'dotagents' "$FAKE/.claude/settings.json" \
  && no "uninstall left one of our entries behind" || ok "nothing of ours is left in settings"
[ -d "$FAKE/.claude/skills" ] && [ "$(ls "$FAKE/.claude/skills" | wc -l | tr -d ' ')" = "0" ] \
  && ok "no skill links remain" || no "skill links remain after uninstall"

echo
if (( fail )); then printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1; fi
printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
