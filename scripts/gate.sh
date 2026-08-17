#!/usr/bin/env bash
# Arm and disarm the verification gate.
#
#   gate.sh arm [dir]            hold this repository's session until its checks pass
#   gate.sh disarm [dir]         release it
#   gate.sh record <check> [dir] note that the user ran a delegated check themselves
#   gate.sh status [dir]         is it armed, how idle, and what has been recorded
#   gate.sh status --json [dir]  the same, for a driver rather than a human
#   gate.sh verify [--json] [dir] run this repository's gating checks now, without ending a turn
#   gate.sh gc                   reclaim gates left armed by sessions that ended
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

# >>> dotagents:gate-shared -- byte-identical in scripts/gate.sh and hooks/dotagents-verify-gate.sh.
# Duplicated rather than sourced from a lib: invariant 4 says a hook must not depend on a path that
# can go missing, and a lib under the repo can. scripts/verify-skills.sh asserts the copies match.
#
# --- identity ---------------------------------------------------------------
# Two levels, because they answer different questions.
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

# Where a working tree's own counters live. One level below the sentinel, so a gate inherited by
# several worktrees keeps one set of attempts per tree instead of one shared set for the repository.
state_dir_for() { # <armed-dir> <dir>
  printf '%s/wt/%s' "$1" "$(gate_worktree_key "$2")"
}

# --- the trace --------------------------------------------------------------
# One line per event, so "nothing happened" can be told apart from "never ran". Capped, because an
# unbounded log under $HOME is the same failure as the unbounded backups.
#
# Shared so that `gate.sh` writes here too, not only the hook. Without it, arm / disarm / record left
# no trace at all -- and the whole reason this file exists is to explain a gate nobody remembers
# arming, which is precisely an arm nobody recorded.
gate_trace() { # <who> <where> <what>
  [[ -d "$GATE_DIR" ]] || return 0
  local trace="$GATE_DIR/trace.log" tmp
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:-?}" "${2:-?}" "${3:-}" >> "$trace" 2>/dev/null || true
  # Trimmed through a temp file and renamed. `tail > f.trim && mv f.trim f` is two steps with a window
  # between them, so two turns ending at once could lose lines -- in the one file that exists to say
  # what happened.
  if [[ "$(wc -l < "$trace" 2>/dev/null || echo 0)" -gt 200 ]]; then
    tmp="$trace.trim.$$"
    tail -100 "$trace" > "$tmp" 2>/dev/null && mv -f "$tmp" "$trace" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  fi
  return 0
}

# --- the clock --------------------------------------------------------------
# Epochs are stored as file *contents*, not as mtimes: `touch -t` arithmetic differs between BSD and
# GNU, and the tests have to move time deterministically. `date +%s` is identical on both.
# DOTAGENTS_GATE_NOW exists for those tests. Nothing else sets it.
gate_now() {
  local n="${DOTAGENTS_GATE_NOW:-}"
  case "$n" in ''|*[!0-9]*) date +%s ;; *) printf '%s' "$n" ;; esac
}

# 12 hours is chosen, not measured. It has to outlast a long unattended run without outlasting a night.
gate_ttl_seconds() {
  local h="${DOTAGENTS_GATE_TTL_HOURS:-12}"
  case "$h" in ''|*[!0-9]*) h=12 ;; esac
  printf '%s' $(( h * 3600 ))
}

# Seconds since this gate last saw a turn end -- idle time, not age. A TTL counted from arming would
# kill the case this exists for: a six-hour unattended run would expire mid-flight and the gate would
# open in silence. Empty when there is no heartbeat to compare against, which callers must NOT read as
# "infinitely idle": that would evict a gate somebody armed a minute ago with an older gate.sh.
gate_idle_seconds() { # <armed-dir>
  local hb now
  hb="$(cat "$1/HEARTBEAT" 2>/dev/null || true)"
  case "$hb" in ''|*[!0-9]*) return 0 ;; esac
  now="$(gate_now)"
  printf '%s' $(( now - hb ))
}

