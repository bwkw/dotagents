#!/usr/bin/env bash
# dotagents installer.
#
#   install [--dry-run] [--prune-scripts]   link skills, copy hooks, merge settings
#   status                                  what is installed and whether it is current
#   doctor                                  diagnose drift and breakage
#   uninstall [--dry-run]                   remove exactly what we installed
#
# Skills are symlinked so edits take effect immediately.
# Hooks are copied, because a dangling hook symlink exits 127 and Claude Code treats that as
# non-blocking -- the guardrail would open rather than close. See docs/adr/0002.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
CURSOR_SKILLS="$HOME/.cursor/skills"
CLAUDE_HOOKS="$HOME/.claude/hooks"
MANIFEST="$HOME/.claude/.dotagents-managed.json"

DRY_RUN=0
PRUNE_SCRIPTS=0

# Literal tilde. Writing \~ inline leaves the backslash in bash 3.2 substitutions.
TILDE="~"

c_red=$'\033[31m'; c_green=$'\033[32m'; c_yellow=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
ok()   { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; }
warn() { printf '%s!%s %s\n' "$c_yellow" "$c_off" "$1"; }
bad()  { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; }
note() { printf '%s  %s%s\n' "$c_dim" "$1" "$c_off"; }
run()  { if (( DRY_RUN )); then note "would: $*"; else "$@"; fi; }
# Report what happened, not what would have happened. A dry run that prints "copied" is a lie
# that costs someone an afternoon.
did()  { if (( DRY_RUN )); then note "would $1"; else ok "$1"; fi; }

die() { bad "$1"; exit 1; }

