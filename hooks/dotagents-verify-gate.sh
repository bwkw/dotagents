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

payload="$(cat)"

# Tell the two agents apart by their payload. Cursor's stop hook sends {status, loop_count} and no
# cwd; Claude Code's sends cwd and hook_event_name.
read -r agent cwd loop_count <<<"$(printf '%s' "$payload" | node -e '
  let s = ""; process.stdin.on("data", d => (s += d)).on("end", () => {
    let p = {}; try { p = JSON.parse(s) } catch {}
    const cursor = "loop_count" in p || ("status" in p && !("cwd" in p));
    console.log([cursor ? "cursor" : "claude", p.cwd || "-", p.loop_count ?? 0].join(" "));
  });
' 2>/dev/null || echo "claude - 0")"

[[ "$cwd" == "-" || -z "$cwd" ]] && cwd="$PWD"

slug_dir="$(dirname "${active[0]}")"
attempts_file="$slug_dir/attempts.json"

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
  printf '%s\n' "$1" >&2
  exit 2
}

# Let the turn end.
pass() { [[ "$agent" == "cursor" ]] && printf '%s' '{}'; exit 0; }

# ---------------------------------------------------------------- resolve the profile

remote="$(git -C "$cwd" remote get-url origin 2>/dev/null || true)"
if [[ -z "$remote" ]]; then
  # Not a git repo, or no origin. We have no basis for choosing commands, so we do not guess.
  pass
fi

profile="$(node -e '
  const fs=require("fs"), path=require("path");
  const [dir, remote] = process.argv.slice(1);
  let hit=null;
  try {
    for (const f of fs.readdirSync(dir)) {
      if (!f.endsWith(".json") || f.startsWith("_")) continue;
      const p = JSON.parse(fs.readFileSync(path.join(dir,f),"utf8"));
      if (p?.match?.remote && remote.includes(p.match.remote)) { hit = path.join(dir,f); break; }
    }
  } catch {}
  if (hit) console.log(hit);
' "$PROFILES" "$remote" 2>/dev/null)"

# No profile means we do not know how to verify this repository. Blocking on a guess would be
# worse than not blocking: it would teach the user to ignore the gate.
[[ -n "$profile" ]] || pass

repo_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || echo "$cwd")"
sub="$(node -e 'try{console.log(require(process.argv[1]).cwd||"")}catch{}' "$profile")"
run_dir="$repo_root${sub:+/$sub}"
[[ -d "$run_dir" ]] || run_dir="$repo_root"

# ---------------------------------------------------------------- run the gating checks

# Only checks that gate AND that we are permitted to run. Delegated ones are handled below.
# Written to a file and read back with `while read` rather than mapfile, because macOS ships
# bash 3.2 and this has to run under whatever shell the agent invokes.
work="$(mktemp -t dotagents-gate)"
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
    files="$(git -C "$repo_root" diff --name-only --diff-filter=d HEAD 2>/dev/null | tr '\n' ' ')"
    [[ -n "${files// /}" ]] || continue
    cmd="${cmd//\{files\}/$files}"
  fi

  out="$(cd "$run_dir" && eval "$cmd" 2>&1)"
  code=$?
  if [[ $code -ne 0 ]]; then
    # The loop body runs in a subshell when fed by a pipe, so hand the result out through a file.
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
        echo "Ask the user to run it, wait for their output, then record the result:"
        echo "  echo '{\"$id\": \"passed\"}' >> \"$slug_dir/delegated.json\""
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
