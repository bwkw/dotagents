#!/usr/bin/env bash
# Stop hook. Refuses to let a turn end while the repository's own verification is failing.
#
# The problem it solves: an agent stops when the work *looks* done. Without a check it can run,
# "looks done" is the only signal, and the human becomes the verification loop.
#
# Sentinel-gated. It does nothing unless a skill armed it by creating
#   ~/.claude/.dotagents-gate/<slug>/ACTIVE
# An always-on Stop hook would run the test suite at the end of every question-answering session,
# which is unusable, so it would get disabled, which is worse than not having it.
#
# Runs on both agents, with different enforcement strength:
#
#   Claude Code  Stop hook.   exit 2 BLOCKS the turn; stderr goes to the agent. Nothing else blocks --
#                             exit 1 is a non-blocking error and the turn ends. See docs/harness-facts.md.
#   Cursor       stop hook.   Cannot block. Printing {"followup_message": "..."} auto-submits a
#                             message so the agent keeps working. Bounded by Cursor's loop_limit
#                             (default 5), so it cannot spin forever.
#
# The Cursor path is genuinely weaker — an agent can still be stopped by the user with checks red.
# It is not presented as parity anywhere.

set -uo pipefail

# Every decision below goes through node. If it is absent -- a GUI-launched agent whose PATH lacks
# a version-manager shim, most commonly -- the gate must say so rather than wave the turn through.
# Checked before anything else so the message is about the real cause.
GATE_NODE_MISSING=0
command -v node >/dev/null 2>&1 || GATE_NODE_MISSING=1

# Set by `gate.sh verify`, never by an agent harness. In dry mode the hook resolves the profile and
# runs the checks exactly as it would at a turn end, and then touches nothing: no attempt counted, no
# verdict, no heartbeat, no arming required. That is what makes self-checking free -- a check that
# spent the budget would make the budget depend on how often you looked at your own work.
GATE_DRY="${DOTAGENTS_GATE_DRY:-0}"
[[ "$GATE_DRY" == "1" ]] || GATE_DRY=0

GATE_DIR="${DOTAGENTS_GATE_DIR:-$HOME/.claude/.dotagents-gate}"
TRACE="$GATE_DIR/trace.log"

# Defined in the shared block below, so gate.sh records arm / disarm / record in the same log.
trace() { gate_trace "$@"; }

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

# Installed copies live in ~/.claude/hooks, away from the repo, so the manifest records where the
# repo is. DOTAGENTS_PROFILES overrides both, which is how the test suite stays hermetic.
PROFILES="${DOTAGENTS_PROFILES:-}"
if [[ -z "$PROFILES" ]]; then
  PROFILES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../profiles"
  if [[ ! -d "$PROFILES" ]]; then
    PROFILES="$(node -e '
      try { console.log(require(process.env.HOME+"/.claude/.dotagents-managed.json").repo + "/profiles") } catch {}
    ' 2>/dev/null)"
  fi
fi

# ---------------------------------------------------------------- no gate armed, nothing to do

