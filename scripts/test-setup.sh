#!/usr/bin/env bash
# Tests for the installer, against a fake HOME. Nothing here touches the real one.
#
# The installer is the component that edits files it does not own -- agent settings holding
# credentials, hooks registered by other tools. It had syntax checks and nothing else, while the
# gate had 42 behavioural tests. That was the wrong way round.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"

# One probe is created inside the repository under test, because pruning is what it exercises: the
# installer only prunes what the repo has stopped shipping, so the repo has to stop shipping
# something. It is removed inline, and named in the trap as well -- without that, an abort between
# creating and removing it leaves skills/ephemeral-probe in the working tree, and a loop that runs
# check.sh and then commits would commit it.
PROBE_STAGED="$REPO/skills/_ephemeral-probe"
PROBE_LIVE="$REPO/skills/ephemeral-probe"
trap 'rm -rf "$TMP" "$PROBE_STAGED" "$PROBE_LIVE"' EXIT INT TERM

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
  "skillOverrides": { "pdf": "on", "someone-elses-skill": "off" },
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

# skillOverrides is a map we share with the user: we add entries, we must not rewrite theirs. `pdf`
# is deliberately set to a DIFFERENT value than our snippet asks for, so it exercises the
# "already set to something else -- not ours to change" branch rather than a no-op.
so() { node -e 'const f=process.argv[1];try{const s=require(f).skillOverrides||{};console.log(s[process.argv[2]]??"absent")}catch{console.log("absent")}' "$FAKE/.claude/settings.json" "$1"; }
check "an override the user set to a different value is left alone" "on"  "$(so pdf)"
check "an override for a skill we know nothing about survives"     "off" "$(so someone-elses-skill)"
check "our own override is applied"      "name-only" "$(so claude-api)"
check "an 'off' override is applied"     "off"       "$(so 'anthropic-skills:schedule')"

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

# The Stop hook must carry an explicit timeout. Left to the harness default, a slow suite gets the
# hook killed -- and a killed hook exits with neither 0 nor 2, which is non-blocking. That is the gate
# turning into a silent pass, the one failure it exists to prevent. It also has to be larger than the
# gate's own budget, so our clock is the one that fires and the timeout is an event we can record.
hook_timeout() { # <event> <substring>
  node -e '
    const s = require(process.argv[1]);
    let found = "absent";
    for (const slot of (s.hooks?.[process.argv[2]] ?? []))
      for (const h of (slot.hooks ?? []))
        if (found === "absent" && (h.command ?? "").includes(process.argv[3]))
          found = h.timeout ?? "absent";
    console.log(found);
  ' "$FAKE/.claude/settings.json" "$1" "$2"
}
st="$(hook_timeout Stop dotagents-verify-gate)"
[[ "$st" != "absent" ]] && (( st > 780 )) \
  && ok "the Stop hook timeout exceeds the gate's worst case (600+180) (${st}s)" \
  || no "the Stop hook timeout is $st -- a harness kill is non-blocking, so this fails open"
[[ "$(hook_timeout PreToolUse dotagents-lint-skill-frontmatter)" != "absent" ]] \
  && ok "the lint hook declares a timeout too" \
  || no "the lint hook has no timeout"

# Subagents have to reach both agents. `setup.sh` used to link only ~/.claude/agents/ on the strength
# of a comment claiming Cursor reads that directory too -- which is not in Cursor's documentation
# (it names .cursor/agents/ and ~/.cursor/agents/), and ~/.cursor/agents/ was empty on the author's
# machine. So the README claimed both subagents existed in every repository while Cursor had neither.
for a in $(ls "$REPO/agents" | sed 's/\.md$//'); do
  [[ -L "$FAKE/.claude/agents/$a.md" ]] \
    && ok "agent '$a' is linked for Claude Code" || no "agent '$a' missing from ~/.claude/agents"
  [[ -L "$FAKE/.cursor/agents/$a.md" ]] \
    && ok "agent '$a' is linked for Cursor" || no "agent '$a' missing from ~/.cursor/agents"
done

# install twice must change nothing further.
cp "$FAKE/.claude/settings.json" "$TMP/after1"
run_setup install >/dev/null
cmp -s "$TMP/after1" "$FAKE/.claude/settings.json" \
  && ok "install is idempotent" || no "a second install changed settings again"

# ...and an install that changes nothing must not leave a backup behind. The old code took a
# timestamped copy on every install whether anything moved or not, and never removed one: 52 files,
# 208 KB, had accumulated on the author's machine. A backup nobody can distinguish from 51 others is
# not a safety net, and an unattended loop that re-installs per iteration grows it without limit.
backups() { ls -1 "$FAKE/.claude/settings.json".dotagents-backup-* 2>/dev/null | wc -l | tr -d ' '; }
before_n="$(backups)"
run_setup install >/dev/null
[[ "$(backups)" == "$before_n" ]] \
  && ok "an install that changes nothing takes no backup" \
  || no "a no-op install still took a backup ($before_n -> $(backups))"

# A destination that is not ours must stop the install before anything is written. link_skill returned
# 1 in that case, and under `set -e` that ended the script partway: some skills linked, no hooks
# copied, no settings merged, no manifest to uninstall from. The node preflight was added to prevent
# exactly that state; this reached it by another route.
CLASH="$TMP/clash-home"
mkdir -p "$CLASH/.claude" "$CLASH/.agents/skills/da-verify"     # a real directory where a link belongs
clash_out="$(HOME="$CLASH" bash "$REPO/scripts/setup.sh" install 2>&1; echo "rc=$?")"
grep -q 'rc=0' <<<"$clash_out" \
  && no "an install over a foreign directory succeeded -- it should refuse" \
  || ok "an install over a foreign directory refuses"
