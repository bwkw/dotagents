#!/usr/bin/env bash
# dotagents installer.
#
#   install [--dry-run] [--no-opinions]     link skills, copy hooks, merge settings, and remove
#                                          anything we installed that the repo no longer ships
#
#     --no-opinions    merge the mechanism (`hooks`) only, and skip the keys the settings template
#                      lists in $opinionKeys: verbose telemetry, and the skillOverrides that quiet
#                      bundled and plugin skills.
#
#                      These are ON by default because this toolkit has one user, and that user
#                      wrote them. They were opt-in for a while, on the theory that installing a
#                      verification gate is not consent to changing how other skills behave -- true
#                      for a stranger, and the stranger does not exist. What the flag actually did
#                      was make the author retype it on every machine. Use --no-opinions on a
#                      machine where the bundled skills should be left alone.
#   status                                  what is installed and whether it is current
#   doctor                                  diagnose drift and breakage
#   uninstall [--dry-run]                   remove exactly what we installed
#
# Skills are symlinked so edits take effect immediately.
# Hooks are copied, because a dangling hook symlink exits 127 and Claude Code treats that as
# non-blocking -- the guardrail would open rather than close. See docs/decisions.md.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AGENTS_SKILLS="$HOME/.agents/skills"
CLAUDE_SKILLS="$HOME/.claude/skills"
CURSOR_SKILLS="$HOME/.cursor/skills"
CLAUDE_HOOKS="$HOME/.claude/hooks"
# Linked into BOTH agent directories. The comment here used to say "Cursor reads ~/.claude/agents/ as
# well as its own, so one link covers both" -- that is not in Cursor's documentation, which names
# .cursor/agents/ for a project and ~/.cursor/agents/ for global definitions. And ~/.cursor/agents/ was
# empty on this machine, so both subagents were simply absent in Cursor while the README claimed they
# existed everywhere. An unverified claim that happened to be convenient.
CLAUDE_AGENTS="$HOME/.claude/agents"
CURSOR_AGENTS="$HOME/.cursor/agents"
MANIFEST="$HOME/.claude/.dotagents-managed.json"

DRY_RUN=0
# On by default: one user, who wrote them. `--no-opinions` turns them off. See the header.
WITH_OPINIONS=1

# Holds the filtered settings snippet while a merge runs. Cleaned on every exit path: `set -e` and
# `die` both leave the function early, and a scratch file under $TMPDIR that nothing removes is the
# same unbounded-growth bug as the backups that were never pruned.
SETTINGS_SCRATCH=""
trap '[[ -n "$SETTINGS_SCRATCH" ]] && rm -f "$SETTINGS_SCRATCH"' EXIT

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

