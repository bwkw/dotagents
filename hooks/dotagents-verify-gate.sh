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
#   Claude Code  Stop hook.   exit 2 BLOCKS the turn; stderr goes to the agent.
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

GATE_DIR="${DOTAGENTS_GATE_DIR:-$HOME/.claude/.dotagents-gate}"

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
(( ${#active[@]} )) || exit 0

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

payload="$(cat)"

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
    process.stdout.write([
      cursor ? "cursor" : "claude",
      p.cwd || "-",
      Number.isFinite(n) ? String(Math.trunc(n)) : "0",
      p.stop_hook_active ? "1" : "0",
    ].join("\n") + "\n");
  });
' 2>/dev/null)"

agent="$(sed -n 1p <<<"$_fields")"
cwd="$(sed -n 2p <<<"$_fields")"
loop_count="$(sed -n 3p <<<"$_fields")"
stop_active="$(sed -n 4p <<<"$_fields")"

# Defaults, and a numeric guarantee for loop_count so the arithmetic below cannot explode.
[[ -n "$agent" ]] || agent="claude"
[[ "$loop_count" =~ ^[0-9]+$ ]] || loop_count=0
[[ "$stop_active" == "1" ]] || stop_active=0
[[ "$cwd" == "-" || -z "$cwd" ]] && cwd="$PWD"

# Emit a block, in whichever dialect this agent speaks, then exit.
# $1 = message
block() {
  if [[ "$agent" == "cursor" ]]; then
    # Cursor cannot be blocked. Feed the failure back as the next user message instead, and stop
    # doing so before the loop_limit so the budget is not silently exhausted by us.
    if [[ "$loop_count" -ge 3 ]]; then
      printf '%s' '{}'
      exit 0
    fi
    printf '%s' "$1" | node -e '
      let s = ""; process.stdin.on("data", d => (s += d)).on("end", () => {
        process.stdout.write(JSON.stringify({ followup_message: s }));
      });
    '
    exit 0
  fi
  # Claude Code re-invokes this hook after a block, and the agent cannot reach the user without
  # ending a turn. Blocking indefinitely would trap it: the instruction "ask the user" is
  # unreachable from inside a blocked turn. So on a re-entry, hand control back once, loudly.
  if [[ "$stop_active" == "1" ]]; then
    {
      printf '[dotagents] %s\n' "$1"
      echo
      echo "Releasing the gate for this turn so you can reach the user -- the checks above are"
      echo "still failing. The sentinel stays armed; say plainly what is red and what you need."
    } >&2
    exit 0
  fi
  printf '[dotagents] %s\n' "$1" >&2
  exit 2
}

# Let the turn end.
pass() { [[ "$agent" == "cursor" ]] && printf '%s' '{}'; exit 0; }

# Each sentinel records the repository root it belongs to. Match on that, not on position:
# with two repositories armed, active[0] would check one and report against the other.
gate_repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
slug_dir=""
for _sentinel in "${active[@]}"; do
  if [[ "$(cat "$_sentinel" 2>/dev/null)" == "$gate_repo_root" ]]; then
    slug_dir="$(dirname "$_sentinel")"
    break
  fi
done
# Armed somewhere, but not for this repository. Not our business.
[[ -n "$slug_dir" ]] || pass

# Armed for this repo, so from here a malfunction must block rather than pass. See docs/adr/0002.
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
attempts_file="$slug_dir/attempts.json"

# ---------------------------------------------------------------- resolve the profile

remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote" ]]; then
  # Not a git repo, or no origin. We have no basis for choosing commands, so we do not guess.
  pass
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
[[ -n "$profile" ]] || pass

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
  # a guardrail that fails open is worse than none (docs/adr/0002).
  block "The verification gate could not create its scratch file, so it cannot check anything.

This is a fault in the gate itself, not in your work. Either fix it or disarm the sentinel at
$slug_dir before continuing -- do not treat this as a pass."
fi
trap 'rm -f "$work" "$work.fail"' EXIT

node -e '
  const p = require(process.argv[1]);
  for (const c of p.checks || [])
    if (c.gate && c.agent_may_run) console.log([c.id, c.cmd].join("\t"));
' "$profile" > "$work"

failed_id=""
failed_cmd=""
failed_out=""
failed_code=0

while IFS=$'\t' read -r id cmd; do
  [[ -n "$id" ]] || continue

  # {files} is a scope narrowing. With nothing changed there is nothing to check.
  if [[ "$cmd" == *"{files}"* ]]; then
    # NUL-separated with quotePath off, so paths with spaces or non-ASCII survive; each name is
    # then shell-quoted before substitution because the result is handed to eval. Unquoted, a file
    # called `a;touch pwned;b.ts` would execute -- and anything that can write to the work tree
    # chooses that name.
    #
    # Untracked files are included: a turn that only adds new files produced an empty list, which
    # skipped the check entirely -- and a new file is what most needs checking.
    files=""
    while IFS= read -r -d '' _f; do
      [[ -n "$_f" ]] || continue
      files="$files $(printf '%q' "$_f")"
    done < <(
      git -C "$repo_root" -c core.quotePath=false diff -z --name-only --diff-filter=d HEAD 2>/dev/null
      git -C "$repo_root" -c core.quotePath=false ls-files -z --others --exclude-standard 2>/dev/null
    )
    [[ -n "${files// /}" ]] || continue
    cmd="${cmd//\{files\}/${files# }}"
  fi

  out="$(cd "$run_dir" && eval "$cmd" 2>&1)"
  code=$?
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

  while IFS=$'\t' read -r id reason; do
    [[ -n "$id" ]] || continue
    if ! grep -qs "\"$id\"" "$slug_dir/delegated.json" 2>/dev/null; then
      block "$(
        echo "Cannot finish: the '$id' check has not been confirmed."
        echo
        echo "$reason"
        echo
        echo "Ask the user to run it and wait for their output. Once they report it, /verify"
        echo "records the result. Do not write that record yourself -- the whole point of this"
        echo "check is that the result came from them."
        echo
        echo "Do not end the turn claiming success while this is outstanding."
      )"
    fi
  done < "$work"
fi

# ---------------------------------------------------------------- all clear

if [[ -z "$failed_id" ]]; then
  node -e 'require("fs").writeFileSync(process.argv[1],"{}\n")' "$attempts_file" 2>/dev/null || true
  pass
fi

# ---------------------------------------------------------------- blocked

attempts="$(node -e '
  const fs=require("fs"); const [f,id]=process.argv.slice(1);
  let a={}; try{a=JSON.parse(fs.readFileSync(f,"utf8"))}catch{}
  a[id]=(a[id]||0)+1;
  fs.writeFileSync(f, JSON.stringify(a,null,2)+"\n");
  console.log(a[id]);
' "$attempts_file" "$failed_id" 2>/dev/null || echo 1)"

block "$(
  if (( attempts >= 2 )); then
    # Repeated correction piles failed approaches into the context and makes each attempt worse.
    echo "The '$failed_id' check has now failed $attempts times in a row."
    echo
    echo "Stop patching. Each further attempt adds a failed approach to this context and makes"
    echo "the next one less likely to work. Write down what you tried and why it failed, then"
    echo "run /clear and restart with that knowledge folded into the prompt."
  else
    echo "Cannot finish: the '$failed_id' check is failing."
  fi
  echo
  echo "  command : $failed_cmd"
  echo "  cwd     : $run_dir"
  echo "  exit    : $failed_code"
  echo
  echo "last 20 lines of output:"
  tail -20 <<<"$failed_out" | sed 's/^/  /'
)"
