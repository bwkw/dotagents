#!/usr/bin/env bash
# Arm and disarm the verification gate.
#
#   gate.sh arm [dir]            hold this repository's session until its checks pass
#   gate.sh disarm [dir]         release it
#   gate.sh record <check> [dir] note that the user ran a delegated check themselves
#   gate.sh status [dir]         is it armed, and what has been recorded
#
# The gate hook does nothing unless armed. Skills call this; nothing else needs to.
#
# The sentinel file holds the repository root it belongs to, and the hook matches on that content
# rather than on the directory name. An earlier design had both sides derive a slug from the repo,
# which meant two implementations that had to agree forever -- and the skill that recorded a
# delegated check could write into a different directory than the one that was armed, silently.
# Matching on content removes the coupling: the name is an implementation detail nobody depends on.
#
# Arming a repository also arms its linked worktrees. Matching only the exact toplevel meant every
# worktree of an armed repo answered "armed elsewhere" -- while `using-git-worktrees` is this
# toolkit's own recommended way to isolate parallel work, so the gate was absent exactly where the
# work was most deliberate. Counters stay per worktree under wt/<key>: inheriting a gate must not
# mean sharing its attempt count with another piece of work.

set -uo pipefail

GATE_DIR="${DOTAGENTS_GATE_DIR:-$HOME/.claude/.dotagents-gate}"

die() { printf 'gate: %s\n' "$1" >&2; exit 1; }

# >>> dotagents:gate-identity -- byte-identical in scripts/gate.sh and hooks/dotagents-verify-gate.sh.
# Duplicated rather than sourced from a lib: invariant 4 says a hook must not depend on a path that
# can go missing, and a lib under the repo can. scripts/verify-skills.sh asserts the copies match.
#
# Two levels of identity, because they answer different questions.
#   Whether a repository is gated is a property of the *repository*, so it keys on the shared git
#   directory -- which is what makes a linked worktree inherit its main checkout's gate.
#   Attempts and delegated records are properties of a *working tree*, so they key per worktree.
#   Inheriting a gate must not mean sharing its counters.
gate_abs() { # <dir> <rev-parse-flag> -> absolute path, or empty when it cannot be determined
  local d="$1" f="$2" p
  p="$(git -C "$d" rev-parse --path-format=absolute "$f" 2>/dev/null || true)"
  case "$p" in /*) printf '%s' "$p"; return 0 ;; esac
  # git < 2.31 has no --path-format, and a bare --git-common-dir answers relative to the directory it
  # was asked from. Resolve by hand, refusing to guess when anything is empty: `cd ""` succeeds and
  # would silently answer with $HOME.
  p="$(git -C "$d" rev-parse "$f" 2>/dev/null || true)"
  [[ -n "$p" ]] || return 0
  case "$p" in /*) printf '%s' "$p"; return 0 ;; esac
  ( cd "$d" 2>/dev/null && cd "$p" 2>/dev/null && pwd ) || true
}

gate_common_dir() { gate_abs "$1" --git-common-dir; }

# git already maintains a unique name per linked worktree, at <common>/worktrees/<name>. Reusing it
# beats hashing the path: no crypto, no node, and the directory stays readable by a human.
gate_worktree_key() { # <dir> -> a filesystem-safe id unique to this working tree
  local g c
  g="$(gate_abs "$1" --git-dir)"
  c="$(gate_abs "$1" --git-common-dir)"
  if [[ -n "$g" && -n "$c" && "$g" != "$c" ]]; then basename "$g"; else printf 'main'; fi
}
# <<< dotagents:gate-identity

# Absolute repository root, or the directory itself when it is not a repo.
repo_root() {
  local d="${1:-$PWD}"
  [[ -d "$d" ]] || die "not a directory: $d"
  git -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd)
}

# A readable directory name. Only for humans reading ~/.claude/.dotagents-gate; never parsed.
# The branch used to be part of it. It was dropped when worktrees began inheriting the gate: a
# directory called `repo-main` holding the gate for a worktree on another branch is a label that lies.
slug_for() {
  printf '%s' "$(basename "$1")" | tr -cs 'A-Za-z0-9._-' '-' | cut -c1-80
}

# Where a working tree's own counters live. One level down from the sentinel, so a gate inherited by
# several worktrees keeps one set of attempts per tree instead of one shared set for the repository.
state_dir_for() { # <armed-dir> <dir>
  printf '%s/wt/%s' "$1" "$(gate_worktree_key "$2")"
}

# The armed directory for this repository, found by the root recorded inside the sentinel -- or by
# the shared git directory, so a worktree finds the gate its main checkout armed.
find_armed() {
  local root="$1" f armed common armed_common
  common="$(gate_common_dir "$root")"
  shopt -s nullglob
  for f in "$GATE_DIR"/*/ACTIVE; do
    armed="$(cat "$f" 2>/dev/null)"
    [[ -n "$armed" ]] || continue
    [[ "$armed" == "$root" ]] && { dirname "$f"; return 0; }
    # Only when the armed path still resolves. If the repository moved, string equality above is the
    # only claim we are entitled to make.
    if [[ -n "$common" && -d "$armed" ]]; then
      armed_common="$(gate_common_dir "$armed")"
      [[ -n "$armed_common" && "$armed_common" == "$common" ]] && { dirname "$f"; return 0; }
    fi
  done
  return 1
}