# Every skill directory in the repo, excluding _-prefixed ones (templates, shared fragments).
skill_names() {
  local d
  for d in "$REPO"/skills/*/; do
    [[ -d "$d" ]] || continue
    local n; n="$(basename "$d")"
    [[ "$n" == _* ]] && continue
    [[ -f "$d/SKILL.md" ]] || { warn "skills/$n has no SKILL.md -- skipping" >&2; continue; }
    printf '%s\n' "$n"
  done
}

hook_names() {
  local f
  for f in "$REPO"/hooks/*.sh; do
    [[ -f "$f" ]] || continue
    basename "$f"
  done
}

# Resolve a symlink one level, portably (macOS has no `readlink -f` by default).
link_target() { readlink "$1" 2>/dev/null || true; }

# True when $1 is a symlink already pointing at $2.
points_at() { [[ -L "$1" && "$(link_target "$1")" == "$2" ]]; }

# ---------------------------------------------------------------- install

link_skill() {
  local name="$1"
  local src="$REPO/skills/$name"

  # Physical entry: ~/.agents/skills/<name> -> <repo>/skills/<name>
  if [[ -e "$AGENTS_SKILLS/$name" && ! -L "$AGENTS_SKILLS/$name" ]]; then
    bad "$AGENTS_SKILLS/$name exists as a real directory, not ours -- refusing to replace it"
    return 1
  fi
  if points_at "$AGENTS_SKILLS/$name" "$src"; then
    note "up to date: ~/.agents/skills/$name"
  else
    run ln -sfn "$src" "$AGENTS_SKILLS/$name"
    did "link ~/.agents/skills/$name"
  fi

  # Agent-visible entries point at the physical entry, not at the repo, so there is one
  # place to repoint if the repo ever moves.
  local agent_dir
  for agent_dir in "$CLAUDE_SKILLS" "$CURSOR_SKILLS"; do
    local dest="$agent_dir/$name"
    local rel="../../.agents/skills/$name"   # ~/.claude/skills/<n> -> ~/.agents/skills/<n>
    if [[ -e "$dest" && ! -L "$dest" ]]; then
      bad "$dest exists as a real directory, not ours -- refusing to replace it"
      continue
    fi
    if points_at "$dest" "$rel"; then
      note "up to date: ${agent_dir/#$HOME/$TILDE}/$name"
    else
      run ln -sfn "$rel" "$dest"
      did "link ${agent_dir/#$HOME/$TILDE}/$name"
    fi
  done
}

copy_hook() {
  local f="$1"
  local src="$REPO/hooks/$f"
  local dest="$CLAUDE_HOOKS/$f"
  if [[ -f "$dest" ]] && cmp -s "$src" "$dest"; then
    note "up to date: ~/.claude/hooks/$f"
    return
  fi
  run cp "$src" "$dest"
  run chmod +x "$dest"
  did "copy ~/.claude/hooks/$f"
}

prune_hooks() {
  local shipped; shipped="$(hook_names)"
  local installed f
  # Only prune what a previous run of ours recorded, never files we did not install.
  installed="$(node -e '
    const fs=require("fs");
    try { const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
          (m.hooks||[]).forEach(h=>console.log(h)); } catch {}
  ' "$MANIFEST" 2>/dev/null || true)"
  for f in $installed; do
    if ! grep -qxF "$f" <<<"$shipped"; then
      run rm -f "$CLAUDE_HOOKS/$f"
      did "prune stale hook ~/.claude/hooks/$f"
    fi
  done
}

# Merge only the keys our template declares. Existing values we did not write -- notably
# env.OTEL_EXPORTER_OTLP_HEADERS, which holds a plaintext API key -- are never read or rewritten.
merge_settings() {
  local tmpl="$REPO/templates/claude.settings.snippet.json"
  local target="$HOME/.claude/settings.json"
  [[ -f "$tmpl" ]] || { note "no settings snippet -- skipping"; return; }

  if (( DRY_RUN )); then
    note "would: merge keys from templates/claude.settings.snippet.json into ~/.claude/settings.json"
    node "$REPO/scripts/lib/merge-settings.mjs" --print-keys "$tmpl" | sed 's/^/    /'
    return
  fi

  local backup="$target.dotagents-backup-$(date +%Y%m%d%H%M%S)"
  [[ -f "$target" ]] && cp "$target" "$backup" && note "backup: ${backup/#$HOME/$TILDE}"
  node "$REPO/scripts/lib/merge-settings.mjs" "$tmpl" "$target" "$MANIFEST"
  ok "merged settings into ~/.claude/settings.json"
}

# Cursor keeps its hooks in a different file with a different shape. Same rule: only the entries
# our snippet declares, appended alongside whatever is already registered there.
merge_cursor_hooks() {
  local tmpl="$REPO/templates/cursor.hooks.snippet.json"
  local target="$HOME/.cursor/hooks.json"
  [[ -f "$tmpl" ]] || return 0
  [[ -d "$HOME/.cursor" ]] || { note "no ~/.cursor -- skipping Cursor hooks"; return 0; }

  if (( DRY_RUN )); then
    note "would: merge Cursor hook entries into ~/.cursor/hooks.json"
    return 0
  fi

  local backup="$target.dotagents-backup-$(date +%Y%m%d%H%M%S)"
  [[ -f "$target" ]] && cp "$target" "$backup" && note "backup: ${backup/#$HOME/$TILDE}"
  node "$REPO/scripts/lib/merge-settings.mjs" --cursor "$tmpl" "$target" "$MANIFEST"
  ok "merged hooks into ~/.cursor/hooks.json"
}

write_manifest() {
  (( DRY_RUN )) && return
  local skills hooks
  skills="$(skill_names | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s.split("\n").filter(Boolean))))')"
  hooks="$(hook_names  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s.split("\n").filter(Boolean))))')"
  node -e '
    const fs=require("fs"), p=process.argv[1];
    let m={}; try { m=JSON.parse(fs.readFileSync(p,"utf8")); } catch {}
    m.repo=process.argv[2];
    m.skills=JSON.parse(process.argv[3]);
    m.hooks=JSON.parse(process.argv[4]);
    m.updatedAt=new Date().toISOString();
    fs.writeFileSync(p, JSON.stringify(m,null,2)+"\n");
  ' "$MANIFEST" "$REPO" "$skills" "$hooks"
}

cmd_install() {
  # Installing from a linked worktree points every link into that worktree; removing it later
  # would silently delete the whole toolkit.
  if [[ -f "$REPO/.git" ]]; then
    die "$REPO looks like a linked git worktree. Install from the main checkout instead --
    removing the worktree would take every installed skill with it."
  fi

  run mkdir -p "$AGENTS_SKILLS" "$CLAUDE_SKILLS" "$CURSOR_SKILLS" "$CLAUDE_HOOKS"

  local n
  while read -r n; do [[ -n "$n" ]] && link_skill "$n"; done < <(skill_names)
  while read -r n; do [[ -n "$n" ]] && copy_hook  "$n"; done < <(hook_names)

  (( PRUNE_SCRIPTS )) && prune_hooks
  merge_settings
  merge_cursor_hooks
  write_manifest

  echo
  ok "install complete$( (( DRY_RUN )) && echo ' (dry run -- nothing changed)')"
  note "verify with: scripts/setup.sh status"
}

# ---------------------------------------------------------------- status / doctor

cmd_status() {
  local n missing=0 total=0
  echo "skills"
  while read -r n; do
    [[ -n "$n" ]] || continue
    total=$((total+1))
    local a="$AGENTS_SKILLS/$n" c="$CLAUDE_SKILLS/$n" u="$CURSOR_SKILLS/$n"
    if [[ -d "$a" && -d "$c" && -d "$u" ]]; then
      ok "$n  ${c_dim}(agents+claude+cursor)${c_off}"
    else
      local where=""
      [[ -d "$a" ]] || where+=" agents"
      [[ -d "$c" ]] || where+=" claude"
      [[ -d "$u" ]] || where+=" cursor"
      bad "$n  missing:$where"; missing=$((missing+1))
    fi
  done < <(skill_names)

  echo
  echo "hooks"
  while read -r n; do
    [[ -n "$n" ]] || continue
    if [[ ! -f "$CLAUDE_HOOKS/$n" ]]; then
      bad "$n  not installed"; missing=$((missing+1))
    elif cmp -s "$REPO/hooks/$n" "$CLAUDE_HOOKS/$n"; then
      ok "$n"
    else
      warn "$n  installed copy differs from source -- run: scripts/setup.sh install"
    fi
  done < <(hook_names)

  echo
  echo "hook wiring"
  local wired
  wired="$(node -e '
    const fs = require("fs");
    const read = (p) => { try { return JSON.parse(fs.readFileSync(p, "utf8")) } catch { return null } };
    const claude = read(process.env.HOME + "/.claude/settings.json");
    const cursor = read(process.env.HOME + "/.cursor/hooks.json");
    const has = (o, path) => JSON.stringify(o ?? {}).includes(path);
    console.log([
      has(claude, "dotagents-verify-gate")            ? "claude-stop" : "-",
      has(claude, "dotagents-lint-skill-frontmatter") ? "claude-lint" : "-",
      has(cursor, "dotagents-verify-gate")            ? "cursor-stop" : "-",
      has(cursor, "dotagents-lint-skill-frontmatter") ? "cursor-lint" : "-",
    ].join(" "));
  ' 2>/dev/null || echo "- - - -")"
  local i=1
  for label in "Claude Stop gate" "Claude frontmatter lint" "Cursor stop gate" "Cursor frontmatter lint"; do
    if [[ "$(echo "$wired" | cut -d" " -f$i)" == "-" ]]; then
      warn "$label  not wired"
    else
      ok "$label"
    fi
    i=$((i+1))
  done
  note "Cursor's stop hook cannot block; it only injects a follow-up. Not parity -- see docs/adr/0003."

  echo
  if (( missing )); then
    bad "$missing item(s) missing of $total skill(s)"
    return 1
  fi
  ok "all $total skill(s) installed"
}

cmd_doctor() {
  local problems=0

  echo "environment"
  [[ -d "$HOME/.claude" ]] && ok "~/.claude exists" || { bad "~/.claude missing"; problems=$((problems+1)); }
  [[ -d "$HOME/.cursor" ]] && ok "~/.cursor exists" || { warn "~/.cursor missing -- Cursor side will not work"; }
  command -v node >/dev/null && ok "node $(node -v)" || { bad "node not found (needed for settings merge)"; problems=$((problems+1)); }

  echo
  echo "dangling links"
  local d found=0
  for d in "$AGENTS_SKILLS"/* "$CLAUDE_SKILLS"/* "$CURSOR_SKILLS"/*; do
    [[ -L "$d" ]] || continue
    if [[ ! -e "$d" ]]; then
      bad "${d/#$HOME/$TILDE} -> $(link_target "$d")  (broken)"
      found=1; problems=$((problems+1))
    fi
  done
  (( found )) || ok "none"

  echo
  echo "foreign entries in our namespace"
  # Real directories we did not create -- e.g. a skill installed by npx skills with --copy.
  found=0
  local ours; ours="$(skill_names)"
  for d in "$CLAUDE_SKILLS"/*; do
    [[ -e "$d" ]] || continue
    local n; n="$(basename "$d")"
    grep -qxF "$n" <<<"$ours" || continue
    [[ -L "$d" ]] || { warn "$n is a real directory but we ship a skill by that name"; found=1; }
  done
  (( found )) || ok "none"

  echo
  echo "hook blocking contract"
  # A guardrail must have a path that actually blocks: exit 2 for Stop/PostToolUse, or a
  # permissionDecision of deny/ask for PreToolUse. Any other exit code is treated as
  # non-blocking, so a hook without one of these silently permits everything it inspects.
  found=0
  local f
  for f in "$REPO"/hooks/*.sh; do
    [[ -f "$f" ]] || continue
    # The status line only renders; it has nothing to block. Guardrails do.
    [[ "$(basename "$f")" == *statusline* ]] && continue
    grep -qE 'exit 2|permissionDecision|followup_message' "$f" \
      || { warn "$(basename "$f") has no blocking path (no 'exit 2', no permissionDecision) -- it cannot stop anything"; found=1; }
  done
  (( found )) || ok "all guardrail hooks can block"

  echo
  (( problems )) && { bad "$problems problem(s) found"; return 1; }
  ok "no problems found"
}

# ---------------------------------------------------------------- uninstall

cmd_uninstall() {
  [[ -f "$MANIFEST" ]] || die "no manifest at ${MANIFEST/#$HOME/$TILDE} -- nothing recorded as installed"

  local skills hooks
  skills="$(node -e 'const m=require(process.argv[1]);(m.skills||[]).forEach(s=>console.log(s))' "$MANIFEST")"
  hooks="$( node -e 'const m=require(process.argv[1]);(m.hooks ||[]).forEach(s=>console.log(s))' "$MANIFEST")"

  local n
  for n in $skills; do
    local p
    for p in "$CLAUDE_SKILLS/$n" "$CURSOR_SKILLS/$n" "$AGENTS_SKILLS/$n"; do
      # Only remove symlinks. A real directory there is someone else's and stays.
      if [[ -L "$p" ]]; then run rm -f "$p"; did "remove ${p/#$HOME/$TILDE}"
      elif [[ -e "$p" ]]; then warn "${p/#$HOME/$TILDE} is not a symlink -- left in place"; fi
    done
  done

  for n in $hooks; do
    [[ -f "$CLAUDE_HOOKS/$n" ]] && { run rm -f "$CLAUDE_HOOKS/$n"; did "remove ~/.claude/hooks/$n"; }
  done

  if [[ -f "$REPO/templates/claude.settings.snippet.json" ]]; then
    if (( DRY_RUN )); then
      note "would: revert settings keys recorded in the manifest"
    else
      node "$REPO/scripts/lib/merge-settings.mjs" --revert "$HOME/.claude/settings.json" "$MANIFEST"
      ok "reverted settings keys we added"
    fi
  fi

  if [[ -f "$HOME/.cursor/hooks.json" ]]; then
    if (( DRY_RUN )); then
      note "would: remove the Cursor hook entries recorded in the manifest"
    else
      node "$REPO/scripts/lib/merge-settings.mjs" --revert-cursor "$HOME/.cursor/hooks.json" "$MANIFEST"
      ok "reverted Cursor hook entries we added"
    fi
  fi

  (( DRY_RUN )) || rm -f "$MANIFEST"
  echo
  ok "uninstall complete$( (( DRY_RUN )) && echo ' (dry run -- nothing changed)')"
}

# ---------------------------------------------------------------- main

usage() {
  sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
cmd="$1"; shift

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --prune-scripts) PRUNE_SCRIPTS=1 ;;
    -h|--help)       usage ;;
    *) die "unknown option: $arg" ;;
  esac
done

case "$cmd" in
  install)   cmd_install ;;
  status)    cmd_status ;;
  doctor)    cmd_doctor ;;
  uninstall) cmd_uninstall ;;
  -h|--help) usage ;;
  *) bad "unknown command: $cmd"; usage 1 ;;
esac