agent_names() {
  local f
  for f in "$REPO"/agents/*.md; do
    [[ -f "$f" ]] || continue
    local n; n="$(basename "$f" .md)"
    [[ "$n" == _* ]] && continue
    printf '%s\n' "$n"
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

  # Only Claude Code needs a link. Cursor reads ~/.agents/skills natively -- confirmed by observing
  # an upstream skill with no ~/.cursor/skills entry appear in its menu -- and a skill reachable from
  # both paths is listed once, not twice. See docs/decisions.md.
  local dest="$CLAUDE_SKILLS/$name"
  local rel="../../.agents/skills/$name"   # ~/.claude/skills/<n> -> ~/.agents/skills/<n>
  if [[ -e "$dest" && ! -L "$dest" ]]; then
    bad "$dest exists as a real directory, not ours -- refusing to replace it"
  elif points_at "$dest" "$rel"; then
    note "up to date: ~/.claude/skills/$name"
  else
    run ln -sfn "$rel" "$dest"
    did "link ~/.claude/skills/$name"
  fi

  # Earlier versions created a ~/.cursor/skills link too. Remove ours, but only if it is a symlink
  # pointing where we would have pointed it -- anything else belongs to someone else.
  if points_at "$CURSOR_SKILLS/$name" "$rel"; then
    run rm -f "$CURSOR_SKILLS/$name"
    did "remove the now-redundant ~/.cursor/skills/$name"
  fi
}

link_agent() {
  local name="$1"
  local src="$REPO/agents/$name.md"
  local d dir label

  # Symlinked, not copied. Unlike hooks, a dangling agent link cannot fail open: the agent simply
  # does not resolve and the caller falls back to general-purpose, which is visible in the
  # transcript. Linking keeps edits here effective immediately.
  for dir in "$CLAUDE_AGENTS" "$CURSOR_AGENTS"; do
    d="$dir/$name.md"
    label="${dir/#$HOME/$TILDE}/$name.md"
    if [[ -e "$d" && ! -L "$d" ]]; then
      bad "$d exists as a real file, not ours -- refusing to replace it"
      return 1
    fi
    if points_at "$d" "$src"; then
      note "up to date: $label"
    else
      run ln -sfn "$src" "$d"
      did "link $label"
    fi
  done
}

# Agents dropped from the repository would otherwise stay linked and keep being dispatched to.
prune_agents() {
  local current recorded f name dir label
  local dirs=("$CLAUDE_AGENTS" "$CURSOR_AGENTS")
  current="$(agent_names | tr '\n' ' ')"
  recorded="$(node -e '
    const fs=require("fs");
    try { const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
          console.log((m.agents||[]).join(" ")); } catch { console.log(""); }
  ' "$MANIFEST" 2>/dev/null || true)"

  for dir in "${dirs[@]}"; do
   [[ -d "$dir" ]] || continue
   label="${dir/#$HOME/$TILDE}"
   for f in "$dir"/*.md; do
    # `-e` follows the symlink, so it is false for exactly the links that most need pruning: the ones
    # whose target was renamed or deleted. Test `-L` as well or a rename leaves a dangling link behind
    # and the agent silently resolves to nothing.
    [[ -e "$f" || -L "$f" ]] || continue
    name="$(basename "$f" .md)"
    # Ours by shape (a symlink into this repo's agents/) or by manifest record. Anything else is
    # someone else's and is left alone.
    if points_at "$f" "$REPO/agents/$name.md" || [[ " $recorded " == *" $name "* ]]; then
      [[ " $current " == *" $name "* ]] && continue
      [[ -L "$f" ]] || { warn "$label/$name.md is not a symlink -- leaving it"; continue; }
      run rm -f "$f"
      did "prune $label/$name.md (no longer in the repository)"
    fi
   done

  # Sweep dangling links into this repo's agents/ even when the name was never recorded -- a rename
  # between two installs leaves one behind under the old name, which the loop above cannot match by
  # manifest and which `points_at` alone would not reach if the manifest was rewritten first.
   for f in "$dir"/*.md; do
    [[ -L "$f" && ! -e "$f" ]] || continue
    [[ "$(link_target "$f")" == "$REPO/agents/"* ]] || continue
    run rm -f "$f"
    did "prune $label/$(basename "$f") (dangling -- its target is gone)"
   done
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

# Skills removed from the repository leave three symlinks behind, and write_manifest then forgets
# they existed, so uninstall cannot reclaim them either. Prune before the manifest is rewritten.
prune_skills() {
  local shipped; shipped="$(skill_names)"
  local recorded n q
  recorded="$(node -e '
    const fs=require("fs");
    try { const m=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
          (m.skills||[]).forEach(x=>console.log(x)); } catch {}
  ' "$MANIFEST" 2>/dev/null || true)"
  for n in $recorded; do
    grep -qxF "$n" <<<"$shipped" && continue
    for q in "$CLAUDE_SKILLS/$n" "$CURSOR_SKILLS/$n" "$AGENTS_SKILLS/$n"; do
      # Only ever remove a symlink. A real directory there belongs to someone else.
      if [[ -L "$q" ]]; then run rm -f "$q"; did "prune ${q/#$HOME/$TILDE}"
      elif [[ -e "$q" ]]; then warn "${q/#$HOME/$TILDE} is not a symlink -- left in place"; fi
    done
  done

  # The manifest is not enough on its own. write_manifest rewrites the skill list every install, so
  # an orphan created before pruning became automatic is no longer recorded anywhere -- and a
  # manifest-only reconcile can never reclaim it. Observed exactly that: a test skill left two
  # dangling links that survived every subsequent install.
  #
  # So also sweep by shape, which needs no record: a *dangling* symlink whose target is spelled the
  # way we spell ours. Both patterns are unambiguous and cannot match someone else's link.
  local l t
  shopt -s nullglob
  for l in "$AGENTS_SKILLS"/*; do
    [[ -L "$l" && ! -e "$l" ]] || continue
    t="$(link_target "$l")"
    [[ "$t" == "$REPO/skills/"* ]] || continue
    run rm -f "$l"; did "prune orphaned ${l/#$HOME/$TILDE} (target gone from the repo)"
  done
  for l in "$CLAUDE_SKILLS"/* "$CURSOR_SKILLS"/*; do
    [[ -L "$l" && ! -e "$l" ]] || continue
    t="$(link_target "$l")"
    [[ "$t" == "../../.agents/skills/"* ]] || continue
    run rm -f "$l"; did "prune orphaned ${l/#$HOME/$TILDE} (chain is broken)"
  done
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

# How many pre-images to keep per target. Three is enough to undo a bad install and small enough that
# the directory stays readable; 52 of them had accumulated here, which is not a safety net -- it is a
# pile nobody can tell apart. An unattended loop that re-installs per iteration grows it without limit.
BACKUP_KEEP=3

# Run a merge, and keep a backup only if the merge actually changed the target.
#
# The pre-image is held in a temp file and promoted to a backup only on a real change, rather than
# taken unconditionally and deleted afterwards. Both orders end up with the same files, but only this
# one is never briefly lying about what happened.
merge_with_backup() { # <target> <label> <merge command...>
  local target="$1" label="$2"; shift 2
  local pre="" rc=0
  if [[ -f "$target" ]]; then
    pre="$(mktemp "${TMPDIR:-/tmp}/dotagents-pre.XXXXXX" 2>/dev/null)" || pre=""
    [[ -n "$pre" ]] && cp "$target" "$pre"
  fi

  "$@" || rc=$?

  if [[ -n "$pre" ]]; then
    if cmp -s "$pre" "$target"; then
      rm -f "$pre"
      note "$label unchanged -- no backup taken"
    else
      # $$ as well as the timestamp: the stamp is second-resolution, so two installs inside one second
      # produced the same name and the second silently overwrote the first pre-image.
      local backup="$target.dotagents-backup-$(date +%Y%m%d%H%M%S)-$$"
      mv "$pre" "$backup"
      note "backup: ${backup/#$HOME/$TILDE}"
    fi
  fi

  # Pruned every time, not only when a backup was just taken. Enforcing the cap on the creating path
  # alone leaves a pile that nothing ever touches again: ~/.cursor/hooks.json stopped changing, so its
  # 24 pre-existing backups were never reached. A bound that only applies while you keep adding is not
  # a bound.
  prune_backups "$target"
  return "$rc"
}

# Keep the newest BACKUP_KEEP. Names sort lexically because the stamp is %Y%m%d%H%M%S.
prune_backups() { # <target>
  local target="$1" f n=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    n=$((n+1))
    if (( n > BACKUP_KEEP )); then
      run rm -f "$f"
      did "prune old backup ${f/#$HOME/$TILDE}"
    fi
  done < <(ls -1 "$target".dotagents-backup-* 2>/dev/null | sort -r)
}

# Merge only the keys our template declares. Existing values we did not write -- notably
# env.OTEL_EXPORTER_OTLP_HEADERS, which holds a plaintext API key -- are never read or rewritten.
#
# With --no-opinions the keys listed in the template's own $opinionKeys are dropped first, leaving the
# mechanism (`hooks`) -- which is always merged, because without it nothing here runs at all.
#
# The filtering exists; only the default flipped. It was opt-in on the theory that installing a
# verification gate is not consent to changing how other skills behave. That is right for a stranger,
# and there is no stranger: what the flag bought in practice was the author retyping it per machine.
#
# Filtered into a temp file rather than merged as a second pass, because merge-settings.mjs REPLACES
# manifest.settingsHooks with what the snippet it was just handed declares. A second pass over a
# snippet with no `hooks` would clear our hook records, and the manifest is the only thing uninstall
# has to go on.
effective_settings_snippet() { # <template> -> path to merge (may be a temp file)
  local tmpl="$1"
  if (( WITH_OPINIONS )); then printf '%s\n' "$tmpl"; return; fi

  local out
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-settings.XXXXXX" 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    # No scratch file means we cannot filter. Merging the unfiltered template would apply the
    # opinions without being asked, so decline the whole merge and say why.
    die "could not create a temp file to filter the settings template -- refusing to merge, because
the unfiltered template would apply the opinion keys you asked to skip. Set TMPDIR, or drop
--no-opinions."
  fi
  SETTINGS_SCRATCH="$out"
  node -e '
    const fs = require("fs");
    const snippet = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    // One home for the list: the template. A copy here would be a second thing to update.
    const drop = new Set(snippet.$opinionKeys ?? []);
    for (const k of drop) delete snippet[k];
    delete snippet.$opinionKeys;
    fs.writeFileSync(process.argv[2], JSON.stringify(snippet, null, 2) + "\n");
  ' "$tmpl" "$out"
  printf '%s\n' "$out"
}

merge_settings() {
  local tmpl="$REPO/templates/claude.settings.snippet.json"
  local target="$HOME/.claude/settings.json"
  [[ -f "$tmpl" ]] || { note "no settings snippet -- skipping"; return; }

  local eff; eff="$(effective_settings_snippet "$tmpl")"

  if (( DRY_RUN )); then
    note "would: merge keys from templates/claude.settings.snippet.json into ~/.claude/settings.json"
    (( WITH_OPINIONS )) || note "(mechanism only -- --no-opinions drops env/skillOverrides)"
    node "$REPO/scripts/lib/merge-settings.mjs" --print-keys "$eff" | sed 's/^/    /'
    rm -f "$SETTINGS_SCRATCH"; SETTINGS_SCRATCH=""
    return
  fi

  merge_with_backup "$target" "~/.claude/settings.json" \
    node "$REPO/scripts/lib/merge-settings.mjs" "$eff" "$target" "$MANIFEST"
  rm -f "$SETTINGS_SCRATCH"; SETTINGS_SCRATCH=""
  ok "merged settings into ~/.claude/settings.json$( (( WITH_OPINIONS )) || echo ' (mechanism only)')"
}

merge_cursor_hooks() {
  local tmpl="$REPO/templates/cursor.hooks.snippet.json"
  local target="$HOME/.cursor/hooks.json"
  [[ -f "$tmpl" ]] || return 0

  if (( DRY_RUN )); then
    # install creates ~/.cursor/skills before reaching here, so ~/.cursor always exists by
    # then. Reporting "skipping" on a machine without Cursor would make the dry run disagree
    # with the install it is supposed to preview.
    note "would: merge Cursor hook entries into ~/.cursor/hooks.json"
    return 0
  fi
  mkdir -p "$HOME/.cursor"

  merge_with_backup "$target" "~/.cursor/hooks.json" \
    node "$REPO/scripts/lib/merge-settings.mjs" --cursor "$tmpl" "$target" "$MANIFEST"
  ok "merged hooks into ~/.cursor/hooks.json"
}

write_manifest() {
  (( DRY_RUN )) && return
  local skills hooks agents
  skills="$(skill_names | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s.split("\n").filter(Boolean))))')"
  hooks="$(hook_names  | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s.split("\n").filter(Boolean))))')"
  agents="$(agent_names | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.stringify(s.split("\n").filter(Boolean))))')"
  node -e '
    const fs=require("fs"), p=process.argv[1];
    let m={}; try { m=JSON.parse(fs.readFileSync(p,"utf8")); } catch {}
    m.repo=process.argv[2];
    m.skills=JSON.parse(process.argv[3]);
    m.hooks=JSON.parse(process.argv[4]);
    m.agents=JSON.parse(process.argv[5]);
    m.updatedAt=new Date().toISOString();
    fs.writeFileSync(p, JSON.stringify(m,null,2)+"\n");
  ' "$MANIFEST" "$REPO" "$skills" "$hooks" "$agents"
}

# Everything that can refuse, checked before anything is written.
#
# `link_skill` and `link_agent` return 1 when a destination is a real directory or file that is not
# ours. Under `set -e` that failure was the last command of an `&&` list, so the whole script exited --
# after some skills were already linked, with no hooks copied, no settings merged and no manifest to
# uninstall from. Exactly the state the node preflight above exists to prevent, reached by a different
# route. Refusing up front means the answer is all-or-nothing rather than however far the loop got.
preflight() {
  local n blocked=0
  while read -r n; do
    [[ -n "$n" ]] || continue
    if [[ -e "$AGENTS_SKILLS/$n" && ! -L "$AGENTS_SKILLS/$n" ]]; then
      bad "$AGENTS_SKILLS/$n is a real directory, not ours"; blocked=1
    fi
    if [[ -e "$CLAUDE_SKILLS/$n" && ! -L "$CLAUDE_SKILLS/$n" ]]; then
      bad "$CLAUDE_SKILLS/$n is a real directory, not ours"; blocked=1
    fi
  done < <(skill_names)
  while read -r n; do
    [[ -n "$n" ]] || continue
    local d
    for d in "$CLAUDE_AGENTS" "$CURSOR_AGENTS"; do
      if [[ -e "$d/$n.md" && ! -L "$d/$n.md" ]]; then
        bad "$d/$n.md is a real file, not ours"; blocked=1
      fi
    done
  done < <(agent_names)

  (( blocked )) && die "refusing to install: move or remove the paths above first. Nothing has been changed."
  return 0
}

cmd_install() {
  # Installing from a linked worktree points every link into that worktree; removing it later
  # would silently delete the whole toolkit. The escape hatch is for the installer suite only:
  # test-setup.sh has to exercise install from whatever checkout the gate is standing in, and
  # the loop deliberately works inside linked worktrees. Nothing else sets this.
  if [[ -f "$REPO/.git" && -z "${DOTAGENTS_ALLOW_WORKTREE_INSTALL:-}" ]]; then
    die "$REPO looks like a linked git worktree. Install from the main checkout instead --
    removing the worktree would take every installed skill with it."
  fi

  # Every settings merge and the manifest go through node. Failing partway leaves skills linked
  # but no guardrails wired and no manifest to uninstall from, so check before changing anything.
  command -v node >/dev/null || die "node is required (>= 18). Nothing has been changed."

  preflight

  run mkdir -p "$AGENTS_SKILLS" "$CLAUDE_SKILLS" "$CURSOR_SKILLS" "$CLAUDE_HOOKS" \
    "$CLAUDE_AGENTS" "$CURSOR_AGENTS"

  local n
  while read -r n; do [[ -n "$n" ]] && link_skill "$n"; done < <(skill_names)
  while read -r n; do [[ -n "$n" ]] && copy_hook  "$n"; done < <(hook_names)
  while read -r n; do [[ -n "$n" ]] && link_agent "$n"; done < <(agent_names)

  # Always. install means "make the installed state match the repository", and that includes
  # removing what the repository no longer ships. Both prune functions only touch what a previous
  # run of ours recorded in the manifest, so nothing else is at risk.
  prune_skills
  prune_hooks
  prune_agents
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
    local a="$AGENTS_SKILLS/$n" c="$CLAUDE_SKILLS/$n"
    if [[ -d "$a" && -d "$c" ]]; then
      ok "$n  ${c_dim}(~/.agents, linked from ~/.claude; Cursor reads ~/.agents directly)${c_off}"
    else
      local where=""
      [[ -d "$a" ]] || where+=" agents"
      [[ -d "$c" ]] || where+=" claude"
      bad "$n  missing:$where"; missing=$((missing+1))
    fi
  done < <(skill_names)

  # Skills are symlinked, so the installed instructions ARE this working tree: an edit is live the
  # next time a skill is read, with no install step and nothing recorded. That includes an edit made
  # by an agent, in the same session, to the instructions it is following.
  #
  # No hashes are kept for this. The earlier design put a sha256 per skill in the manifest, which is
  # a second record of something git already records exactly -- and a baseline written at install time
  # records whatever was there at install time, including a change nobody reviewed. git is the
  # baseline, and `git status` is the comparison.
  echo
  echo "skill bodies vs the last commit"
  if git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    local drift; drift="$(git -C "$REPO" status --porcelain -- skills/ 2>/dev/null)"
    if [[ -z "$drift" ]]; then
      ok "identical to HEAD ${c_dim}($(git -C "$REPO" rev-parse --short HEAD 2>/dev/null))${c_off}"
    else
      # Not a failure. Editing skills is the normal way to work on this repository, and the point is
      # that it is *visible* -- an uncommitted change to an agent's own instructions should never be
      # something you have to go looking for.
      warn "uncommitted, and therefore already live:"
      while IFS= read -r line; do [[ -n "$line" ]] && note "  $line"; done <<<"$drift"
    fi
  else
    warn "$REPO is not a git checkout -- there is no baseline to compare skill bodies against"
  fi

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
  echo "agents"
  while read -r n; do
    [[ -n "$n" ]] || continue
    total=$((total+1))
    local where=""
    points_at "$CLAUDE_AGENTS/$n.md" "$REPO/agents/$n.md" && where="claude"
    points_at "$CURSOR_AGENTS/$n.md" "$REPO/agents/$n.md" && where="${where:+$where+}cursor"
    if [[ "$where" == "claude+cursor" ]]; then
      ok "$n  ${c_dim}(~/.claude/agents and ~/.cursor/agents)${c_off}"
    elif [[ -n "$where" ]]; then
      warn "$n  only in $where -- the other agent cannot reach it"; missing=$((missing+1))
    elif [[ -e "$CLAUDE_AGENTS/$n.md" || -e "$CURSOR_AGENTS/$n.md" ]]; then
      warn "$n  present but not our symlink -- left alone"
    else
      bad "$n  not installed"; missing=$((missing+1))
    fi
  done < <(agent_names)

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
  note "Cursor's stop hook cannot block; it only injects a follow-up. Not parity -- see docs/decisions.md."

  echo
  if (( missing )); then
    bad "$missing item(s) missing of $total skill(s)"
    return 1
  fi
  ok "all $total skill(s) installed"
}

cmd_doctor() {
  local problems=0

  # The flows in README.md hand work to upstream skills this repository deliberately does not vendor.
  # Nothing installs them, and nothing said they were missing: a fresh machine got a documented
  # pipeline whose first step (`/research`) simply did not exist, and a slash command that is not there
  # is silence, not an error. Reported, not fixed -- installing them is `npx skills add`, which is the
  # user's call and is spelled out in README.md.
  #
  # The list is declared once, here. scripts/verify-skills.sh asserts every name still appears in
  # README.md, so a rename upstream cannot leave this checking for something nobody documents.
  # dotagents:upstream-flow-skills research grill-me documentation-and-adrs writing-plans executing-plans test-driven-development systematic-debugging receiving-code-review using-git-worktrees skill-scanner
  echo "upstream skills the documented flows use"
  local UPSTREAM_FLOW_SKILLS="research grill-me documentation-and-adrs writing-plans executing-plans test-driven-development systematic-debugging receiving-code-review using-git-worktrees skill-scanner"
  local u umissing=0
  for u in $UPSTREAM_FLOW_SKILLS; do
    [[ -d "$AGENTS_SKILLS/$u" ]] || { umissing=$((umissing+1)); note "missing: /$u"; }
  done
  if (( umissing == 0 )); then
    ok "all present"
  else
    warn "$umissing not installed -- those steps of the documented flows are absent, silently. See README.md"
  fi

  echo
  # Everything above can be green on a machine where the gate cannot check anything: it is armed per
  # repository, and it resolves what to run from a profile matched on the git remote. With no profile
  # it passes, by design -- guessing commands would be worse. But `status` never mentioned profiles, so
  # a fresh install reported success while the one thing the toolkit is for was absent everywhere.
  # Counted the way the gate counts them: `_`-prefixed files are templates and never match.
  echo "profiles"
  local pn=0 pf
  for pf in "$REPO"/profiles/*.json; do
    [[ -f "$pf" ]] || continue
    case "$(basename "$pf")" in _*) continue ;; esac
    pn=$((pn+1))
  done
  if (( pn > 0 )); then
    ok "$pn profile(s) in $REPO/profiles ${c_dim}(the gate checks a repository only if one matches its remote)${c_off}"
  else
    warn "no profiles -- the gate will pass on every repository, silently. Copy profiles/_example.*.json, or run /da-verify"
  fi

  echo
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
    # Every hook shipped here is a guardrail, so every one must have a blocking path. The exception
    # for a render-only status line went away with the status line itself.
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

  local skills hooks agents
  skills="$(node -e 'const m=require(process.argv[1]);(m.skills||[]).forEach(s=>console.log(s))' "$MANIFEST")"
  hooks="$( node -e 'const m=require(process.argv[1]);(m.hooks ||[]).forEach(s=>console.log(s))' "$MANIFEST")"
  agents="$(node -e 'const m=require(process.argv[1]);(m.agents||[]).forEach(s=>console.log(s))' "$MANIFEST")"

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

  for n in $agents; do
    local a d
    for d in "$CLAUDE_AGENTS" "$CURSOR_AGENTS"; do
      a="$d/$n.md"
      if [[ -L "$a" ]]; then run rm -f "$a"; did "remove ${d/#$HOME/$TILDE}/$n.md"
      elif [[ -e "$a" ]]; then warn "${d/#$HOME/$TILDE}/$n.md is not a symlink -- left in place"; fi
    done
  done

  # Our backups go with us. They are pre-images of a file we were editing; once we are uninstalled they
  # are litter, and 52 of them had accumulated because nothing ever removed one.
  local t
  for t in "$HOME/.claude/settings.json" "$HOME/.cursor/hooks.json"; do
    local b
    while IFS= read -r b; do
      [[ -n "$b" ]] || continue
      run rm -f "$b"
      did "remove ${b/#$HOME/$TILDE}"
    done < <(ls -1 "$t".dotagents-backup-* 2>/dev/null)
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
  # Print the header block up to its first bare '#' line, rather than a hardcoded range that
  # silently drifts every time a flag is documented.
  sed -n '2,/^#$/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'
  exit "${1:-0}"
}

[[ $# -gt 0 ]] || usage 1
cmd="$1"; shift

for arg in "$@"; do
  case "$arg" in
    --dry-run)       DRY_RUN=1 ;;
    --no-opinions)   WITH_OPINIONS=0 ;;
    # Still accepted, and silently: it is now the default, and a warning on a flag that asks for
    # exactly what already happens is noise. Kept because it is in this repository's own history and
    # in muscle memory, and an unknown-option `die` on it would be a puzzling failure.
    --with-opinions) WITH_OPINIONS=1 ;;
    --prune-scripts) warn "--prune-scripts is now the default and is ignored" ;;
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