# Is there a profile for this repository? Arming one without a profile produces a gate that reports
# "armed" and then passes every turn in silence -- the believing-you-are-protected state that
# docs/decisions.md exists to prevent. Found by arming this repository, which had no profile.
warn_if_no_profile() {
  local root="$1" remote profiles hit
  remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  profiles="$(node -e '
    try { console.log(require(process.env.HOME + "/.claude/.dotagents-managed.json").repo + "/profiles") } catch {}
  ' 2>/dev/null)"
  [[ -n "$profiles" && -d "$profiles" ]] || profiles="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/profiles"

  if [[ -z "$remote" ]]; then
    echo "  warning: no git remote, so no profile can be matched -- the gate will pass silently."
    return
  fi
  hit="$(node -e '
    const fs = require("fs"), path = require("path");
    const [dir, remote] = process.argv.slice(1);
    try {
      for (const f of fs.readdirSync(dir)) {
        if (!f.endsWith(".json") || f.startsWith("_")) continue;
        try {
          const p = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
          if (p?.match?.remote && remote.includes(p.match.remote)) { console.log(f); break; }
        } catch {}
      }
    } catch {}
  ' "$profiles" "$remote" 2>/dev/null)"

  if [[ -n "$hit" ]]; then
    echo "  profile: $hit"
  else
    echo
    echo "  WARNING: no profile matches $remote"
    echo "  The gate is armed but has no commands to run, so it will pass every turn in silence."
    echo "  Write $profiles/<name>.json before relying on this. /da-verify will walk you through it."
  fi
}

cmd_arm() {
  local root; root="$(repo_root "${1:-}")"
  local dir state
  if dir="$(find_armed "$root")"; then
    # Already armed -- possibly by the main checkout of a worktree we are standing in. Do not reset
    # anything, but make sure this working tree has somewhere to keep its own counters.
    state="$(state_dir_for "$dir" "$root")"
    mkdir -p "$state" 2>/dev/null || true
    echo "already armed: $dir"
    warn_if_no_profile "$root"
    return 0
  fi
  # The slug is a label, so two repositories with the same basename can want the same directory.
  # Writing into one that already holds a sentinel would hijack another repository's gate.
  local base n=0
  base="$GATE_DIR/$(slug_for "$root")"
  dir="$base"
  while [[ -e "$dir/ACTIVE" ]]; do
    n=$((n+1))
    dir="$base-$n"
  done
  mkdir -p "$dir" || die "could not create $dir"
  printf '%s' "$root" > "$dir/ACTIVE" || die "could not write the sentinel"
  state="$(state_dir_for "$dir" "$root")"
  mkdir -p "$state" || die "could not create $state"
  printf '{}\n' > "$state/attempts.json"
  : > "$state/delegated.json"
  echo "armed: $dir"
  echo "  the turn will not end while $(basename "$root")'s gating checks fail"
  echo "  worktrees of this repository inherit it, each with its own attempt count"
  warn_if_no_profile "$root"
}

cmd_disarm() {
  local root; root="$(repo_root "${1:-}")"
  local dir
  if ! dir="$(find_armed "$root")"; then
    echo "not armed"
    return 0
  fi
  # Named paths only, never a glob: this runs under $HOME.
  rm -f "$dir/ACTIVE"
  rm -rf "$dir/wt"
  rm -f "$dir/attempts.json" "$dir/delegated.json"   # pre-worktree layout
  rmdir "$dir" 2>/dev/null || true
  echo "disarmed: $dir"
}

cmd_record() {
  local check="${1:-}"
  [[ -n "$check" ]] || die "record needs a check id"
  local root; root="$(repo_root "${2:-}")"
  local dir state
  dir="$(find_armed "$root")" || die "not armed, so there is nothing to record against.
Run 'gate.sh arm' first, or let /da-verify do it."
  # A delegated result is evidence about one working tree, so it is recorded against this one.
  state="$(state_dir_for "$dir" "$root")"
  mkdir -p "$state" || die "could not create $state"
  # Appended as one JSON object per line; the hook greps for the id rather than parsing.
  printf '{"%s": "passed"}\n' "$check" >> "$state/delegated.json"
  echo "recorded: $check"
}

cmd_status() {
  local root; root="$(repo_root "${1:-}")"
  local dir state deleg attempts
  if ! dir="$(find_armed "$root")"; then
    echo "not armed  ($root)"
    return 0
  fi
  state="$(state_dir_for "$dir" "$root")"
  echo "armed      $dir"
  echo "  repo     $root"
  [[ "$(cat "$dir/ACTIVE" 2>/dev/null)" == "$root" ]] \
    || echo "  inherited from $(cat "$dir/ACTIVE" 2>/dev/null)"
  # Pre-worktree layout kept the records beside the sentinel. Read them rather than lose a delegated
  # result across the upgrade: losing one means re-asking a human, which is a worse default than
  # reading a file we wrote ourselves one version ago.
  deleg="$state/delegated.json";     [[ -e "$deleg" ]]    || deleg="$dir/delegated.json"
  attempts="$state/attempts.json";   [[ -e "$attempts" ]] || attempts="$dir/attempts.json"
  if [[ -s "$deleg" ]]; then
    echo "  recorded $(tr '\n' ' ' < "$deleg")"
  else
    echo "  recorded (nothing yet)"
  fi
  if [[ -s "$attempts" ]] && ! grep -qx '{}' "$attempts"; then
    echo "  attempts $(tr -d '\n ' < "$attempts")"
  fi
}

usage() { sed -n '3,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -gt 0 ]] || usage 1
cmd="$1"; shift
case "$cmd" in
  arm)       cmd_arm    "${1:-}" ;;
  disarm)    cmd_disarm "${1:-}" ;;
  record)    cmd_record "${1:-}" "${2:-}" ;;
  status)    cmd_status "${1:-}" ;;
  -h|--help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
