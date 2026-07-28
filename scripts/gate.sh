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

set -uo pipefail

GATE_DIR="${DOTAGENTS_GATE_DIR:-$HOME/.claude/.dotagents-gate}"

die() { printf 'gate: %s\n' "$1" >&2; exit 1; }

# Absolute repository root, or the directory itself when it is not a repo.
repo_root() {
  local d="${1:-$PWD}"
  [[ -d "$d" ]] || die "not a directory: $d"
  git -C "$d" rev-parse --show-toplevel 2>/dev/null || (cd "$d" && pwd)
}

# A readable directory name. Only for humans reading ~/.claude/.dotagents-gate; never parsed.
slug_for() {
  local root="$1" branch
  branch="$(git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
  printf '%s' "$(basename "$root")-${branch}" | tr -cs 'A-Za-z0-9._-' '-' | cut -c1-80
}

# The armed directory for this repository, found by the root recorded inside the sentinel.
find_armed() {
  local root="$1" f
  shopt -s nullglob
  for f in "$GATE_DIR"/*/ACTIVE; do
    [[ "$(cat "$f" 2>/dev/null)" == "$root" ]] && { dirname "$f"; return 0; }
  done
  return 1
}

cmd_arm() {
  local root; root="$(repo_root "${1:-}")"
  local dir
  if dir="$(find_armed "$root")"; then
    echo "already armed: $dir"
    return 0
  fi
  dir="$GATE_DIR/$(slug_for "$root")"
  mkdir -p "$dir" || die "could not create $dir"
  printf '%s' "$root" > "$dir/ACTIVE" || die "could not write the sentinel"
  printf '{}\n' > "$dir/attempts.json"
  : > "$dir/delegated.json"
  echo "armed: $dir"
  echo "  the turn will not end while $(basename "$root")'s gating checks fail"
}

cmd_disarm() {
  local root; root="$(repo_root "${1:-}")"
  local dir
  if ! dir="$(find_armed "$root")"; then
    echo "not armed"
    return 0
  fi
  rm -f "$dir/ACTIVE" "$dir/attempts.json" "$dir/delegated.json"
  rmdir "$dir" 2>/dev/null || true
  echo "disarmed: $dir"
}

cmd_record() {
  local check="${1:-}"
  [[ -n "$check" ]] || die "record needs a check id"
  local root; root="$(repo_root "${2:-}")"
  local dir
  dir="$(find_armed "$root")" || die "not armed, so there is nothing to record against.
Run 'gate.sh arm' first, or let /verify do it."
  # Appended as one JSON object per line; the hook greps for the id rather than parsing.
  printf '{"%s": "passed"}\n' "$check" >> "$dir/delegated.json"
  echo "recorded: $check"
}

cmd_status() {
  local root; root="$(repo_root "${1:-}")"
  local dir
  if ! dir="$(find_armed "$root")"; then
    echo "not armed  ($root)"
    return 0
  fi
  echo "armed      $dir"
  echo "  repo     $root"
  if [[ -s "$dir/delegated.json" ]]; then
    echo "  recorded $(tr '\n' ' ' < "$dir/delegated.json")"
  else
    echo "  recorded (nothing yet)"
  fi
  if [[ -s "$dir/attempts.json" ]] && ! grep -qx '{}' "$dir/attempts.json"; then
    echo "  attempts $(tr -d '\n ' < "$dir/attempts.json")"
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