gate_touch_heartbeat() { # <armed-dir>
  local tmp="$1/HEARTBEAT.tmp.$$"
  gate_now > "$tmp" 2>/dev/null && mv -f "$tmp" "$1/HEARTBEAT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# --- verdicts ---------------------------------------------------------------
# A verdict is a file that is *present*, not a state that is absent. If ending a gate only removed
# ACTIVE, the next session's `status` would say "not armed" -- indistinguishable from a session that
# never armed anything, which is the exact lie this is here to prevent.
#
# One field per line, read with `sed -n Np`, the same idiom the hook already uses for its work file.
#   1 timestamp   2 reason   3 check id   4 attempts   5 exit code   6 agent   7 command   8+ output
gate_write_verdict() { # <dir> <reason> <check> <attempts> <exit> <agent> <command> [output]
  local d="$1" tmp="$1/VERDICT.tmp.$$"
  {
    date -u +%Y-%m-%dT%H:%M:%SZ
    printf '%s\n%s\n%s\n%s\n%s\n' "${2:--}" "${3:--}" "${4:-0}" "${5:--}" "${6:--}"
    # Flattened to one line: every field above is addressed by line number, so a command containing a
    # newline would push the output tail into the middle of the record.
    printf '%s' "${7:--}" | tr '\n' ' '
    printf '\n%s\n' "${8:-}"
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$d/VERDICT" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# Beside trace.log, but never trimmed. The trace self-trims at 200 lines by design, so a verdict
# recorded only there would be deleted by ordinary operation.
gate_log_verdict() { # <root> <reason> <detail>
  printf '%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${1:--}" "${2:--}" "${3:-}" \
    >> "$GATE_DIR/verdicts.log" 2>/dev/null || true
  return 0
}

# Reclaim an idle sentinel. ACTIVE goes, so the gate correctly becomes inert. ROOT and VERDICT stay,
# so `status` can still answer whose gate it was and why it ended. Prints the root it reclaimed.
gate_expire() { # <armed-dir> <idle-seconds>
  local d="$1" idle="${2:-0}" root ttl
  root="$(cat "$d/ROOT" 2>/dev/null || true)"
  [[ -n "$root" ]] || root="$(cat "$d/ACTIVE" 2>/dev/null || true)"
  ttl="$(gate_ttl_seconds)"
  [[ -n "$root" ]] && printf '%s' "$root" > "$d/ROOT" 2>/dev/null
  gate_write_verdict "$d" expired - 0 - - - \
"Reclaimed after $(( idle / 3600 ))h idle (ttl $(( ttl / 3600 ))h). The session that armed this gate
ended without disarming it. Nothing was checked by this verdict -- it records only that the gate
stopped holding, not that the work was verified."
  rm -f "$d/ACTIVE"
  printf '%s' "$root"
}
# <<< dotagents:gate-shared

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

# The directory holding a given marker for this repository, found by the root recorded inside it --
# or by the shared git directory, so a worktree finds the gate its main checkout armed.
#
# ACTIVE answers "is it armed". ROOT answers "whose was this" and outlives eviction, which is the
# only reason `status` can tell an expired gate apart from a session that never armed anything.
find_marked() { # <marker-filename> <root>
  local marker="$1" root="$2" f armed common armed_common
  common="$(gate_common_dir "$root")"
  shopt -s nullglob
  for f in "$GATE_DIR"/*/"$marker"; do
    armed="$(cat "$f" 2>/dev/null)"
    [[ -n "$armed" ]] || continue
    [[ "$armed" == "$root" ]] && { dirname "$f"; return 0; }
    # Only when the recorded path still resolves. If the repository moved, string equality above is
    # the only claim we are entitled to make.
    if [[ -n "$common" && -d "$armed" ]]; then
      armed_common="$(gate_common_dir "$armed")"
      [[ -n "$armed_common" && "$armed_common" == "$common" ]] && { dirname "$f"; return 0; }
    fi
  done
  return 1
}

find_armed() { find_marked ACTIVE "$1"; }
find_ended() { find_marked ROOT   "$1"; }

# How long a gate has been idle, in whole hours, for humans.
idle_hours() { # <armed-dir>
  local s; s="$(gate_idle_seconds "$1")"
  [[ -n "$s" ]] || { printf 'unknown'; return; }
  printf '%sh' $(( s / 3600 ))
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
          // String or list of strings, any of which matches. Kept identical to the copy in
          // hooks/dotagents-verify-gate.sh.
          const pats = p?.match?.remote == null ? [] : [].concat(p.match.remote);
          if (pats.some((s) => typeof s === "string" && s !== "" && remote.includes(s))) { console.log(f); break; }
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

# Surface a verdict left behind by whoever was here before, and move it aside so the gate can hold
# again. Returns 0 when there was one, so the caller knows to reset the budget with it.
report_prior_verdict() { # <dir holding VERDICT>
  local d="$1"
  [[ -f "$d/VERDICT" ]] || return 1
  mv -f "$d/VERDICT" "$d/VERDICT.prev" 2>/dev/null || return 1
  echo
  echo "  NOTE: the gate here ended with a verdict rather than being disarmed:"
  printf '    reason  %s\n' "$(sed -n 2p "$d/VERDICT.prev" 2>/dev/null)"
  printf '    check   %s\n' "$(sed -n 3p "$d/VERDICT.prev" 2>/dev/null)"
  printf '    at      %s after %s attempt(s)\n' \
    "$(sed -n 1p "$d/VERDICT.prev" 2>/dev/null)" "$(sed -n 4p "$d/VERDICT.prev" 2>/dev/null)"
  echo "  That work was NOT verified. Read $d/VERDICT.prev before treating it as done."
  echo "  The attempt budget restarts now."
  return 0
}

cmd_arm() {
  local root; root="$(repo_root "${1:-}")"
  local dir state
  if dir="$(find_armed "$root")"; then
    # Already armed -- possibly by the main checkout of a worktree we are standing in. Do not reset
    # anything, but make sure this working tree has somewhere to keep its own counters.
    state="$(state_dir_for "$dir" "$root")"
    mkdir -p "$state" 2>/dev/null || true
    gate_trace "gate.sh" "$root" "arm requested; already armed"
    echo "already armed: $dir"
    # Re-arming is the one code path a new session is guaranteed to reach, via /da-verify. So it is
    # where a verdict left by the previous session has to surface -- and where the budget restarts,
    # since a gate that gave up would otherwise never hold again however many times it was re-armed.
    report_prior_verdict "$state" && printf '{}\n' > "$state/attempts.json"
    warn_if_no_profile "$root"
    return 0
  fi
  # The slug is a label, so two repositories with the same basename can want the same directory.
  # Writing into one that already holds a sentinel would hijack another repository's gate.
  local base n=0
  base="$GATE_DIR/$(slug_for "$root")"
  dir="$base"
  # Reuse our own expired directory -- that is how a prior verdict gets echoed below -- but never one
  # that is armed, and never one whose ROOT names a different repository.
  while [[ -e "$dir/ACTIVE" ]] \
     || { [[ -e "$dir/ROOT" ]] && [[ "$(cat "$dir/ROOT" 2>/dev/null)" != "$root" ]]; }; do
    n=$((n+1))
    dir="$base-$n"
  done
  mkdir -p "$dir" || die "could not create $dir"
  printf '%s' "$root" > "$dir/ACTIVE" || die "could not write the sentinel"
  # ROOT is the same content, and is never removed. It is what lets `status` and `gc` report on a gate
  # that is no longer armed, instead of falling back to a bare "not armed".
  printf '%s' "$root" > "$dir/ROOT"
  gate_now > "$dir/ARMED_AT"
  gate_touch_heartbeat "$dir"
  state="$(state_dir_for "$dir" "$root")"
  mkdir -p "$state" || die "could not create $state"
  printf '{}\n' > "$state/attempts.json"
  : > "$state/delegated.json"
  gate_trace "gate.sh" "$root" "armed"
  echo "armed: $dir"
  echo "  the turn will not end while $(basename "$root")'s gating checks fail"
  echo "  worktrees of this repository inherit it, each with its own attempt count"
  echo "  reclaimed automatically after $(( $(gate_ttl_seconds) / 3600 ))h with no turn ending here"
  # Two places a verdict can be waiting: beside the sentinel if this gate was reclaimed for idleness,
  # and beside this tree's counters if it gave up. Both mean the same thing to whoever is re-arming.
  report_prior_verdict "$dir"   || true
  report_prior_verdict "$state" || true
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
  # A deliberate disarm is a clean end, so it leaves no verdict behind -- unlike eviction, which has
  # to explain itself. That is the difference the three-state design exists to express.
  rm -f "$dir/ACTIVE" "$dir/ROOT" "$dir/ARMED_AT" "$dir/HEARTBEAT" "$dir/VERDICT" "$dir/VERDICT.prev"
  rm -rf "$dir/wt"
  rm -f "$dir/attempts.json" "$dir/delegated.json"   # pre-worktree layout
  rmdir "$dir" 2>/dev/null || true
  gate_trace "gate.sh" "$root" "disarmed deliberately"
  echo "disarmed: $dir"
}

# Reclaim every idle gate now, rather than waiting for some other repository's turn to end. For a
# driver or a CI step that wants the sweep on demand. Prints what it reclaimed -- a sweep that says
# nothing is indistinguishable from a sweep that found nothing.
cmd_gc() {
  local f dir idle root ttl found=0
  ttl="$(gate_ttl_seconds)"
  shopt -s nullglob
  for f in "$GATE_DIR"/*/ACTIVE; do
    dir="$(dirname "$f")"
    idle="$(gate_idle_seconds "$dir")"
    if [[ -z "$idle" ]]; then
      # Armed by a version that kept no heartbeat. Start its clock rather than treat it as ancient.
      gate_touch_heartbeat "$dir"
      echo "clock started: $(cat "$f" 2>/dev/null) (no heartbeat recorded until now)"
      found=1
      continue
    fi
    if (( idle > ttl )); then
      root="$(gate_expire "$dir" "$idle")"
      gate_log_verdict "${root:-$dir}" expired "idle $(( idle / 3600 ))h, reclaimed by gc"
      echo "reclaimed: ${root:-$dir} (idle $(( idle / 3600 ))h, ttl $(( ttl / 3600 ))h)"
      found=1
    fi
  done
  (( found )) || echo "nothing to reclaim (no gate idle beyond $(( ttl / 3600 ))h)"
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
  gate_trace "gate.sh" "$root" "recorded delegated check: $check"
  echo "recorded: $check"
}

# The one machine-readable surface. A driver that had to parse the prose above would break the first
# time a sentence was reworded, and new exit codes would mean litigating what each one means -- so this
# is JSON, built by node so the escaping is not ours to get wrong. Read-only, like `status` itself.
cmd_status_json() {
  local root dir state ended
  root="$(repo_root "${1:-}")"
  dir="$(find_armed "$root" || true)"
  ended=""
  [[ -n "$dir" ]] || ended="$(find_ended "$root" || true)"
  state=""
  [[ -n "$dir" ]] && state="$(state_dir_for "$dir" "$root")"
  node -e '
    const fs = require("fs");
    const [root, dir, state, ended, idle, ttl] = process.argv.slice(1);
    const read = (p) => { try { return fs.readFileSync(p, "utf8") } catch { return "" } };
    const verdict = (p) => {
      const raw = read(p);
      if (!raw) return null;
      const l = raw.split("\n");
      return { at: l[0] ?? "", reason: l[1] ?? "", check: l[2] ?? "", attempts: Number(l[3]) || 0,
               exit: l[4] ?? "", agent: l[5] ?? "", command: l[6] ?? "" };
    };
    let attempts = {};
    try { attempts = JSON.parse(read(state + "/attempts.json") || "{}") } catch {}
    const recorded = read(state + "/delegated.json").split("\n").filter(Boolean)
      .map((l) => { try { return Object.keys(JSON.parse(l))[0] } catch { return null } }).filter(Boolean);
    const gaveUp = verdict(state + "/VERDICT");
    process.stdout.write(JSON.stringify({
      repo: root,
      armed: Boolean(dir),
      dir: dir || null,
      state_dir: state || null,
      idle_seconds: idle === "" ? null : Number(idle),
      ttl_seconds: Number(ttl),
      gave_up: Boolean(gaveUp),
      verdict: gaveUp || verdict(ended + "/VERDICT"),
      attempts,
      recorded,
    }, null, 2) + "\n");
  ' "$root" "$dir" "$state" "$ended" "$( [[ -n "$dir" ]] && gate_idle_seconds "$dir" )" "$(gate_ttl_seconds)"
}

cmd_status() {
  if [[ "${1:-}" == "--json" ]]; then cmd_status_json "${2:-}"; return 0; fi
  local root; root="$(repo_root "${1:-}")"
  local dir state deleg attempts ended
  if ! dir="$(find_armed "$root")"; then
    # Nothing armed. But "not armed" alone cannot be the whole answer: it reads identically whether
    # this session never armed anything or a gate was reclaimed out from under an abandoned one.
    # Reporting only, never evicting -- reading state must not be what opens a gate.
    if ended="$(find_ended "$root")" && [[ -f "$ended/VERDICT" ]]; then
      echo "not armed  ($root)"
      echo "  ended    $(sed -n 2p "$ended/VERDICT" 2>/dev/null) at $(sed -n 1p "$ended/VERDICT" 2>/dev/null)"
      [[ "$(sed -n 3p "$ended/VERDICT" 2>/dev/null)" == "-" ]] \
        || echo "  check    $(sed -n 3p "$ended/VERDICT" 2>/dev/null)"
      echo "  verdict  $ended/VERDICT"
      echo "  The work this gate was holding was NOT verified. Read the verdict before calling it done."
    else
      echo "not armed  ($root)"
    fi
    return 0
  fi
  state="$(state_dir_for "$dir" "$root")"
  echo "armed      $dir"
  echo "  repo     $root"
  echo "  idle     $(idle_hours "$dir") (reclaimed past $(( $(gate_ttl_seconds) / 3600 ))h)"
  if [[ -f "$dir/VERDICT" ]]; then
    echo "  GAVE UP  $(sed -n 2p "$dir/VERDICT" 2>/dev/null) on $(sed -n 3p "$dir/VERDICT" 2>/dev/null) after $(sed -n 4p "$dir/VERDICT" 2>/dev/null) attempts"
    echo "           this gate no longer blocks; see $dir/VERDICT"
  fi
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

# Matched, not addressed by line number: adding a subcommand to the header above used to silently
# push one out of the range and `gate.sh -h` stopped listing it.
# Run the repository's gating checks now. Drives the Stop hook rather than reimplementing its loop:
# there is one implementation of "what this repository checks and how", and no second copy to drift.
#
# That mattered. da-verify/SKILL.md described the loop in prose and had already diverged -- it told the
# model to use `git diff --name-only HEAD` while the hook also includes untracked files, deliberately,
# because a turn that only adds new files produced an empty list and skipped the check entirely. The
# skill would have skipped a check the gate runs.
#
# DOTAGENTS_GATE_DRY makes the hook resolve the profile, run the checks, report, and touch nothing:
# no attempt counted, no verdict written, no heartbeat refreshed, and no sentinel required. Checking
# your own work has to be free, or the attempt budget would depend on how often you looked.
cmd_verify() {
  local as_json=0
  [[ "${1:-}" == "--json" ]] && { as_json=1; shift; }
  local root; root="$(repo_root "${1:-}")"

  # The copy in this repository, not the installed one. gate.sh ships with the repository and its job
  # is to run these checks with this repository's logic; the installed copy can be older, and
  # `setup.sh doctor` is what reports that gap. Preferring the installed copy meant `verify` silently
  # exercised a version that predated the feature being tested -- which is how I found this.
  local hook; hook="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/hooks/dotagents-verify-gate.sh"
  [[ -f "$hook" ]] || die "cannot find hooks/dotagents-verify-gate.sh next to this script"

  local out err report rc=0
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-verify.XXXXXX")" || die "mktemp failed"
  err="$(mktemp "${TMPDIR:-/tmp}/dotagents-verify.XXXXXX")" || die "mktemp failed"
  report="$(mktemp "${TMPDIR:-/tmp}/dotagents-verify.XXXXXX")" || die "mktemp failed"
  # shellcheck disable=SC2064
  trap "rm -f '$out' '$err' '$report'" EXIT

  # DOTAGENTS_GATE_REPORT asks the hook for a machine-readable record of what it did. Only `verify`
  # sets it, so a turn-end run is byte-for-byte what it was.
  printf '{"cwd":"%s","hook_event_name":"Stop"}' "$root" \
    | DOTAGENTS_GATE_DRY=1 DOTAGENTS_GATE_REPORT="$report" bash "$hook" >"$out" 2>"$err" || rc=$?

  if (( as_json )); then
    node -e '
      const fs = require("fs");
      const [outP, errP, rc, root, reportP] = process.argv.slice(1);
      const read = (p) => { try { return fs.readFileSync(p, "utf8") } catch { return "" } };
      const detail = (read(outP) + read(errP)).trim();
      // The hook prints "gate: <check id>" on the first line of a failure report.
      const m = detail.match(/^gate:\s*(\S+)/m);
      const id = m && m[1] !== "all" && m[1] !== "nothing" ? m[1] : null;
      const kind = (detail.match(/^\s*kind\s*:\s*(\S+)/m) || [])[1] ?? null;

      // The sidecar carries the facts this document used to leave to prose. FAIL CLOSED when it is
      // missing or unreadable: `checked: null` and `ok: false`, never "assume it ran". An absent
      // answer is "I could not tell", which is the fail-open this repository keeps naming. There is
      // no version-skew case to be gentle about -- `verify` deliberately runs the IN-REPO hook.
      let rep = null;
      try { rep = JSON.parse(read(reportP)) } catch {}
      const sane = rep && typeof rep === "object" && Number.isInteger(rep.ran);
      let ok = rc === "0";
      if (!sane) ok = false;

      process.stdout.write(JSON.stringify({
        repo: root, ok, exit: Number(rc), check: id, kind, detail,
        profile: sane ? (rep.profile ?? null) : null,
        ran: sane ? rep.ran : null,
        checked: sane ? rep.ran > 0 : null,
        skipped: sane ? (rep.skipped ?? []) : null,
      }, null, 2) + "\n");
    ' "$out" "$err" "$rc" "$root" "$report"
  else
    cat "$out"
    cat "$err" >&2
  fi
  return "$rc"
}

usage() { grep -E '^#   gate\.sh ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -gt 0 ]] || usage 1
cmd="$1"; shift
case "$cmd" in
  arm)       cmd_arm    "${1:-}" ;;
  disarm)    cmd_disarm "${1:-}" ;;
  record)    cmd_record "${1:-}" "${2:-}" ;;
  status)    cmd_status "${1:-}" "${2:-}" ;;
  gc)        cmd_gc ;;
  verify)    cmd_verify "${1:-}" "${2:-}" ;;
  -h|--help) usage ;;
  *) die "unknown command: $cmd" ;;
esac