[[ ! -e "$CLASH/.claude/.dotagents-managed.json" ]] && [[ ! -d "$CLASH/.claude/hooks" ]] \
  && ok "   ...and wrote nothing at all (no manifest, no hooks)" \
  || no "   it wrote something before refusing: $(ls -a "$CLASH/.claude" | tr '\n' ' ')"
grep -qi 'nothing has been changed' <<<"$clash_out" \
  && ok "   ...and says so" || no "   refused without saying nothing changed"

# The reason this file exists: a skill removed from the repo must stop being installed, with no flag.
mkdir -p "$PROBE_STAGED"
cat > "$PROBE_STAGED/SKILL.md" <<'SK'
---
name: ephemeral-probe
description: Temporary. Use when testing the installer.
metadata:
  source: bwkw/dotagents
---
## Preconditions
none
SK
mv "$PROBE_STAGED" "$PROBE_LIVE"
run_setup install >/dev/null
[ -e "$FAKE/.claude/skills/ephemeral-probe" ] && ok "a new skill is picked up" || no "new skill not linked"
rm -r "$PROBE_LIVE"
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
# Uninstall has to clear both agent directories. Leaving one behind is the same failure as the install
# side: the toolkit reports itself gone while Cursor still dispatches to a subagent it defines.
left="$(ls "$FAKE/.claude/agents" "$FAKE/.cursor/agents" 2>/dev/null | grep -c '\.md$' || true)"
[[ "$left" == "0" ]] \
  && ok "uninstall leaves no agent links in either directory" \
  || no "$left agent link(s) survived uninstall"

# --- bounded state, after the uninstall comparisons ----------------------------
# Last, because both of these overwrite the settings fixture to force a real merge, and the uninstall
# assertions above compare against the original bytes.
run_setup install >/dev/null

# And the count is bounded. Seeded with distinct old stamps rather than by installing in a loop: the
# stamp is second-resolution, so five installs inside one second reused one filename and the test
# passed while proving nothing.
for d in 20200101000001 20200101000002 20200101000003 20200101000004 20200101000005; do
  : > "$FAKE/.claude/settings.json.dotagents-backup-$d"
done
seeded="$(backups)"
printf '{"model":"sonnet"}\n' > "$FAKE/.claude/settings.json"   # force a real change
run_setup install >/dev/null
(( $(backups) <= 3 )) \
  && ok "backups are pruned to 3 generations (was $seeded, now $(backups))" \
  || no "$(backups) backups kept out of $seeded seeded -- the count is unbounded"
# The newest must be the ones kept, or the pruning threw away the pre-image you would actually want.
ls -1 "$FAKE/.claude/settings.json".dotagents-backup-* 2>/dev/null | grep -q '20200101000001' \
  && no "pruning kept the oldest backup and dropped newer ones" \
  || ok "   the oldest were the ones dropped"

# The manifest is the only record uninstall has of what to take back, so a duplicate entry is a
# request to remove something that does not exist. `dropOurs` clears every spelling of our hooks from
# settings.json before rewriting, but the manifest side only appended -- so an old spelling stayed
# forever. Four records for two hooks, measured.
mrec() { node -e '
  const m = require(process.argv[1]);
  console.log((m[process.argv[2]] ?? []).length);
' "$FAKE/.claude/.dotagents-managed.json" "$1"; }

# Seeded with the stale spelling, because a clean fake HOME cannot reproduce it -- the four records on
# the real machine came from a version that recorded an unresolved $HOME. A test that starts clean
# would pass without the fix.
node -e '
  const fs = require("fs"), p = process.argv[1];
  const m = JSON.parse(fs.readFileSync(p, "utf8"));
  m.settingsHooks = [
    { event: "Stop", matcher: "", command: "$HOME/.claude/hooks/dotagents-verify-gate.sh" },
    ...(m.settingsHooks ?? []),
    { event: "PreToolUse", matcher: "", command: "someone-elses-hook.sh" },
  ];
  m.cursorHooks = [
    { event: "stop", command: "$HOME/.claude/hooks/dotagents-verify-gate.sh" },
    ...(m.cursorHooks ?? []),
  ];
  fs.writeFileSync(p, JSON.stringify(m, null, 2) + "\n");
' "$FAKE/.claude/.dotagents-managed.json"
printf '{"model":"haiku"}\n' > "$FAKE/.claude/settings.json"    # force a real merge
run_setup install >/dev/null
check "a stale hook spelling is dropped from the manifest, not accumulated" 3 "$(mrec settingsHooks)"
check "the Cursor side too" 2 "$(mrec cursorHooks)"
node -e '
  const m = require(process.argv[1]);
  process.exit((m.settingsHooks ?? []).some(h => (h.command ?? "").includes("someone-elses-hook")) ? 0 : 1);
' "$FAKE/.claude/.dotagents-managed.json" \
  && ok "   ...and a record that is not ours is left on the manifest" \
  || no "   a foreign manifest record was dropped -- uninstall would stop knowing about it"


if (( fail )); then printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1; fi

printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