shopt -s nullglob
active=("$GATE_DIR"/*/ACTIVE)
if (( ${#active[@]} == 0 )) && (( GATE_DRY )); then
  # Nothing armed, but a dry run is not asking whether the gate holds -- it is asking whether the
  # checks pass. Carry on with an empty sentinel list.
  :
elif (( ${#active[@]} == 0 )); then
  trace "?" "$PWD" "invoked; nothing armed; passed"
  exit 0
fi

# Something is armed. From here on the gate owes an answer, and every step that could produce one
# goes through node -- including working out which repository the payload refers to. Checked here
# rather than later because without node the hook cannot tell whether the armed sentinel belongs to
# this repository, so "armed, but not ours, carry on" is not a conclusion it is entitled to draw.
if [[ "$GATE_NODE_MISSING" == "1" ]]; then
  {
    echo "[dotagents] The verification gate needs node and cannot find it on PATH, so it cannot"
    echo "check anything."
    echo
    echo "A gate is armed, but without node this hook cannot even determine which repository it"
    echo "belongs to. This is a fault in the gate's environment, not in your work: fix PATH for the"
    echo "agent, or disarm the gate. Do not treat this as a pass."
  } >&2
  exit 2
fi

# Read the payload through an explicit descriptor, never bare stdin.
#
# With fd 0 *closed* -- not empty, closed, which is what a caller that has already exited leaves
# behind -- bash assigns the lowest free descriptor when it builds the pipe for a command
# substitution. That is fd 0. So `payload="$(cat)"` had `cat` reading the read end of its own output
# pipe, and it blocked forever. The harness then killed the hook on its timeout, and a killed hook
# exits with neither 0 nor 2: non-blocking. The gate failed open because stdin was missing.
#
# Duplicating fd 0 to fd 3 first fixes it two ways: the duplication fails loudly when there is no
# stdin, and nothing afterwards can be handed fd 0 by accident.
# The probe runs in a subshell. `exec` with a redirection and no command applies that redirection to
# the shell permanently -- so `exec 3<&0 2>/dev/null` silently sent every later stderr write to
# /dev/null, and the block message stopped reaching the model at all. A worse fail-open than the one
# being fixed, and the suite caught it on the next run.
if ( exec 3<&0 ) 2>/dev/null; then
  exec 3<&0
else
  trace "?" "$PWD" "no readable stdin; treating the payload as empty"
  exec 3</dev/null
fi
# Something is armed, so from here an unexpected failure must not read as permission to stop.
#
# Only exit 2 blocks. The documentation is explicit that exit 1 is a *non-blocking* error and Claude
# Code proceeds, so a crash here would end the turn with nothing checked and nothing said. This script
# runs under `set -u`, which makes one unbound variable enough -- and that class already bit this repo
# once, when a cwd containing a space made an arithmetic comparison exit 127. A trap makes it structural
# instead of a bug fixed one occurrence at a time.
#
# Installed before the payload is even parsed, because "armed, but perhaps not for this repository" is
# not a conclusion the hook is entitled to draw while it is malfunctioning -- the same reasoning the
# node-missing block above already uses.
agent="claude"
cwd="$PWD"
slug_dir=""
_gate_work=""
gate_on_exit() {
  local code=$?
  [[ -n "$_gate_work" ]] && rm -f "$_gate_work" "$_gate_work.fail" "$_gate_work.out" "$_gate_work.timeout"
  # Cursor cannot be blocked, so converting there would buy nothing and would put noise on a stream it
  # does not read.
  if [[ "$code" != "0" && "$code" != "2" && "$agent" != "cursor" ]]; then
    trace "$agent" "$cwd" "CRASHED with status $code; converted to a block"
    {
      echo "[dotagents] The verification gate exited unexpectedly (status $code), so it does not know"
      echo "whether this repository's checks pass."
      echo
      echo "This is a fault in the gate, not in your work -- but only exit 2 blocks, and any other"
      echo "status would have ended the turn with nothing checked. Report that the gate failed rather"
      echo "than treating it as a pass${slug_dir:+, or disarm the gate at $slug_dir}."
    } >&2
    exit 2
  fi
}
trap gate_on_exit EXIT

payload="$(cat <&3)"
exec 3<&-

# Tell the two agents apart by their payload. Cursor's stop hook sends {status, loop_count} and no
# cwd; Claude Code's sends cwd and hook_event_name.
# One field per line, not space-separated: a cwd containing a space would otherwise land in
# loop_count, and `[[ "project 0" -ge 3 ]]` exits 127 under set -u -- a non-blocking exit, so the
# gate would open on a path like ~/my project.
_fields="$(printf '%s' "$payload" | node -e '
  let s = ""; process.stdin.on("data", d => (s += d)).on("end", () => {
    let p = {}; try { p = JSON.parse(s) } catch {}
    const cursor = "loop_count" in p || ("status" in p && !("cwd" in p));
    const n = Number(p.loop_count);
    // A subagent completing is not the end of the turn. Claude Code converts a registered Stop hook
    // into SubagentStop for subagents, so this hook fires there too; agent_id is present in that case
    // even when the event name is not. No apostrophes in here -- this whole script is inside a
    // single-quoted shell argument, and one would close it and spill script text into the output.
    const sub = p.hook_event_name === "SubagentStop" || "agent_id" in p ? "1" : "0";
    process.stdout.write([
      cursor ? "cursor" : "claude",
      p.cwd || "-",
      Number.isFinite(n) ? String(Math.trunc(n)) : "0",
      p.stop_hook_active ? "1" : "0",
      sub,
      String(p.agent_type || "-"),
    ].join("\n") + "\n");
  });
' 2>/dev/null)"

agent="$(sed -n 1p <<<"$_fields")"
cwd="$(sed -n 2p <<<"$_fields")"
loop_count="$(sed -n 3p <<<"$_fields")"
stop_active="$(sed -n 4p <<<"$_fields")"
is_subagent="$(sed -n 5p <<<"$_fields")"
agent_type="$(sed -n 6p <<<"$_fields")"
[[ "$is_subagent" == "1" ]] || is_subagent=0
[[ -n "$agent_type" ]] || agent_type="-"

# Defaults, and a numeric guarantee for loop_count so the arithmetic below cannot explode.
[[ -n "$agent" ]] || agent="claude"
[[ "$loop_count" =~ ^[0-9]+$ ]] || loop_count=0
[[ "$stop_active" == "1" ]] || stop_active=0

# Cursor's stop payload carries no cwd, and this hook's process cwd there is ~/.cursor -- not the
# workspace. Falling back to $PWD therefore compared the wrong repository and passed every turn,
# silently. Observed in the trace: "cursor /Users/shota/.cursor passed: armed elsewhere".
cwd_known=1
if [[ "$cwd" == "-" || -z "$cwd" ]]; then
  cwd_known=0
  cwd="$PWD"
fi

# Emit a block, in whichever dialect this agent speaks, then exit.
# $1 = message
# $2 = what is red, for the trace. Passed explicitly rather than read from a global because block()
#      is reached from several places, and the earliest of them run before any check has an id.
# Cursor cannot be blocked; a stop hook there answers with a message that is auto-submitted as the
# next user turn. Shared by block() and the terminal give-up, so both speak the same dialect and both
# respect Cursor's own loop budget.
emit_cursor_followup() { # $1 = message, $2 = what is red (for the trace)
  if [[ "$loop_count" -ge 3 ]]; then
    trace "$agent" "$cwd" "gave up injecting at loop_count=$loop_count while ${2:-the gate} red"
    printf '%s' '{}'
    exit 0
  fi
  trace "$agent" "$cwd" "injected a follow-up while ${2:-the gate} red (cannot block in Cursor)"
  # followup_message is auto-submitted *as a user message*, so without attribution the agent
  # cannot tell this from the human typing it -- and may then treat a hook's demand as the
  # user's stated intent, or attribute the interruption to them. Say what it is.
  {
    echo "[dotagents] Automated message from the verification gate. The user did not write this,"
    echo "and did not ask you to stop -- a hook did, because a check is failing."
    echo
    printf '%s\n' "$1"
  } | node -e '
    let s = ""; process.stdin.on("data", d => (s += d)).on("end", () => {
      process.stdout.write(JSON.stringify({ followup_message: s.trimEnd() }));
    });
  '
  exit 0
}

block() {
  local _what="${2:-the gate}"
  if [[ "$agent" == "cursor" ]]; then
    # Stop injecting before the loop_limit so the budget is not silently exhausted by us.
    emit_cursor_followup "$1" "$_what"
  fi
  # Claude Code re-invokes this hook after a block, and the agent cannot reach the user without
  # ending a turn. Blocking indefinitely would trap it: the instruction "ask the user" is
  # unreachable from inside a blocked turn. So on a re-entry, hand control back once, loudly.
  if [[ "$stop_active" == "1" ]]; then
    # Traced, because this -- not the block -- is what decides whether a red turn ends. A trace that
    # records only blocks is silent about the gate's most frequent and most consequential event, so
    # "nothing happened" could not be told apart from "never ran" in the one file built to tell them
    # apart. On Claude Code the harness's own 8-consecutive-block release is never reached: this
    # releases at the first re-entry, so every turn cycle blocks exactly once.
    trace "$agent" "$cwd" "RELEASED while $_what red -- handed control back with checks failing"
    {
      printf '[dotagents] %s\n' "$1"
      echo
      echo "Releasing the gate for this turn so you can reach the user -- the checks above are"
      echo "still failing. The sentinel stays armed; say plainly what is red and what you need."
      echo "This is a hook speaking, not the user."
    } >&2
    exit 0
  fi
  trace "$agent" "$cwd" "BLOCKED ($_what)"
  printf '[dotagents] %s\n' "$1" >&2
  exit 2
}

# Let the turn end.
pass() {
  trace "$agent" "$cwd" "passed${1:+: $1}"
  if (( GATE_DRY )); then
    # Said out loud, because "green" and "there was nothing to check" are different answers and only
    # one of them means the work is verified.
    printf 'gate: nothing blocking%s\n' "${1:+ -- $1}"
    exit 0
  fi
  [[ "$agent" == "cursor" ]] && printf '%s' '{}'
  exit 0
}

# Each sentinel records the repository root it belongs to. Match on that, not on position:
# with two repositories armed, active[0] would check one and report against the other.
#
# The sentinel's contents are unchanged. What changed is the comparison: a linked worktree's toplevel
# is its own path, so exact matching answered "armed elsewhere" for every worktree of an armed repo --
# while `using-git-worktrees` is this toolkit's own recommended way to isolate parallel work. Falling
# back to the shared git directory makes the worktree inherit the gate. Over-coverage is loud and
# `disarm` fixes it; under-coverage was silent.
gate_repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
gate_common="$(gate_common_dir "$cwd")"
slug_dir=""
for _sentinel in ${active[@]+"${active[@]}"}; do
  _armed="$(cat "$_sentinel" 2>/dev/null)"
  [[ -n "$_armed" ]] || continue
  if [[ "$_armed" == "$gate_repo_root" ]]; then
    slug_dir="$(dirname "$_sentinel")"
    break
  fi
  # Only while the armed path still resolves. If the repository moved, the exact match above is the
  # only claim this hook is entitled to make -- and claiming a gate that is not ours would report
  # against the wrong repository, which is the failure the content-matching design removed once.
  if [[ -n "$gate_common" && -d "$_armed" ]]; then
    _armed_common="$(gate_common_dir "$_armed")"
    if [[ -n "$_armed_common" && "$_armed_common" == "$gate_common" ]]; then
      slug_dir="$(dirname "$_sentinel")"
      break
    fi
  fi
done

# The agent gave no working directory and nothing matched. With exactly one sentinel armed there is
# only one repository it could be about, so take that and record the inference. This is what makes
# the gate work at all in Cursor.
if [[ -z "$slug_dir" && "$cwd_known" == "0" && ${#active[@]} -eq 1 ]]; then
  slug_dir="$(dirname "${active[0]}")"
  gate_repo_root="$(cat "${active[0]}" 2>/dev/null)"
  cwd="$gate_repo_root"
  trace "$agent" "$cwd" "inferred the repository from the only armed sentinel"
fi

# Several armed and nothing to disambiguate with. Guessing would check one repository and report
# against another, so say what happened rather than let it look like a pass.
if [[ -z "$slug_dir" && "$cwd_known" == "0" && ${#active[@]} -gt 1 ]]; then
  block "The verification gate could not tell which repository this turn was about.

This agent reports no working directory, and ${#active[@]} repositories are armed. Disarm the ones
you are not working in with 'scripts/gate.sh disarm' so there is a single answer. Nothing was
checked -- do not treat this as a pass."
fi

# ---------------------------------------------------------------- reclaim idle sentinels
# The sweeper is the glob above, which every turn end in every repository already walks. It runs
# several times a minute across all sessions, so it costs nothing -- and a launchd job whose purpose
# was to un-arm guardrails would be a fail-open machine running when nobody is watching.
#
# The rule that makes expiry structurally unable to fail open:
#
#   an invocation may evict a sentinel only if that sentinel is NOT the one it is about to enforce.
#
# So the only invocation that can expire gate G is one that was never protecting G, and no single
# invocation can both expire a gate and pass on the basis of that expiry. Placed after the match and
# after the Cursor inference: if the one armed sentinel is stale and we inferred it, enforcing it is
# the fail-closed answer, and the heartbeat refresh below keeps it.
_ttl="$(gate_ttl_seconds)"
for _sentinel in ${active[@]+"${active[@]}"}; do
  _d="$(dirname "$_sentinel")"
  [[ -n "$slug_dir" && "$_d" == "$slug_dir" ]] && continue
  _idle="$(gate_idle_seconds "$_d")"
  if [[ -z "$_idle" ]]; then
    # Armed by a version that kept no heartbeat. Start its clock instead of reading the absence as
    # infinite idleness, which would evict a gate somebody armed a minute ago. The upgrade migrates
    # itself; there is no command for anyone to remember to run.
    gate_touch_heartbeat "$_d"
    continue
  fi
  if (( _idle > _ttl )); then
    _root="$(gate_expire "$_d" "$_idle")"
    trace "$agent" "$cwd" "expired ${_root:-$_d} (idle $(( _idle / 3600 ))h, ttl $(( _ttl / 3600 ))h)"
    gate_log_verdict "${_root:-$_d}" expired "idle $(( _idle / 3600 ))h, reclaimed during a turn end in $gate_repo_root"
  fi
done

# Ours: refreshed, not expired. This is also what backfills a pre-upgrade sentinel of our own, and
# what lets a long unattended run keep its gate -- idle time is measured from the last turn to end
# here, not from when the gate was armed.
(( GATE_DRY )) || { [[ -n "$slug_dir" ]] && gate_touch_heartbeat "$slug_dir"; }

# Armed somewhere, but not for this repository. Not our business -- unless this is a dry run, which is
# not asking whether a gate holds. `gate.sh verify` deliberately works with nothing armed, because
# checking your own work is what you do *while* implementing, before any gate exists.
if [[ -z "$slug_dir" ]] && ! (( GATE_DRY )); then
  pass "armed elsewhere, not for $gate_repo_root"
fi

# ---------------------------------------------------------------- a subagent is not a turn
# Claude Code converts a registered Stop hook into SubagentStop for subagents, so this hook fires every
# time one completes. That is the wrong question to ask here: the gate decides whether the *user's turn*
# may end. Left alone it meant da-review-all's three layer subagents each triggered a full run of the
# gating suite, exit 2 *prevented a review subagent from stopping* because the repository's tests were
# red, and the attempt budget was spent three times over by work that was not the user's turn.
if [[ "$is_subagent" == "1" ]]; then
  pass "subagent completed (${agent_type}); the gate applies to the turn, not to a subagent"
fi


# Armed for this repo, so from here a malfunction must block rather than pass. See docs/decisions.md.
if [[ "$GATE_NODE_MISSING" == "1" ]]; then
  block "The verification gate needs node and cannot find it on PATH, so it cannot check anything.

This is a fault in the gate's environment, not in your work. Fix PATH for the agent, or disarm the
gate at $slug_dir -- do not treat this as a pass."
fi
if [[ -z "$PROFILES" || ! -d "$PROFILES" ]]; then
  block "The verification gate cannot find its profiles directory (looked for: ${PROFILES:-<unset>}).

The dotagents checkout may have moved. Re-run scripts/setup.sh install, or disarm the gate at
$slug_dir -- do not treat this as a pass."
fi
# Counters belong to a working tree, not to the repository: two worktrees are two pieces of work, and
# carrying a count between them would escalate at a tree whose own first attempt had not happened.
state_dir="$slug_dir/wt/$(gate_worktree_key "$cwd")"
mkdir -p "$state_dir" 2>/dev/null || true
attempts_file="$state_dir/attempts.json"

# The pre-worktree layout kept the records beside the sentinel. Read a delegated file from there when
# this tree has none: losing a delegated result means re-asking a human, which is a worse default than
# reading a file we wrote ourselves one version ago.
delegated_file="$state_dir/delegated.json"
if [[ ! -e "$delegated_file" && -e "$slug_dir/delegated.json" ]]; then
  delegated_file="$slug_dir/delegated.json"
fi

# A verdict beside the counters means this working tree's gate has already given up. It stops
# blocking -- that is the point of bounding it -- but it must not read as green, so the trace line is
# deliberately different from the all-clear one. Per working tree, not per repository: a dead end in
# one worktree must not release the gate for every other piece of work in parallel.
verdict_file="$state_dir/VERDICT"
if [[ -f "$verdict_file" ]]; then
  pass "gave up earlier on $(sed -n 3p "$verdict_file" 2>/dev/null) after $(sed -n 4p "$verdict_file" 2>/dev/null) attempts -- the work was NOT verified"
fi

# ---------------------------------------------------------------- resolve the profile

remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote" ]]; then
  # Not a git repo, or no origin. We have no basis for choosing commands, so we do not guess.
  pass "no git remote in $cwd"
fi

profile="$(node -e '
  const fs=require("fs"), path=require("path");
  const [dir, remote] = process.argv.slice(1);
  let hit = null, broken = [];
  let names = [];
  try { names = fs.readdirSync(dir); } catch { process.stdout.write("ERR:unreadable\n"); process.exit(0); }
  for (const f of names) {
    if (!f.endsWith(".json") || f.startsWith("_")) continue;
    // try/catch per file: with it around the loop, one malformed profile hid every profile after
    // it in readdir order, and the gate opened for those repositories with no message.
    try {
      const p = JSON.parse(fs.readFileSync(path.join(dir, f), "utf8"));
      if (p?.match?.remote && remote.includes(p.match.remote)) { hit = path.join(dir, f); break; }
    } catch { broken.push(f); }
  }
  if (hit) process.stdout.write(hit + "\n");
  else if (broken.length) process.stdout.write("ERR:broken:" + broken.join(",") + "\n");
' "$PROFILES" "$remote" 2>/dev/null)"

case "$profile" in
  ERR:unreadable)
    block "The verification gate could not read $PROFILES, so it cannot check anything.
This is a fault in the gate, not in your work. Do not treat it as a pass." ;;
  ERR:broken:*)
    block "These profile files are not valid JSON, so the gate cannot tell whether one of them
applies to this repository: ${profile#ERR:broken:}

Fix the JSON in $PROFILES, or disarm the gate at $slug_dir. Do not treat this as a pass." ;;
esac

# No matching profile means we do not know how to verify this repository. Blocking on a guess would
# be worse than not blocking: it would teach the user to ignore the gate.
[[ -n "$profile" ]] || pass "no profile matches $remote"

repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
sub="$(node -e 'try{console.log(require(process.argv[1]).cwd||"")}catch{}' "$profile")"
run_dir="$repo_root${sub:+/$sub}"
[[ -d "$run_dir" ]] || run_dir="$repo_root"

# ---------------------------------------------------------------- run the gating checks

# Only checks that gate AND that we are permitted to run. Delegated ones are handled below.
# Written to a file and read back with `while read` rather than mapfile, because macOS ships
# bash 3.2 and this has to run under whatever shell the agent invokes.
# Pass a full template: BSD mktemp treats `-t x` as a prefix, GNU coreutils demands XXXXXX and
# errors on anything else. A bare `-t dotagents-gate` works on macOS and fails on Linux.
work="$(mktemp "${TMPDIR:-/tmp}/dotagents-gate.XXXXXX" 2>/dev/null)"
if [[ -z "$work" || ! -f "$work" ]]; then
  # The gate could not set itself up. It must not let the turn through on its own malfunction --
  # a guardrail that fails open is worse than none (docs/decisions.md).
  block "The verification gate could not create its scratch file, so it cannot check anything.

This is a fault in the gate itself, not in your work. Either fix it or disarm the sentinel at
$slug_dir before continuing -- do not treat this as a pass."
fi
# Registered through the same handler rather than as a second trap: a bare `trap ... EXIT` here would
# replace the crash guard installed above, and losing it is invisible until the gate crashes.
_gate_work="$work"

# Defaults, not measurements. They have to be generous enough for a real suite and finite enough that
# a hung check cannot hold a turn open indefinitely.
GATE_CHECK_TIMEOUT_DEFAULT=120
GATE_TOTAL_TIMEOUT_DEFAULT=300

# A command the repository forbids must not be run by the gate either. `forbidden` was declared in the
# schema, used in three profiles, described in da-verify/SKILL.md -- and read by nothing. The gate
# `eval`ed whatever `cmd` said, so a repository could forbid `cdk deploy` and have the gate run it at
# every turn end. docs/mechanisms.md is explicit about this shape: a rule written in a skill is a
# request, not a guarantee, and guardrails belong in hooks.
#
# One per line so a phrase containing spaces survives; `read` gives the whole line to the variable.
forbidden_list="$(node -e '
  try { for (const f of require(process.argv[1]).forbidden || []) if (String(f).trim()) console.log(f) }
  catch {}
' "$profile" 2>/dev/null)"

# The first forbidden phrase contained in a command, or nothing.
forbidden_hit() { # <command>
  local phrase
  while IFS= read -r phrase; do
    [[ -n "$phrase" ]] || continue
    [[ "$1" == *"$phrase"* ]] && { printf '%s' "$phrase"; return 0; }
  done <<<"$forbidden_list"
  return 1
}

budget_total="$(node -e '
  try { const v = require(process.argv[1]).timeout_total;
        console.log(Number.isInteger(v) && v > 0 ? v : "") } catch {}
' "$profile" 2>/dev/null)"
case "$budget_total" in ''|*[!0-9]*|0) budget_total=$GATE_TOTAL_TIMEOUT_DEFAULT ;; esac

# id, timeout and the mutates flag first, command last: the command is the only field that can contain
# a tab, and `read` gives the remainder of the line to the last variable.
node -e '
  const p = require(process.argv[1]);
  const dflt = Number(process.argv[2]);
  for (const c of p.checks || [])
    if (c.gate && c.agent_may_run) {
      const t = Number.isInteger(c.timeout) && c.timeout > 0 ? c.timeout : dflt;
      console.log([c.id, t, c.mutates ? "1" : "0", c.cmd].join("\t"));
    }
' "$profile" "$GATE_CHECK_TIMEOUT_DEFAULT" > "$work"

# What the working tree looks like, cheaply, so a check that declares `mutates` can be held to it.
tree_fingerprint() {
  git -C "$repo_root" -c core.quotePath=false status --porcelain 2>/dev/null
}

# macOS ships no `timeout` and no `gtimeout`, so the wall clock is built here rather than depended on.
# Real seconds, deliberately not gate_now(): this measures how long a command actually took, and a
# clock the environment can move would be a way to defeat the budget.
#
# The kill reaches the subshell running `eval`, not its grandchildren, so a `pnpm test` that spawned
# node may leave one behind. That is the right trade for now: the requirement is that the hook -- and
# therefore the turn, and therefore the loop -- is released. A lingering child is the lesser evil, and
# a real tree kill means moving execution into node's spawn(), which moves the {files}+eval injection
# boundary that exactly one test stands on. Separate change, separately reviewed.
run_check() { # <seconds> <command>  -> sets check_out and check_code; touches $work.timeout on a kill
  local secs="$1" c="$2" pid dog waited
  rm -f "$work.timeout" "$work.out"
  # The gate's own control variables are unset for the child. A check is repository code, not gate
  # internals, and leaking them changes what it does: `gate.sh verify` sets DOTAGENTS_GATE_DRY=1, the
  # profile gates ./scripts/test-verify-gate.sh, and that suite then ran every one of its hook
  # invocations in dry mode -- so verifying this repository reported its own gate suite as failing.
  ( cd "$run_dir" \
    && unset DOTAGENTS_GATE_DRY DOTAGENTS_GATE_NOW DOTAGENTS_GATE_TTL_HOURS DOTAGENTS_GATE_MAX_ATTEMPTS \
    && eval "$c" ) > "$work.out" 2>&1 &
  pid=$!
  (
    waited=0
    while [[ $waited -lt $secs ]]; do
      kill -0 "$pid" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited+1))
    done
    kill -0 "$pid" 2>/dev/null || exit 0
    # Touched BEFORE the kill. Without it, `wait` returning 143 because the watchdog fired is
    # indistinguishable from 143 for any other reason -- and "the gate timed out" would get reported
    # as "your check failed", which is a different claim about different code.
    : > "$work.timeout"
    kill -TERM "$pid" 2>/dev/null
    sleep 2
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null
  ) 2>/dev/null &
  dog=$!
  wait "$pid" 2>/dev/null
  check_code=$?
  kill "$dog" 2>/dev/null
  wait "$dog" 2>/dev/null
  check_out="$(cat "$work.out" 2>/dev/null)"
  rm -f "$work.out"
}

failed_id=""
failed_cmd=""
failed_out=""
failed_code=0
# Which finding this is, and therefore which verdict it would become. "the human has not confirmed"
# is not "the code is broken", and a record that conflated them would be useless to read later.
failed_kind="red"

# How many consecutive failures before this gate stops holding. Not 2: 2 is where the message already
# escalates, and the terminal point has to be strictly later or the escalation never gets a turn to
# work. The env var takes precedence so the tests can shorten it without editing a profile.
max_attempts="${DOTAGENTS_GATE_MAX_ATTEMPTS:-}"
if [[ -z "$max_attempts" ]]; then
  max_attempts="$(node -e '
    try { const v = require(process.argv[1]).max_attempts;
          console.log(Number.isInteger(v) && v > 0 ? v : "") } catch {}
  ' "$profile" 2>/dev/null)"
fi
case "$max_attempts" in ''|*[!0-9]*|0) max_attempts=3 ;; esac

gate_started="$(date +%s)"
unrun=""

while IFS=$'\t' read -r id secs mutates cmd; do
  [[ -n "$id" ]] || continue
  case "$secs" in ''|*[!0-9]*|0) secs=$GATE_CHECK_TIMEOUT_DEFAULT ;; esac

  # {files} is a scope narrowing. With nothing changed there is nothing to check.
  if [[ "$cmd" == *"{files}"* ]]; then
    # NUL-separated with quotePath off, so paths with spaces or non-ASCII survive; each name is
    # then shell-quoted before substitution because the result is handed to eval. Unquoted, a file
    # called `a;touch pwned;b.ts` would execute -- and anything that can write to the work tree
    # chooses that name.
    #
    # Untracked files are included: a turn that only adds new files produced an empty list, which
    # skipped the check entirely -- and a new file is what most needs checking.
    #
    # Listed from $run_dir, not from the repository root. The command runs in
    # repo_root/<profile.cwd>, so root-relative paths were being handed to a runner that could not
    # open them: dresscode-backend.json sets "cwd": "v2" with `vitest run {files}`, and a changed file
    # arrived as `v2/src/foo.ts` for a vitest already inside `v2/`. Depending on passWithNoTests that
    # is a permanent false failure or a vacuous pass. `--relative` also scopes the list to that
    # subtree, which is the right answer too: a check that runs in v2/ is about v2/'s files.
    files=""
    while IFS= read -r -d '' _f; do
      [[ -n "$_f" ]] || continue
      files="$files $(printf '%q' "$_f")"
    done < <(
      git -C "$run_dir" -c core.quotePath=false diff -z --relative --name-only --diff-filter=d HEAD 2>/dev/null
      git -C "$run_dir" -c core.quotePath=false ls-files -z --others --exclude-standard 2>/dev/null
    )
    [[ -n "${files// /}" ]] || continue
    cmd="${cmd//\{files\}/${files# }}"
  fi

  # Nothing new is started once the total budget is gone. Overrunning the harness's own hook timeout
  # is the one failure the gate cannot observe -- it exits with neither 0 nor 2, which is
  # non-blocking, so the turn ends looking clean.
  # Checked before starting, and deliberately not used to shorten a check that is already allowed to
  # run. Clamping a check to the remaining budget would report it as a timeout for a reason that has
  # nothing to do with that check -- and it would make this branch nearly unreachable, since the
  # budget could then only ever run out by killing something. The cost is that the total can overshoot
  # by at most one check's timeout, which is why the hook entry in templates/ allows for both.
  if (( budget_total - ( $(date +%s) - gate_started ) <= 0 )); then
    unrun="${unrun:+$unrun }$id"
    continue
  fi

  # Checked after {files} substitution, so what is compared is the command that would actually run.
  _forbidden="$(forbidden_hit "$cmd" || true)"
  if [[ -n "$_forbidden" ]]; then
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "forbidden"
      printf '%s' "This repository forbids it: the profile lists \"$_forbidden\" under 'forbidden',
and the '$id' check would have run a command containing that phrase.

The gate did not run it. Nothing was checked by this check -- do not read the block
as a failing test. Either the profile contradicts itself, or the check needs a
command that does not do the forbidden thing."
    } > "$work.fail"
    break
  fi

  before=""
  [[ "$mutates" == "1" ]] && before="$(tree_fingerprint)"

  run_check "$secs" "$cmd"
  out="$check_out"
  code="$check_code"

  # A check declaring `mutates` is an auto-fixer, and both dresscode profiles gate on two of them
  # (`lint:fix`, `format:fix`, scope: all). Succeeding is not enough to report green: the hook has
  # just rewritten the tree after the agent decided it was done, and in a loop the next iteration
  # would read files it did not write. So the change is surfaced and the turn is held once. Nothing is
  # reverted -- the fix is wanted, the silence is not -- and the next turn passes with nothing left to
  # fix. A gate that repairs things quietly is a gate whose green cannot be trusted.
  if [[ "$mutates" == "1" && $code -eq 0 && "$(tree_fingerprint)" != "$before" ]]; then
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "mutated"
      printf '%s' "The '$id' check changed the working tree while running.

It succeeded, so nothing is broken -- but the files you were about to finish with are
not the files you wrote. Review the changes it made, then end the turn again; with
nothing left to fix this check passes and the gate gets out of the way.

Working tree now:
$(tree_fingerprint)

Its own output:
$out"
    } > "$work.fail"
    break
  fi

  if [[ -f "$work.timeout" ]]; then
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "timeout"; printf '%s' "$out"; } > "$work.fail"
    break
  fi
  if [[ $code -ne 0 ]]; then
    # NOTE: this loop is fed by `done < "$work"` -- a file redirect, not a pipe -- so the body runs
    # in this shell and `block`'s exit actually exits the script. Do not convert this to
    # `node ... | while ...`: the body would become a subshell, `block` would exit only that
    # subshell, and execution would fall through to the all-clear `pass` below. Silent fail-open.
    { printf '%s\n%s\n%s\n' "$id" "$cmd" "$code"; printf '%s' "$out"; } > "$work.fail"
    break
  fi
done < "$work"

if [[ -f "$work.fail" ]]; then
  failed_id="$(sed -n 1p "$work.fail")"
  failed_cmd="$(sed -n 2p "$work.fail")"
  failed_code="$(sed -n 3p "$work.fail")"
  failed_out="$(tail -n +4 "$work.fail")"
  if [[ -f "$work.timeout" ]]; then
    # A timeout is a malfunction of the gate, not a finding about the code. Recorded as its own reason
    # so a verdict read a day later does not claim the check failed when it never finished.
    failed_kind="timeout"
    failed_out="The gate killed this check: it timed out after ${secs}s.
It says nothing about whether the code is correct -- only that the gate could not
finish checking within its budget. Raise 'timeout' for this check in the profile,
or make the check faster.

Output captured before the kill:
$failed_out"
  fi
fi

# Checks the budget never reached. Not a pass: reporting green for something that did not run is the
# failure this whole section exists to prevent.
if [[ -z "$failed_id" && -n "$unrun" ]]; then
  failed_id="gate-budget"
  failed_kind="timeout"
  failed_cmd="(the gate ran out of its total budget)"
  failed_code="-"
  failed_out="These gating checks were not run: $unrun

The gate spends at most ${budget_total}s per turn end (timeout_total). It stopped starting
checks rather than risk being killed by the agent's own hook timeout, which exits
non-blocking and would have let this turn end looking green.

Raise 'timeout_total' in the profile, narrow the checks with scope: changed, or move
the slow ones out of the gate."
fi

# ---------------------------------------------------------------- delegated checks

# A check the agent may not run still has to happen. We require evidence that the user ran it,
# recorded by the skill. Otherwise "I asked the user to run typecheck" becomes a way to finish
# without ever seeing the result.
if [[ -z "$failed_id" ]]; then
  node -e '
    const p = require(process.argv[1]);
    for (const c of p.checks || [])
      if (c.gate && !c.agent_may_run) console.log([c.id, c.delegate_reason || ""].join("\t"));
  ' "$profile" > "$work"

  # Recorded rather than blocked on the spot. Blocking here bypassed the attempt counter entirely, so
  # a delegated check with nobody around to run it was a wall with no door: it blocked every turn
  # cycle forever and never moved any counter. It goes through the same budget as everything else now.
  while IFS=$'\t' read -r id reason; do
    [[ -n "$id" ]] || continue
    if ! grep -qs "\"$id\"" "$delegated_file" 2>/dev/null; then
      failed_id="$id"
      failed_kind="needs_human"
      failed_cmd="(delegated -- the agent may not run this)"
      failed_code="-"
      failed_out="$reason"
      break
    fi
  done < "$work"
fi

# ---------------------------------------------------------------- dry run: report, touch nothing
# Everything below this point writes state -- the attempt counter, a verdict, the pass/block dialect.
# A dry run has produced its answer by now, so it stops here.
if (( GATE_DRY )); then
  if [[ -z "$failed_id" ]]; then
    printf 'gate: all gating checks green (%s)\n' "$gate_repo_root"
    exit 0
  fi
  {
    printf 'gate: %s\n' "$failed_id"
    printf '  kind    : %s\n' "$failed_kind"
    printf '  command : %s\n' "$failed_cmd"
    printf '  cwd     : %s\n' "$run_dir"
    printf '  exit    : %s\n' "$failed_code"
    echo
    echo "output:"
    tail -20 <<<"$failed_out" | sed 's/^/  /'
  } >&2
  exit 1
fi

# ---------------------------------------------------------------- all clear

if [[ -z "$failed_id" ]]; then
  node -e 'require("fs").writeFileSync(process.argv[1],"{}\n")' "$attempts_file" 2>/dev/null || true
  pass "all gating checks green"
fi

# ---------------------------------------------------------------- blocked

# Written through a temp file and renamed. Two concurrent writers could otherwise leave a truncated
# attempts.json, which JSON.parse inside the catch below turns into {} -- silently resetting the count
# so the bound is never reached. That is a fail-open wearing a parse error as a disguise.
attempts="$(node -e '
  const fs=require("fs"); const [f,id]=process.argv.slice(1);
  let a={}; try{a=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}
  a[id]=(a[id]||0)+1;
  const tmp = f + ".tmp." + process.pid;
  fs.writeFileSync(tmp, JSON.stringify(a,null,2)+"\n");
  fs.renameSync(tmp, f);
  console.log(a[id]);
' "$attempts_file" "$failed_id" 2>/dev/null || echo 1)"
case "$attempts" in ''|*[!0-9]*) attempts=1 ;; esac

failed_detail="$(
  echo "  command : $failed_cmd"
  echo "  cwd     : $run_dir"
  echo "  exit    : $failed_code"
  echo
  echo "last 20 lines of output:"
  tail -20 <<<"$failed_out" | sed 's/^/  /'
)"

# The order below is the fix, not just the bound. The terminal decision has to come BEFORE the
# re-entry release, because the release short-circuits everything -- so the verdict would never be
# written on the turn it was due.
if (( attempts >= max_attempts )); then
  gate_write_verdict "$state_dir" "$failed_kind" "$failed_id" "$attempts" "$failed_code" \
    "$agent" "$failed_cmd" "$failed_out"
  gate_log_verdict "$gate_repo_root" "$failed_kind" "gave up on $failed_id after $attempts attempts"
  trace "$agent" "$cwd" "GAVE UP on $failed_id after $attempts attempts ($failed_kind)"

  terminal_msg="$(
    printf 'The gate has given up on the %s check after %s attempts.\n' "$failed_id" "$attempts"
    echo
    echo "$failed_detail"
    echo
    echo "This gate is now releasing and will not block again for this check."
    echo "The work is NOT verified. Do not describe it as done, do not commit it as passing, and"
    echo "do not open a PR claiming green. Say plainly what is still red and what you could not fix."
    echo
    echo "Recorded at $state_dir/VERDICT. Re-arming the gate starts a fresh budget."
  )"

  # Deliberately not routed through block(): block() releases on re-entry, and this message is the one
  # that must not be swallowed. On Claude Code the crossing invocation still exits 2, because exit 2
  # is what routes stderr to the model and a non-blocking exit does not reliably -- releasing here
  # would let the agent stop without ever learning the gate gave up. One more blocked turn is cheap,
  # and it puts the failure in the transcript.
  if [[ "$agent" == "cursor" ]]; then
    emit_cursor_followup "$terminal_msg" "$failed_id (gave up)"
  fi
  {
    printf '[dotagents] %s\n' "$terminal_msg"
    echo
    echo "This is a hook speaking, not the user."
  } >&2
  exit 2
fi

block "$(
  if (( attempts >= 2 )); then
    # Repeated correction piles failed approaches into the context and makes each attempt worse.
    echo "The '$failed_id' check has now failed $attempts times in a row (attempt $attempts of $max_attempts)."
    echo
    echo "Stop patching. Each further attempt adds a failed approach to this context and makes"
    echo "the next one less likely to work. Write down what you tried and why it failed, then"
    echo "run /clear and restart with that knowledge folded into the prompt."
  else
    echo "Cannot finish: the '$failed_id' check is failing (attempt $attempts of $max_attempts)."
  fi
  echo
  echo "After $max_attempts this gate stops blocking and records that it gave up. It will not"
  echo "become green on its own."
  echo
  echo "$failed_detail"
)" "$failed_id"
