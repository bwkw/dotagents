#!/usr/bin/env bash
# Drive design -> implementation -> review -> one stacked PR per landing.
#
#   loop.sh "<what you want>"        the only one you need: advances one step, whatever step that is
#   loop.sh size "<what you want>"   measure the change, and say which tier it is
#   loop.sh design                   the design phase: what to type next, and what it can verify
#   loop.sh run [<landing-plan>]     run the landings (the plan is required above tier S)
#   loop.sh report [--json]          cost per accepted landing, and where the money went
#   loop.sh status                   the last size verdict, and what the gate thinks
#
# This script types what a human would type. It is not a new agent: every `claude -p` here is a user
# prompt, which is why skills carrying `disable-model-invocation` stay reachable without that field
# being removed -- it blocks the *model* from invoking them, not a person, and this is a person's
# keystrokes with the person automated away.
#
# The consequence is the thing to keep in view: a typist who never reads is a comprehension-debt
# machine. The ledger exists so there is something to read other than a transcript nobody opens.
#
# Three rules it does not break:
#
#   1. It never decides whether the work is correct. `gate.sh verify` decides that. A review finding
#      is material for a human, not a pass/fail -- the one rigorous published experiment on this had
#      an LLM review gate approving code that failed 12-20 of 38 unit tests, and found that more
#      review rounds raised the chance of approval without raising correctness. So review is capped.
#   2. It never reimplements the gate. It reads `gate.sh verify --json` and `gate.sh status --json`,
#      both of which say "for a driver rather than a human" in their own headers.
#   3. It never edits the scorer -- **on this repository**. The thing being judged and the thing doing
#      the judging are the same checkout here, so a round that touches profiles/, hooks/, the gate, the
#      check runner, this script or scripts/test-*.sh aborts the landing. Moving your own goalposts has
#      to be a human act, or a green result means nothing.
#
#      **The guarded list is dotagents' own paths and nothing else.** On any other repository it matches
#      nothing, so a round there can edit or delete the test that was failing and the gate will go green
#      legitimately. An earlier version of this comment claimed "a test suite" was guarded without that
#      qualification, which was false everywhere except here -- and a false claim about a guardrail is
#      worse than an absent one. Making it declarable per repository is recorded as follow-up in
#      docs/fix-plans/2026-08-11-loop-driver.md.
#
# Tier S is the only one that runs unattended end to end. `/grill-me` is an interview and
# `da-design-review` says "Show this to the user" in its first step -- both need somebody there. The
# tiers differ in how deep the human goes, not in whether one is present.
#
# UNVERIFIED, and written so it does not matter: whether a Stop hook fires at the end of a
# `claude -p` turn. If it does, the gate counts attempts and writes a VERDICT at max_attempts, and
# this driver reads it. If it does not, no VERDICT ever appears and the driver's own round cap stops
# the landing instead. Both abort; the ledger records *which*, so the first real run answers the
# question as a side effect. See docs/loops.md.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE_SH="$HERE/gate.sh"
LOOP_DIR="${DOTAGENTS_LOOP_DIR:-$HOME/.claude/.dotagents-loop}"
LEDGER="$LOOP_DIR/ledger.jsonl"

# Chosen numbers, not measured ones -- the same status as the gate's max_attempts of 3 and its 12h
# TTL. They are here so that nothing has to be passed on the command line in normal use: a flag you
# retype on every machine is a flag that buys nothing (docs/decisions.md).
MAX_ROUNDS=6          # implementation attempts per landing before handing back
REVIEW_ROUNDS=2       # review passes; the third would buy approval, not correctness
MAX_OPEN_PRS=5        # open layers in one stack; the reviewer is the bottleneck, not the agent
BUDGET_USD=10         # per `run` invocation

# Measured against claude 2.1.148, not assumed: `--json-schema` exists, and it takes the schema as an
# INLINE JSON STRING. Handing it a file path does not error -- it HANGS, with stdin closed, forever.
# That is why the deadline below is not optional: the two phases that ask for structured output would
# have hung on first real use, and a hang is the one failure neither the round cap, the budget nor the
# gate can stop.
SCHEMA_FLAG="--json-schema"

# Seconds a single `claude -p` may take. Chosen, not measured. The env override exists for the tests.
ROUND_TIMEOUT="${DOTAGENTS_LOOP_ROUND_TIMEOUT:-1800}"

if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then c_red=''; c_green=''; c_dim=''; c_off=''
else c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'; fi

usage() { grep -E '^#   loop\.sh ' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die()   { printf 'loop: %s\n' "$1" >&2; exit 1; }
say()   { printf '%s\n' "$1"; }
dim()   { printf '%s%s%s\n' "$c_dim" "$1" "$c_off"; }

# ---------------------------------------------------------------- identity
# One ledger for every repository, each line carrying its own `repo` and `branch`. This mirrors
# verdicts.log rather than the gate's per-repo directories: the gate needs a sentinel it can find by
# content, and a log needs to be one file you can read. Deriving a second slug-and-worktree scheme
# here would be a second implementation of an identity that already exists in two places.
repo_root() { git rev-parse --show-toplevel 2>/dev/null || pwd; }
branch()    { git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'HEAD'; }

# The ledger's notion of "which repository is this", and it is NOT the working tree. `size` is taken in
# whatever checkout you are standing in and `run` may execute inside a linked worktree, so keying on the
# toplevel would hide the recorded tier from the run that needs it. The gate solves the same problem the
# same way -- repository identity keys on the shared git dir, working-tree state keys per tree -- and
# `worktree` stays a separate field so a line still says where it happened.
repo_key() {
  local c
  c="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  case "$c" in /*) printf '%s' "$c"; return 0 ;; esac
  repo_root
}

# Already isolated? `--git-dir != --git-common-dir` is the test, but it is ALSO true inside a submodule,
# so the submodule guard is required before concluding anything -- the using-git-worktrees skill names
# this trap explicitly and it is the reason detection is not just a one-line comparison.
in_linked_worktree() {
  local g c
  g="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  c="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [[ -n "$g" && -n "$c" && "$g" != "$c" ]] || return 1
  [[ -z "$(git rev-parse --show-superproject-working-tree 2>/dev/null)" ]]
}

default_branch() {
  local b
  b="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')"
  [[ -n "$b" ]] && { printf '%s' "$b"; return 0; }
  printf 'main'
}

# ---------------------------------------------------------------- the ledger
# Append-only and never trimmed. trace.log self-trims at 200 lines by design, so anything recorded
# only there is deleted by ordinary operation; the gate learned that once already and split
# verdicts.log out for it. This is the instrument, so it gets the durable treatment.
ledger_append() { # <json-object-without-braces-fields...>  via node, keyed pairs
  mkdir -p "$LOOP_DIR" 2>/dev/null || return 0
  node -e '
    const fs = require("fs");
    const [ledger, ...kv] = process.argv.slice(1);
    const o = { ts: new Date().toISOString() };
    for (let i = 0; i < kv.length; i += 2) {
      const k = kv[i]; let v = kv[i + 1];
      if (v === "__null__") v = null;
      else if (/^-?\d+(\.\d+)?$/.test(v)) v = Number(v);
      else if (v === "true" || v === "false") v = v === "true";
      else if (v.startsWith("{") || v.startsWith("[")) { try { v = JSON.parse(v) } catch {} }
      o[k] = v;
    }
    fs.appendFileSync(ledger, JSON.stringify(o) + "\n");
  ' "$LEDGER" "$@" 2>/dev/null || true
}

# The most recent line of a given phase for this repository. `run` reads its tier back from here
# rather than re-deciding it, which is what stops `run` being a way around the front door.
ledger_last() { # <phase> <field>
  [[ -f "$LEDGER" ]] || return 0
  node -e '
    const fs = require("fs");
    const [ledger, repo, phase, field] = process.argv.slice(1);
    let last = null;
    for (const line of fs.readFileSync(ledger, "utf8").split("\n")) {
      if (!line.trim()) continue;
      try { const o = JSON.parse(line); if (o.repo === repo && o.phase === phase) last = o } catch {}
    }
    if (last && last[field] != null) process.stdout.write(String(last[field]));
  ' "$LEDGER" "$(repo_key)" "$1" "$2" 2>/dev/null || true
}

# ---------------------------------------------------------------- the scorer
# Everything that decides whether the work passes. A round that edits any of it has changed the exam
# it is sitting, so the landing stops. Deliberately wide: on this repository most of the machinery is
# under scripts/ and hooks/, which means the loop's legal work area here is skills/, docs/, agents/,
# templates/ and the top-level Markdown. That is a real limit and docs/loops.md states it.
scorer_paths() {
  printf '%s\n' profiles hooks scripts/gate.sh scripts/check.sh scripts/verify-skills.sh \
                scripts/loop.sh scripts/test-loop.sh
  git ls-files 'scripts/test-*.sh' 2>/dev/null
  [[ -n "${PLAN_PATH:-}" ]] && printf '%s\n' "$PLAN_PATH"
  return 0
}

# Whether git can answer the question at all. `changed_paths` returns the empty string both when the
# tree is clean and when git failed -- an index.lock, a dubious-ownership refusal, a cwd that is not a
# work tree -- and all four of its consumers read empty as the benign answer: "nothing touched" for the
# scorer check, "clean" for the precondition, "committed" for commit_landing, "not dirty" before
# submitting. One helper, four green readings. So readability is asked separately and it is asked first.
tree_readable() { git status --porcelain -z >/dev/null 2>&1; }

# What changed in the working tree, tracked and untracked, as repo-relative paths.
#
# A rename reports BOTH paths, and both matter: the scorer check has to see that a guarded file moved
# away, not only that some new file appeared. Under `-z` a rename is two NUL-separated fields -- the
# new path in the status entry, then the old path as a bare field with no status prefix. There is no
# " -> " separator; that spelling only exists in the non-`-z` output. The first version of this stripped
# three characters from every field, which mangled the old path of every rename, and the ONE case it
# broke is the one that matters: `git mv scripts/gate.sh gate-old.sh` produced an unguarded new path and
# a mangled old path, so a round could move the gate out of the way and not be stopped.
changed_paths() {
  git status --porcelain -z 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      const fields = s.split("\0");
      const out = [];
      for (let i = 0; i < fields.length; i++) {
        const e = fields[i];
        if (!e) continue;
        const xy = e.slice(0, 2);
        out.push(e.slice(3));
        // R or C in either column means the NEXT field is the original path, and it is consumed here
        // so it is never read as a status entry of its own.
        if (xy[0] === "R" || xy[0] === "C" || xy[1] === "R" || xy[1] === "C") {
          i++;
          if (fields[i]) out.push(fields[i]);
        }
      }
      if (out.length) process.stdout.write(out.join("\n") + "\n");
    });
  ' 2>/dev/null || true
}

scorer_touched() { # -> newline-separated offenders, empty when clean
  local changed sp
  tree_readable || { printf '<could not read the working tree>\n'; return 0; }
  changed="$(changed_paths)"
  [[ -n "$changed" ]] || return 0
  sp="$(scorer_paths)"
  # The guard list goes through argv, not a process substitution. `<(...)` hands node a /dev/fd path
  # whose readability through readFileSync is platform-dependent, and a read that fails here returns
  # "nothing was touched" -- the fail-open answer, in the check whose whole job is to fail closed.
  printf '%s\n' "$changed" | node -e '
    const guarded = process.argv[1].split("\n").filter(Boolean);
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      const hits = s.split("\n").filter(Boolean).filter((p) =>
        guarded.some((g) => p === g || p.startsWith(g.replace(/\/*$/, "") + "/")));
      if (hits.length) process.stdout.write([...new Set(hits)].join("\n") + "\n");
    });
  ' "$sp" 2>/dev/null || true
}

# ---------------------------------------------------------------- the gate
gate_verify_ok() { # -> 0 only when gating checks actually RAN and were green
  local out
  out="$(bash "$GATE_SH" verify --json 2>/dev/null)"
  GATE_JSON="$out"
  # Empty means gate.sh or node failed, not that the work is fine. Every helper below reads
  # $GATE_JSON, and an empty document makes each of them answer benignly.
  [[ -n "$out" ]] || { GATE_UNRAN="unreadable"; return 1; }
  # A `{files}`-scoped check is skipped when the tree is clean, and the hook then exits 0 -- so `ok`
  # is true although nothing executed. The gate says the two apart in prose and only in prose:
  # "all gating checks green" versus "nothing blocking". Its own comment is explicit that these are
  # different answers and only one means verified, but `verify --json` collapses both into ok:true,
  # so the distinction has to be read out of `detail`.
  #
  # This is the SECOND prose coupling to the gate's output (see gate_has_profile). The structural fix
  # is a field in `verify --json`, which lives in the scorer and is deliberately out of scope here --
  # docs/fix-plans/2026-08-11-loop-driver.md records that as the open decision.
  if grep -q 'nothing blocking' <<<"$out"; then GATE_UNRAN="skipped"; return 1; fi
  GATE_UNRAN=""

  # `agent_may_run: false` means the repository forbids the AGENT from running this check -- not that
  # the work may ship unverified. Interactively /da-verify asks the user and waits. Here there is nobody
  # to ask, and no number of rounds can satisfy it either, so waiting or rounding are both wrong: it
  # would burn MAX_ROUNDS and halt on something no round could fix (measured -- it did).
  #
  # So it is DEFERRED, and the deferral is loud. The chain becomes: the local gate runs what it may, CI
  # runs what it may not, and the PR says which is which. That respects the prohibition exactly -- the
  # repository forbade running it, and nothing here runs it. What it must never become is silent: a
  # deferred gate is no more green than a released one.
  local kind; kind="$(node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const o = JSON.parse(s); if (!o.ok && o.kind) process.stdout.write(String(o.kind)) } catch {}
    });
  ' <<<"$out")"
  if [[ "$kind" == "needs_human" ]]; then
    local id; id="$(gate_field check)"
    case " $GATE_DEFERRED " in *" $id "*) : ;; *) GATE_DEFERRED="${GATE_DEFERRED:+$GATE_DEFERRED }$id" ;; esac
    dim "   $id: the repository forbids the agent from running this -- deferred to CI, not verified here"
    return 0
  fi
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { process.exit(JSON.parse(s).ok ? 0 : 1) } catch { process.exit(1) }
    });
  ' <<<"$out"
}

gate_field() { # <field> from the last verify
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const v = JSON.parse(s)[process.argv[1]]; if (v != null) process.stdout.write(String(v)) }
      catch {}
    });
  ' "$1" <<<"${GATE_JSON:-}" 2>/dev/null || true
}

# No profile means no gating checks, and `verify` answers ok:true for that -- so `ok` alone cannot be
# trusted. There is no structured field saying "nothing matched", so this reads the one string the
# hook prints. Coupled to that wording on purpose: the alternative is resolving profiles here, which
# would be a second implementation of the matcher.
#
# It reads the LAST verify rather than running its own. Running one costs a full suite -- minutes on
# this repository -- and the first version did that on top of the implement loop's own first verify,
# so every `run` paid for two complete suite runs before any work started. Call gate_verify_ok first.
gate_has_profile() {
  [[ -n "${GATE_JSON:-}" ]] || return 1     # empty is "I could not tell", not "yes"
  ! grep -q 'no profile matches' <<<"$GATE_JSON"
}

gate_gave_up() { # -> 0 when a VERDICT has been recorded
  bash "$GATE_SH" status --json 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { process.exit(JSON.parse(s).gave_up ? 0 : 1) } catch { process.exit(1) }
    });
  '
}

# ---------------------------------------------------------------- rounds
SPENT=0
GATE_UNRAN=""
GATE_DEFERRED=""
ROUND_TIMED_OUT=0
REVIEW_REPORT=""
SECOND_REPORT=""
ROUND_COST=0; ROUND_TURNS=0; ROUND_EXIT=0; ROUND_OUT=""

# One `claude -p`. Never --bare: that switch turns off hooks, skills and CLAUDE.md, which is the
# whole mechanism here -- the official docs recommend it for scripted calls and for this loop it is
# the one fail-open in the manual. Never --dangerously-skip-permissions either; acceptEdits plus the
# profile's `forbidden` list plus the scorer check is the containment.
claude_round() { # <prompt> [inline-schema-json]
  local prompt="$1" schema="${2:-}" raw out pid t
  local args="--print --output-format json --permission-mode acceptEdits"
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-loop-round.XXXXXX")" || die "mktemp failed"

  # Bounded, and stdin closed. macOS has no `timeout`, so this polls the way
  # scripts/test-non-interactive.sh does. stdin is closed because a `claude` whose credentials have
  # expired will otherwise sit waiting for a login it can never get in an unattended run.
  # shellcheck disable=SC2086
  if [[ -n "$schema" ]]; then
    claude $args "$SCHEMA_FLAG" "$schema" "$prompt" >"$out" 2>/dev/null </dev/null &
  else
    claude $args "$prompt" >"$out" 2>/dev/null </dev/null &
  fi
  pid=$!
  t=0
  ROUND_TIMED_OUT=0
  while (( t < ROUND_TIMEOUT * 5 )); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
    t=$((t + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    # The whole process group: a killed `claude` can leave the tools it spawned holding ports.
    kill -TERM "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
    sleep 1
    kill -KILL "-$pid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null
    ROUND_TIMED_OUT=1
  fi
  wait "$pid" 2>/dev/null; ROUND_EXIT=$?
  (( ROUND_TIMED_OUT )) && ROUND_EXIT=124

  raw="$(cat "$out" 2>/dev/null)"
  rm -f "$out"
  ROUND_OUT="$raw"
  ROUND_COST="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).total_cost_usd??0))}catch{process.stdout.write("0")}})' <<<"$raw")"
  ROUND_TURNS="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(String(JSON.parse(s).num_turns??0))}catch{process.stdout.write("0")}})' <<<"$raw")"
  SPENT="$(node -e 'process.stdout.write(String(Number(process.argv[1])+Number(process.argv[2])))' "$SPENT" "${ROUND_COST:-0}")"
  return 0
}

# The round's reply text. Used to carry one skill's report into the next skill's prompt -- the review
# skills write no file, so this is the only way their findings survive the process boundary.
round_result() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const r = JSON.parse(s).result; if (r) process.stdout.write(String(r)) } catch {}
    });
  ' <<<"$ROUND_OUT" 2>/dev/null || true
}

round_has_structured() {
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const o = JSON.parse(s); process.exit(o && typeof o.structured_output === "object" && o.structured_output !== null ? 0 : 1) }
      catch { process.exit(1) }
    });
  ' <<<"$ROUND_OUT" 2>/dev/null
}

round_structured() { # <field> -> value from structured_output, empty when absent
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { const v = JSON.parse(s).structured_output?.[process.argv[1]];
            if (v != null) process.stdout.write(String(v)) } catch {}
    });
  ' "$1" <<<"$ROUND_OUT" 2>/dev/null || true
}

# ---------------------------------------------------------------- size
TIER=""; M_FILES=0; M_LAYERS=0; M_ONEWAY=0; M_RISK=0; M_UNCONF=0

# The model measures; this decides. "Scale it to the change" was the instruction in the review
# fan-out for a while and it produced the maximum every time, because nothing in it could be checked.
# A tier the model picks for itself is the same failure with a different name.
decide_tier() {
  TIER=S
  if [[ "$M_FILES" -gt 5 || "$M_LAYERS" -ge 2 ]]; then TIER=M; fi
  if [[ "$M_FILES" -gt 15 || "$M_LAYERS" -ge 3 \
        || "$M_ONEWAY" -gt 0 || "$M_RISK" -gt 0 || "$M_UNCONF" -gt 0 ]]; then TIER=L; fi
}

cmd_size() {
  local request="${1:-}"
  [[ -n "$request" ]] || die "size needs the request: loop.sh size \"<what you want>\""
  # Inline, not a file. `--json-schema` takes the schema as a string; a path makes the CLI hang.
  local schema
  schema='{"type":"object","required":["files","layers","one_way","risk_surfaces","unconfirmed"],'
  schema="$schema"'"properties":{"files":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"layers":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"one_way":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"risk_surfaces":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"unconfirmed":{"type":"array","items":{"type":"string"}}}}'

  dim "measuring with /da-investigate ..."
  claude_round "/da-investigate $request

Answer only with the structured fields. \`files\` is every file a change would touch. \`layers\` is
which of backend / frontend / infrastructure it reaches. \`one_way\` is each irreversible step.
\`risk_surfaces\` is any of money, billing, external or government submission, authorization, PII,
data migration or concurrency that the change reaches.

\`unconfirmed\` is NOT everything you failed to look at. It is only the things that, if you are wrong
about them, would make this change BIGGER OR RISKIER than the counts above suggest -- a consumer you
could not enumerate, a call path you could not follow, a migration you suspect but did not confirm.
Something you did not need to check is not unconfirmed; something you checked and found irrelevant is
not unconfirmed. If nothing could change the size of this, return an empty list -- an empty list is the
correct and common answer for a small change, and padding it sends work to a human who did not need to
see it." \
    "$schema"

  local files layers oneway risk unconf
  round_has_structured || die "no measurement came back (exit $ROUND_EXIT). Check that \`$SCHEMA_FLAG\`
  is the right flag for structured output on this version of the CLI.

  Not falling back to a guess: sizing is the step that decides whether this may run unattended at all,
  and an unmeasured change treated as small is the worst outcome available here."
  files="$(round_structured files)"; layers="$(round_structured layers)"
  oneway="$(round_structured one_way)"; risk="$(round_structured risk_surfaces)"
  unconf="$(round_structured unconfirmed)"

  count() { node -e 'const v=process.argv[1];process.stdout.write(String(v?v.split(",").filter(Boolean).length:0))' "$1"; }
  M_FILES="$(count "$files")"; M_LAYERS="$(count "$layers")"
  M_ONEWAY="$(count "$oneway")"; M_RISK="$(count "$risk")"; M_UNCONF="$(count "$unconf")"
  decide_tier

  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase size \
    request "$request" \
    tier "$TIER" files "$M_FILES" layers "$M_LAYERS" one_way "$M_ONEWAY" \
    risk_surfaces "$M_RISK" unconfirmed "$M_UNCONF" \
    cost_usd "${ROUND_COST:-0}" turns "${ROUND_TURNS:-0}" exit "$ROUND_EXIT" \
    outcome sized halt_reason __null__

  echo
  say "tier $TIER"
  say "  files $M_FILES · layers $M_LAYERS · one-way $M_ONEWAY · risk surfaces $M_RISK · unconfirmed $M_UNCONF"
  echo
  case "$TIER" in
    S) say "No design phase. The gate is this repository's own gating checks."
       say "Next:  scripts/loop.sh run" ;;
    M) say "Design review first, with you in it -- da-design-review's first step shows you its"
       say "restatement of the plan, and a misread plan produces confident, irrelevant findings."
       say "Next:  /da-design-review   then commit the 🧱 Landing plan, then:"
       say "       scripts/loop.sh run <plan-path>" ;;
    L) say "This needs the full design phase, attended. Something here is irreversible, touches a"
       say "risk surface, or was not confirmed -- and an unmeasured change is the worst thing to"
       say "hand to an unattended loop."
       say "Next:  /grill-me   →   /writing-plans   →   /da-design-review"
       say "       then commit the 🧱 Landing plan, then:  scripts/loop.sh run <plan-path>" ;;
  esac
}



# ---------------------------------------------------------------- the single entry point
# One command, typed repeatedly. Each invocation advances one step and stops; nothing has to be
# remembered about which step is next, or where the plan file went.
#
# It does NOT drive the attended stages, and cannot: `/grilling` interviews you, and an interview with
# nobody in the room produces questions into the void. So the states are advance, hand over, or run --
# and handing over exits 0, because it advanced as far as it could and the next step is a person's.
#
# The landing plan is discovered rather than named. `da-design-review` writes no file, so the plan is
# whatever you copied its 🧱 table into; the convention is docs/plans/, and the table's own header row
# is what identifies it. A content search over the whole tree would match this repository's own
# documentation, which quotes that header -- so the search is scoped to the conventional directory.
landing_plans() {
  local f
  for f in $(git ls-files 'docs/plans/*.md' 2>/dev/null); do
    grep -q 'What gates it' "$f" 2>/dev/null && printf '%s\n' "$f"
  done
  return 0
}

cmd_auto() { # <request>
  local request="$1" tier recorded plans n
  recorded="$(ledger_last size request)"
  tier="$(ledger_last size tier)"

  # Re-measure when the request is new. Reusing a stale tier for different work is how an unmeasured
  # change gets treated as a small one.
  if [[ -z "$tier" || ( -n "$request" && "$request" != "$recorded" ) ]]; then
    cmd_size "$request" || return 1
    tier="$TIER"
    echo
  else
    dim "already sized: tier $tier ($recorded)"
    echo
  fi

  if [[ "$tier" == "S" ]]; then
    cmd_run
    return $?
  fi

  plans="$(landing_plans)"
  n="$(printf '%s\n' "$plans" | grep -c . || true)"
  if [[ "$n" == "1" ]]; then
    dim "landing plan: $plans"
    echo
    cmd_run "$plans"
    return $?
  fi
  if [[ "${n:-0}" -gt 1 ]]; then
    printf 'loop: more than one committed landing plan under docs/plans/:\n' >&2
    printf '%s\n' "$plans" | sed 's/^/  /' >&2
    die "name the one you mean: scripts/loop.sh run <plan-path>"
  fi

  # No plan yet. This is the handover, and it is not a failure.
  # `${tier}` braced, deliberately. In bash 3.2 under a UTF-8 locale a full-width character sitting
  # immediately after `$var` is absorbed INTO THE VARIABLE NAME -- `$tier）` becomes a lookup of
  # `tier<3 bytes of ）`, which is unbound, and the whole run dies at the handover. macOS ships bash 3.2,
  # so this failed only on the macOS CI runner and passed everywhere else, including locally under the
  # C locale. Braces delimit the name and the bug goes away.
  say "━━ ここからはあなたの手番です（tier ${tier}）━━"
  say ""
  say "設計フェーズは対話が要るので、駆動系は打ちません。順序と、何が検証できているかだけ出します:"
  say ""
  cmd_design
  say ""
  say "🧱 Landing plan を docs/plans/ 以下に保存して commit すれば、**同じコマンドをもう一度打つだけ**で"
  say "駆動系が見つけて続きを回します:"
  say ""
  say "    scripts/loop.sh \"$request\""
  return 0
}

# ---------------------------------------------------------------- design
# The design phase is ATTENDED at every tier above S -- `/grilling` is an interview and
# `da-design-review` says "Show this to the user" in its first step. So this command does not sequence
# it and does not ask anything: it prints what to type next and reports what it can actually verify.
# Prompting here is the obvious temptation and it is forbidden -- test-non-interactive.sh asserts there
# is no interactive path, and a design phase that stalls waiting for input is the failure that whole
# suite exists to prevent.
#
# Three artifacts can be checked, and three stages cannot. Saying which is which is the point: a
# checklist that shows six green ticks when it verified three of them is worse than no checklist.

# writing-plans writes docs/superpowers/plans/YYYY-MM-DD-<name>.md and its own template makes several
# headings mandatory. The headings are the check: without them the file is notes, not a plan, and an
# empty file at the right path would otherwise satisfy the gate.
plan_files() { ls -1 docs/superpowers/plans/????-??-??-*.md 2>/dev/null || true; }
plan_has_header() { # <file>
  grep -q 'Implementation Plan' "$1" 2>/dev/null \
    && grep -q '\*\*Goal:\*\*' "$1" 2>/dev/null \
    && grep -q '## Global Constraints' "$1" 2>/dev/null \
    && grep -q -- '- \[ \]' "$1" 2>/dev/null
}
adr_files() { ls -1 docs/decisions/ADR-*.md docs/adr/*.md 2>/dev/null || true; }

cmd_design() {
  local tier; tier="$(ledger_last size tier)"
  [[ -n "$tier" ]] || die "no size recorded for this repository. Run: loop.sh size \"<what you want>\"
  The tier decides how deep the design phase goes, so it comes first."

  say "tier $tier"
  echo
  if [[ "$tier" == "S" ]]; then
    say "No design phase. README's own standing rule: a change you can describe in one sentence skips"
    say "the plan. The gate is this repository's configured checks."
    say ""
    say "Next:  scripts/loop.sh run"
    ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase design \
      tier "$tier" outcome sized halt_reason __null__ cost_usd 0 turns 0
    return 0
  fi

  local pf adr have_plan=0 have_adr=0 committed=0 plan_note=""
  for pf in $(plan_files); do
    if plan_has_header "$pf"; then have_plan=1; plan_note="$pf"; break; fi
    plan_note="$pf (no mandatory header -- writing-plans requires '# … Implementation Plan', '**Goal:**', '## Global Constraints' and '- [ ]' steps, so this is notes, not a plan)"
  done
  adr="$(adr_files | head -1)"; [[ -n "$adr" ]] && have_adr=1

  say "The stages, in order. Type them yourself -- this command does not run them, because every one"
  say "of them needs you in the room."
  echo
  [[ "$tier" == "L" ]] && {
    say "  1. /research <topic>            the outside world. CANNOT BE CHECKED -- it writes a file at"
    say "                                  a path it chooses, so nothing here can look for it."
    say "  2. /grill-me                    the interview (it delegates to /grilling, which does the work"
    say "                                  -- install both or it does nothing). CANNOT BE CHECKED."
  }
  say "  3. /writing-plans               $( ((have_plan)) && printf 'FOUND: %s' "$plan_note" || printf 'not found%s' "${plan_note:+ -- $plan_note}" )"
  say "  4. /documentation-and-adrs      $( ((have_adr)) && printf 'FOUND: %s' "$adr" || printf 'no ADR (only needed if you made a decision worth recording)' )"
  say "  5. /da-design-review            CANNOT BE CHECKED -- it writes no file at all. Its 🧱 Landing"
  say "                                  plan exists only in the conversation, so YOU copy that table"
  say "                                  into a file and commit it. Nothing else will."
  echo
  say "Then: commit the landing plan, and  scripts/loop.sh run <plan-path>"
  say "The commit is the approval -- there is no approval flag, because a flag is something you type"
  say "without reading."
  echo
  say "Verified here: the plan file and the ADR. Not verified: research, the interview, and the design"
  say "review. Three of five stages leave nothing behind, and this command will not pretend otherwise."

  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase design \
    tier "$tier" plan_found "$have_plan" adr_found "$have_adr" \
    outcome sized halt_reason __null__ cost_usd 0 turns 0
  return 0
}

# ---------------------------------------------------------------- run
HALT=""; PLAN_PATH=""

# Put the work in its own workspace, by typing the skill. The driver does not run `git worktree add`
# itself, and that is not fussiness -- `using-git-worktrees` carries five things a one-line call does
# not: the submodule guard (`--git-dir != --git-common-dir` is true inside submodules too, so the naive
# test calls a submodule "already isolated"), the directory-selection order, `git check-ignore`
# verification (an unignored worktree directory commits the whole tree into the repository), a clean
# baseline check, and a documented fallback when the sandbox refuses. Reimplementing it here would
# reproduce the shape that already went wrong once with `gate.sh arm`.
#
# What the driver does own is finding out what happened, and it reads that from git rather than from the
# reply -- the same split as typing `/da-verify` and then reading `gate.sh status --json`.
isolate() {
  local want_key; want_key="$(repo_key)"
  if in_linked_worktree; then
    dim "already in a linked worktree ($(branch)) -- not creating another"
    return 0
  fi
  local before after new
  before="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  # An empty `before` is indistinguishable from "the first listing failed", and in that case EVERY
  # existing worktree looks new -- `head -1` would then cd into an unrelated one. There is always at
  # least the main checkout, so empty means the command failed.
  [[ -n "$before" ]] || { halt isolate_failed "could not list worktrees before isolating"; return 1; }
  dim "isolating the work through /using-git-worktrees ..."
  claude_round "/using-git-worktrees

This is an unattended run: set up an isolated workspace without asking for consent -- treat this
instruction as the declared preference the skill's Step 0 looks for. Do not run the project's tests as
the baseline; something else owns verification here and will run the repository's configured checks."
  [[ "$ROUND_EXIT" == "143" ]] && die "interrupted while isolating"
  after="$(git worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p')"
  new="$(comm -13 <(printf '%s\n' "$before" | sort) <(printf '%s\n' "$after" | sort) | head -1)"

  if [[ -n "$new" && -d "$new" ]]; then
    cd "$new" || { halt isolate_failed "could not enter the new worktree at $new"; return 1; }
    # Identity is checked after the cd rather than assumed from the diff. Another session adding a
    # worktree between the two listings would also show up in it, and `head -1` picks lexicographically
    # rather than causally -- so without this the whole landing could run in someone else's checkout.
    if ! in_linked_worktree || [[ "$(repo_key)" != "$want_key" ]]; then
      halt isolate_failed "the directory that appeared ($new) is not a linked worktree of this
  repository. Refusing to work in it -- a concurrent worktree created by another run would look
  identical from here."
      return 1
    fi
    dim "  isolated at $new ($(branch))"
    return 0
  fi
  # The skill legitimately declines in two documented cases -- a sandbox permission error, and a user
  # who has said no. Continuing is right; continuing while implying isolation would not be, so it is
  # said out loud rather than left to be inferred from the absence of a message.
  say "no worktree was created -- working in place in $(repo_root) on branch $(branch)."
  say "The skill declines when the sandbox refuses or consent is withheld; either way this run will"
  say "edit and commit in this checkout."
  return 0
}

halt() { # <reason> <message>
  HALT="$1"
  printf '%sloop: halted -- %s%s\n' "$c_red" "$1" "$c_off" >&2
  printf '  %s\n' "$2" >&2
}

record() { # <phase> <landing> <round> <outcome> [halt_reason]
  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" \
    phase "$1" landing "$2" round "$3" outcome "$4" \
    halt_reason "${5:-__null__}" \
    gate "{\"ok\":$([[ "${LAST_OK:-0}" == 1 ]] && echo true || echo false),\"check\":\"$(gate_field check)\",\"kind\":\"$(gate_field kind)\"}" \
    fix_now "${FIX_NOW:-0}" needs_decision "${NEEDS_DECISION:-0}" decline "${DECLINE:-0}" \
    cost_usd "${ROUND_COST:-0}" turns "${ROUND_TURNS:-0}" exit "${ROUND_EXIT:-0}" \
    deferred "$(node -e 'const v=process.argv[1];process.stdout.write(JSON.stringify(v?v.split(" ").filter(Boolean):[]))' "${GATE_DEFERRED:-}")" \
    spent_usd "$SPENT" scorer_touched "$(node -e 'const v=process.argv[1];process.stdout.write(JSON.stringify(v?v.split("\n").filter(Boolean):[]))' "${SCORER_HITS:-}")"
}

# Everything that must be checked after any round, in one place. Returns non-zero when the landing
# has to stop, with HALT set.
post_round() { # <phase> <landing> <round>
  SCORER_HITS="$(scorer_touched)"
  if [[ "$ROUND_EXIT" == "143" ]]; then
    halt interrupted "the round was terminated (SIGTERM). Nothing is claimed about the work."
    record "$1" "$2" "$3" halted interrupted; return 1
  fi
  # Every other non-zero exit, not just 143. An API error, a rate limit or a rejected flag used to
  # leave the failure invisible: claude_round swallows stderr and returns 0, so the loop carried on
  # against whatever the round did or did not manage to do.
  if [[ "$ROUND_EXIT" == "124" ]]; then
    halt round_timeout "the $1 round did not return within ${ROUND_TIMEOUT}s and was killed.
  A hang is the one failure the round cap, the budget and the gate all miss, which is why the deadline
  is here. If this repeats, check whether \`claude\` is waiting for a login it cannot get."
    record "$1" "$2" "$3" halted round_timeout; return 1
  fi
  if [[ "$ROUND_EXIT" != "0" ]]; then
    halt round_failed "the $1 round exited $ROUND_EXIT. Nothing is claimed about what it did."
    record "$1" "$2" "$3" halted round_failed; return 1
  fi
  if [[ -n "$SCORER_HITS" ]]; then
    halt scorer_touched "this round edited what judges it: $(printf '%s' "$SCORER_HITS" | tr '\n' ' ')
  Changing the exam has to be a human act. Nothing was reverted -- look, then decide."
    record "$1" "$2" "$3" halted scorer_touched; return 1
  fi
  if gate_gave_up; then
    halt gave_up "the gate recorded a VERDICT and stopped blocking. A released gate is not a green
  one: the work is NOT verified. Read: scripts/gate.sh status"
    record "$1" "$2" "$3" halted gave_up; return 1
  fi
  if node -e 'process.exit(Number(process.argv[1]) > Number(process.argv[2]) ? 0 : 1)' "$SPENT" "$BUDGET_USD"; then
    halt budget "spent \$$SPENT against a budget of \$$BUDGET_USD."
    record "$1" "$2" "$3" halted budget; return 1
  fi
  return 0
}

# One line, because it is passed as an argument rather than written to a file.
triage_schema() {
  printf '%s' '{"type":"object","required":["fix_now","needs_decision","decline"],"properties":{"fix_now":{"type":"integer"},"needs_decision":{"type":"integer"},"decline":{"type":"integer"}}}'
}

# One landing, start to submitted PR. Sets HALT when it stops early.
run_landing() { # <n> <what-lands> <one-way>
  local n="$1" what="$2" oneway="$3" r rr schema
  LAST_OK=0; FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0

  echo
  dim "── landing $n: $what"

  # The layer comes before the work, so the commits land on their own branch. Doing it afterwards would
  # mean moving commits between branches, which is the part of stacking worth not hand-rolling.
  stack_layer "$n" || return 1

  # --- implement, until the gate is green -----------------------------------
  #
  # Round 1 writes the code. Every round after a red gate switches to /systematic-debugging, because
  # da-verify's own closing line says so: "If the same check fails twice in a row, stop patching."
  # Repeating /test-driven-development against a check that already failed is exactly the patching it
  # names -- it piles failed approaches on top of each other, and each attempt is worse than the last.
  # The two skills are not interchangeable: one writes code from an intent, the other refuses to
  # propose a fix before it has a root cause.
  local head_before
  for (( r = 1; r <= MAX_ROUNDS; r++ )); do
    head_before="$(git rev-parse HEAD 2>/dev/null || true)"
    if (( r == 1 )); then
      # Above tier S there is a committed plan, and `executing-plans` is the skill for executing a
      # written plan. Below it there is no plan at all, so TDD is typed directly.
      #
      # NOT `subagent-driven-development`, although upstream recommends it when subagents exist. Its own
      # decision graph routes "Stay in this session? no - parallel session" to executing-plans, and every
      # round here is a fresh `claude -p` process by design. It also instructs "Always specify the model
      # explicitly when dispatching a subagent", which is invariant 10 inverted, and it brings a second
      # ledger, a second fix loop and a second final review alongside the ones this driver already has.
      if [[ -n "$PLAN_PATH" ]]; then
        dim "   round $r: implement (/executing-plans)"
        claude_round "/executing-plans $PLAN_PATH

Execute the landing: $what

Use /test-driven-development for each step -- a failing test first, then the code that makes it pass.
That is not implied: executing-plans delegates to whatever the plan's steps say, so it is stated here.

Do not modify profiles/, hooks/, or anything under scripts/ -- those decide whether your work passes,
and editing them aborts this landing."
      else
      dim "   round $r: implement"
      claude_round "/test-driven-development

Work on this landing: $what

Do not modify profiles/, hooks/, or anything under scripts/ -- those decide whether your work passes,
and editing them aborts this landing. When you believe it is done, stop; something else runs the checks."
      fi
    else
      dim "   round $r: debug ($(gate_field check) is $(gate_field kind))"
      claude_round "/systematic-debugging

The check \`$(gate_field check)\` is $(gate_field kind) after $(( r - 1 )) attempt(s) on this landing: $what

Find the root cause before proposing a fix. Do not patch around it, and do not start over. What was
tried already is in the commits on this branch and in the failing output above.

Do not modify profiles/, hooks/, or anything under scripts/ -- those decide whether your work passes,
and editing them aborts this landing."
    fi
    post_round implement "$n" "$r" || return 1

    # A round that changed nothing has not done the work, and this is the only defence the driver has
    # against the vacuous green. A `{files}`-scoped check is SKIPPED when the tree is clean, and the
    # hook then reports `gate: all gating checks green` -- byte-identical to a real pass, in the JSON
    # and in the prose. Measured, not assumed: `verify --json` on a clean tree with a `{files}`-only
    # profile returns ok:true, check:null, detail:"all gating checks green". So the gate cannot be
    # asked whether anything ran, and the answer has to come from here: if the tree is untouched and
    # HEAD has not moved, whatever green comes back was true before this round started.
    if [[ -z "$(changed_paths)" && "$(git rev-parse HEAD 2>/dev/null || true)" == "$head_before" ]]; then
      halt round_changed_nothing "the $( ((r == 1)) && printf implement || printf debug ) round changed
  nothing -- no edit, no commit. Any green from the gate was already true before it ran, and a
  \`{files}\`-scoped check is skipped entirely on a clean tree, so 'verified' here would mean nothing
  was checked. See docs/fix-plans/2026-08-11-loop-driver.md item A."
      record implement "$n" "$r" halted round_changed_nothing; return 1
    fi

    if gate_verify_ok; then LAST_OK=1; record implement "$n" "$r" advanced; break; fi
    LAST_OK=0
    # "Nothing was checked" is not a red check, and another round cannot turn it into a green one --
    # the check was skipped because the tree is clean, and more rounds do not change that. Halting is
    # the only honest move: the profile cannot verify this landing.
    if [[ -n "$GATE_UNRAN" ]]; then
      halt gate_unran "nothing was checked ($GATE_UNRAN). No gating check ran, so nothing here is
  verified -- and \`gate.sh verify\` reports ok:true for that, which is why this is checked separately.
  A \`{files}\`-scoped check is skipped when the tree is clean; if that is the whole profile, this
  landing has no gate."
      record implement "$n" "$r" halted gate_unran; return 1
    fi
    dim "   round $r: $(gate_field check) is $(gate_field kind)"
    record implement "$n" "$r" held
  done
  if [[ "$LAST_OK" != 1 ]]; then
    halt round_cap "the gate never went green in $MAX_ROUNDS rounds. Last: $(gate_field check) ($(gate_field kind)).
  Repeated correction piles failed approaches on top of each other -- this is the point to read the
  ledger and rewrite the request rather than buy another round."
    record implement "$n" "$MAX_ROUNDS" halted round_cap; return 1
  fi
  commit_landing "$n" "$what" || return 1

  # --- review, capped ------------------------------------------------------
  schema="$(triage_schema)"
  for (( rr = 1; rr <= REVIEW_ROUNDS; rr++ )); do
    dim "   review $rr"
    claude_round "/da-review-all"
    post_round review "$n" "$rr" || return 1
    record review "$n" "$rr" advanced
    REVIEW_REPORT="$(round_result)"

    # A second reviewer, deliberately built differently. Measured on the same 146 pull requests: 93.4%
    # of findings were caught by exactly one of four tools and none by all four, so coverage comes from
    # a different reviewer rather than another pass of this one.
    #
    # Metered on risk, not run every time, because review is where the money goes -- one /da-review-all
    # measured at $1.99 against $0.09 for a trivial round. It runs only where being wrong once is
    # already the incident: the surfaces `size` recorded as risk_surfaces.
    #
    # Its FULL report is carried into triage, not a count. A count would buy zero coverage -- the value
    # is the specific findings the first reviewer missed, and da-fix-plan's own template says
    # "**Source:** which review(s)", plural, so two reports is a shape it already expects.
    SECOND_REPORT=""
    if [[ "$(ledger_last size risk_surfaces)" != "0" && -n "$(ledger_last size risk_surfaces)" ]]; then
      dim "   review $rr: second reviewer (/find-bugs) -- this landing touches a risk surface"
      claude_round "/find-bugs"
      post_round findbugs "$n" "$rr" || return 1
      SECOND_REPORT="$(round_result)"
      record findbugs "$n" "$rr" advanced
    fi

    # Both reports go in, not counts. The review skills write no file, so the process boundary between
    # rounds is where their findings would be lost -- and a count would buy zero coverage, when coverage
    # is the entire reason for a second reviewer. da-fix-plan's own template says "**Source:** which
    # review(s)", plural, so two reports is a shape it already expects.
    claude_round "/da-fix-plan

Triage the review(s) below. Report only the bucket counts. \`fix_now\` counts Fix now plus Fix now
smaller. \`needs_decision\` counts findings that need a human decision. \`decline\` counts what you
decided not to fix.

=== /da-review-all の所見 ===
$REVIEW_REPORT
${SECOND_REPORT:+
=== /find-bugs の所見（2本目のレビュア、意図的に別の作り） ===
$SECOND_REPORT}" "$schema"
    # Absent is not zero. Defaulting a missing count to 0 reads as "the review found nothing to fix",
    # which is the optimistic reading of an answer that never arrived -- and it would submit a PR that
    # was never triaged while the ledger recorded fix_now:0, indistinguishable from a clean review.
    # Not theoretical: the flag was measured (it exists, and it takes an inline schema), but a round can
    # still come back without structured output for any other reason, and 0 is the optimistic reading.
    FIX_NOW="$(round_structured fix_now)"
    NEEDS_DECISION="$(round_structured needs_decision)"
    DECLINE="$(round_structured decline)"
    if [[ -z "$FIX_NOW" || -z "$NEEDS_DECISION" ]]; then
      halt triage_unreadable "the triage round returned no bucket counts (exit $ROUND_EXIT).
  Nothing is claimed about what the review found."
      FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0
      record triage "$n" "$rr" halted triage_unreadable; return 1
    fi
    # Non-numeric is also not zero, and `[[ x -gt 0 ]]` on a non-number exits non-zero under set -u
    # rather than comparing -- which would be a silent pass in the branch below.
    case "$FIX_NOW$NEEDS_DECISION$DECLINE" in
      *[!0-9]*)
        halt triage_unreadable "the triage counts were not numbers (fix_now='$FIX_NOW',
  needs_decision='$NEEDS_DECISION', decline='$DECLINE')."
        FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0
        record triage "$n" "$rr" halted triage_unreadable; return 1 ;;
    esac
    post_round triage "$n" "$rr" || return 1

    if [[ "$NEEDS_DECISION" -gt 0 ]]; then
      halt needs_decision "$NEEDS_DECISION finding(s) need a decision, not a retry. Stopping now
  regardless of remaining budget -- deciding whether to fix comes before deciding how."
      record triage "$n" "$rr" halted needs_decision; return 1
    fi
    record triage "$n" "$rr" advanced
    [[ "$FIX_NOW" -eq 0 ]] && break

    if [[ "$rr" -ge "$REVIEW_ROUNDS" ]]; then
      halt review_cap "$FIX_NOW finding(s) still open after $REVIEW_ROUNDS reviews. A third round
  buys a higher chance of approval, not a higher chance of being right. They are in the ledger."
      record triage "$n" "$rr" halted review_cap; return 1
    fi

    # Through /receiving-code-review, not straight into an editor. That skill exists to stop exactly
    # what a driver would otherwise do here -- implement every finding because it is written down.
    # da-fix-plan already decided WHAT is worth fixing; this decides whether each remedy is actually
    # right, and a finding that does not survive scrutiny goes back as a finding about the review.
    dim "   review $rr: applying $FIX_NOW fix(es)"
    claude_round "/receiving-code-review

Apply the 'Fix now' items from the fix plan at docs/fix-plans/ -- and only those.

Evaluate each one before implementing it. If a finding does not hold up against the actual code, say
so and leave it; a remedy applied because it was written down is the failure this skill is about. Do
not touch profiles/, hooks/, or scripts/."
    post_round fix "$n" "$rr" || return 1
    if gate_verify_ok; then
      LAST_OK=1; record fix "$n" "$rr" advanced; commit_landing "$n" "$what fixes" || return 1
    else
      LAST_OK=0
      halt red_after_fix "the fixes took the gate red: $(gate_field check) ($(gate_field kind)).
  The review's remedy broke something the implementation had passing, which is a finding about the
  remedy."
      record fix "$n" "$rr" halted red_after_fix; return 1
    fi
  done

  # --- the PR ------------------------------------------------------------
  submit_landing "$n" "$what" "$oneway"
}

# Named paths only. `git add -A` is how one round's droppings get committed by the next, and
# check.sh already carries a step about suites that leave the tree dirty.
commit_landing() { # <n> <what>
  tree_readable || { halt tree_unreadable "could not read the working tree, so there is no way to know
  what to commit."; return 1; }
  local paths; paths="$(changed_paths)"
  [[ -n "$paths" ]] || return 0
  # The status of each `git add` matters. Discarding it meant that when the paths could not be resolved
  # -- cwd a subdirectory, a path git no longer recognises -- the index stayed empty and the next line
  # read that as "nothing to do, fine", so the landing continued believing it had committed.
  local add_failed=0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    git add -- "$p" 2>/dev/null || add_failed=1
  done <<<"$paths"
  if (( add_failed )); then
    halt commit_failed "could not stage every changed path for landing $1. Not committing a partial
  set: a commit that silently omits half the work is worse than no commit."
    return 1
  fi
  git diff --cached --quiet 2>/dev/null && return 0
  git commit -qm "loop: landing $1 -- $2" 2>/dev/null || {
    halt commit_failed "could not commit landing $1"; return 1; }
  return 0
}

# One PR per landing, stacked -- landing 2's PR targets landing 1's branch, not the trunk.
#
# Landings are a stack by construction: landing N builds on N-1, and `da-design-review` already
# decided where the divisions are and what gates each one. The first version of this driver kept every
# landing on one branch, which meant the second landing's PR would have collided with the first's.
#
# Stacks are also the answer to the thing that actually kills agent PRs. The measured largest cause of
# rejection is that nobody engaged (inactivity, 17.3% of 33,596 PRs) -- a reviewer facing one large
# diff stalls, and a chain of small ones can be reviewed a layer at a time, starting before the top is
# finished. That is why each landing is submitted as it completes rather than all of them at the end.
stack_ready() { # -> 0 when the gh-stack extension is available
  gh extension list 2>/dev/null | grep -q 'gh-stack'
}

# Establish the stack, or add a layer for this landing. Layer 1 is the branch the user is already on;
# every later layer is a branch this driver creates.
stack_layer() { # <n>
  if [[ "$1" == "1" ]]; then
    # Set on BOTH paths. It used to be assigned only after `gh stack init`, so resuming into an existing
    # stack -- which is the normal state after any halt -- left it empty: layer names then compounded
    # (<l1>-2, then <l1>-2-3) and the open-PR cap counted against whichever branch happened to be
    # checked out, so it could never fire.
    STACK_BASE_BRANCH="$(branch)"
    gh stack view --json >/dev/null 2>&1 && return 0
    # The branch goes in POSITIONALLY. `gh stack init -b <trunk>` with no branch argument asks for one
    # interactively, and headless that is "interactive input required; provide branch names as arguments"
    # -- which is how the first real run halted at landing 1 before implementing anything. An existing
    # branch is adopted rather than recreated, so passing the branch we are already on is the right call.
    gh stack init -b "$(default_branch)" "$STACK_BASE_BRANCH" >/dev/null 2>&1 || {
      halt stack_failed "gh stack init failed"; return 1; }
    return 0
  fi
  gh stack add "${STACK_BASE_BRANCH:-$(branch)}-$1" >/dev/null 2>&1 || {
    halt stack_failed "gh stack add failed for landing $1"; return 1; }
  return 0
}

submit_landing() { # <n> <what> <one-way>
  local open_prs
  if [[ "$3" == "yes" ]]; then
    say ""
    say "landing $1 is a one-way door. Verified and committed on its own layer, not submitted --"
    say "an irreversible change gets a human to press the button. The layers below it are up."
    record pr "$1" 0 halted one_way; return 0
  fi
  # Counted by head branch, not by author: `--author @me` also counts the PRs you opened by hand, and
  # a cap that fires because of your own work is a cap that gets switched off.
  open_prs="$(gh pr list --state open --json headRefName --jq '.[].headRefName' 2>/dev/null \
              | grep -c "^${STACK_BASE_BRANCH:-$(branch)}" || true)"
  open_prs="${open_prs:-0}"
  if [[ "$open_prs" -ge "$MAX_OPEN_PRS" ]]; then
    say ""
    say "$open_prs PRs from this stack are already open, and the cap is $MAX_OPEN_PRS."
    say "Verified and committed, nothing submitted. A stack is meant to be read a layer at a time,"
    say "but it is still output nobody has read yet -- the reviewer is the bottleneck, not the agent."
    record pr "$1" 0 halted pr_cap; return 0
  fi
  tree_readable || { halt tree_unreadable "could not read the working tree, so \"nothing left over\"
  cannot be established before submitting."; record pr "$1" 0 halted tree_unreadable; return 1; }
  [[ -n "$(changed_paths)" ]] && { halt dirty_at_pr "the tree is dirty at PR time"; \
    record pr "$1" 0 halted dirty_at_pr; return 1; }

  gh stack push >/dev/null 2>&1 || { halt push_failed "gh stack push failed"; \
    record pr "$1" 0 halted push_failed; return 1; }
  local url
  # --open, not the default: `gh stack submit` creates drafts, and these layers have already been
  # through the gate and a review pass. --auto because there is no editor to open.
  url="$(gh stack submit --auto --open 2>/dev/null | grep -o 'https://[^ ]*/pull/[0-9]*' | tail -1)"
  [[ -n "$url" ]] || { halt pr_failed "gh stack submit produced no PR URL"; \
    record pr "$1" 0 halted pr_failed; return 1; }
  # The driver makes the shell; the skill writes the body. da-pr-describe's own precondition is that
  # a PR already exists and that it must not create one -- which stays literally true this way.
  local num; num="$(printf '%s' "$url" | sed 's@.*/@@')"
  claude_round "/da-pr-describe $num${GATE_DEFERRED:+

このリポジトリがエージェントに実行を禁じているため、ローカルで検証していないチェックがあります:
  $GATE_DEFERRED

PR 本文にそれを明記してください —— **CI が走らせるまで、その分は未検証**です。}"
  record pr "$1" 0 opened-pr
  say ""
  say "landing $1 -> $url  (layer $1 of the stack, ready for review)"
  return 0
}

parse_plan() { # <path> -> "n<TAB>what<TAB>oneway" per landing row
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    let inTable = false, out = [];
    for (const l of lines) {
      if (/Landing plan/i.test(l)) { inTable = true; continue }
      if (!inTable) continue;
      if (!l.trim().startsWith("|")) { if (out.length) break; else continue }
      const cells = l.split("|").slice(1, -1).map((c) => c.trim());
      if (cells.length < 3) continue;
      if (/^-+$/.test(cells[0]) || /^#$/.test(cells[0]) || /what lands/i.test(cells[1] || "")) continue;
      const oneway = /yes|はい/i.test(cells[3] || "") ? "yes" : "no";
      out.push([cells[0], cells[1], oneway].join("\t"));
    }
    process.stdout.write(out.join("\n"));
  ' "$1" 2>/dev/null || true
}

cmd_run() {
  local want_landing="" plan=""
  # `shift 2` with one argument left shifts NOTHING and returns non-zero, and there is no `set -e`
  # here, so the loop used to spin forever on the same argument. A hang is the one outcome this
  # repository keeps a whole suite about, so the value is required before anything is consumed.
  need_value() { [[ -n "${2:-}" ]] || die "$1 needs a value"; printf '%s' "$2"; }
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --landing)    want_landing="$(need_value "$1" "${2:-}")"; shift; shift ;;
      --max-rounds) MAX_ROUNDS="$(need_value "$1" "${2:-}")"; shift; shift ;;
      --budget-usd) BUDGET_USD="$(need_value "$1" "${2:-}")"; shift; shift ;;
      -*)           die "unknown option: $1" ;;
      *)            plan="$1"; shift ;;
    esac
  done
  # Numeric, or the comparisons that consume them quietly stop working: `[[ x -gt 0 ]]` is false and
  # `Number("x") > n` is false, so a typo would disable the cap and the budget rather than fail.
  case "$MAX_ROUNDS" in ''|*[!0-9]*) die "--max-rounds must be a positive integer (got '$MAX_ROUNDS')" ;; esac
  case "$BUDGET_USD" in ''|*[!0-9.]*) die "--budget-usd must be a number (got '$BUDGET_USD')" ;; esac
  [[ -z "$want_landing" ]] || case "$want_landing" in *[!0-9]*) die "--landing must be a number (got '$want_landing')" ;; esac

  local root branch_now def tier
  root="$(repo_root)"; def="$(default_branch)"
  tree_readable || die "could not read the working tree (\`git status\` failed). Refusing rather than
  reading that as clean -- every consumer of this answer treats empty as benign, so a git failure here
  would look like a tidy starting point."
  [[ -n "$(changed_paths)" ]] && die "the working tree is not clean. Commit or stash first -- a loop that
  starts on top of uncommitted work cannot tell its own changes from yours."

  # A hard dependency, checked up front. Falling back to `gh pr create` would produce one unstacked PR
  # per landing, all targeting the trunk -- a different shape of output than the one asked for, with
  # nothing saying so. Stacked PRs are in public preview, so this can also disappear from under us.
  stack_ready || die "the gh-stack extension is not installed, and landings are submitted as a stack.

  gh extension install github/gh-stack

  Not falling back to a plain \`gh pr create\`: that would put every landing's PR on the trunk and
  silently drop the layering the review depends on."

  # Inputs are validated before anything with a side effect runs. Isolation creates a worktree and
  # arming touches the gate; refusing a bad plan afterwards means having done both for nothing, and the
  # committed plan reads identically from either checkout, so there is no reason to wait.
  tier="$(ledger_last size tier)"
  [[ -n "$tier" ]] || die "no size recorded for this repository. Run: loop.sh size \"<what you want>\"
  The tier decides whether this may run unattended at all, and it is not a thing to skip past."

  if [[ "$tier" != "S" ]]; then
    [[ -n "$plan" ]] || die "tier $tier requires a committed landing plan: loop.sh run <plan-path>
  Tier $tier means a human goes through the design phase first. See docs/loops.md."
  fi
  # Validated whenever one was supplied, at every tier. The tier decides whether a plan is REQUIRED; it
  # does not decide whether a supplied one gets checked. Tier S used to skip all of this and then hand
  # the same unvalidated path to parse_plan, so an uncommitted -- unapproved -- plan ran end to end.
  if [[ -n "$plan" ]]; then
    [[ -f "$plan" ]] || die "no such landing plan: $plan"
    git ls-files --error-unmatch -- "$plan" >/dev/null 2>&1 \
      || die "the landing plan is not committed. Committing it is how a human says they approved it --
  there is no approval flag, because a flag is something you type without reading."
    git diff --quiet -- "$plan" 2>/dev/null \
      || die "the landing plan has uncommitted changes. A plan edited after its commit is not the plan
  that was approved."
  fi
  PLAN_PATH="$plan"

  isolate || return 1

  # After isolation, not before: a fresh worktree comes with its own branch, so this check is about
  # where the work will actually land rather than where the command was typed.
  branch_now="$(branch)"
  case "$branch_now" in
    "$def"|main|master|develop)
      die "on the default branch ($branch_now). Branch first; the loop pushes and opens a PR." ;;
  esac

  # Checked before anything arms the gate. `gate.sh arm` moves an existing VERDICT to VERDICT.prev and
  # restarts the attempt budget -- correct for a human starting a fresh session, and wrong to do
  # silently here: the verdict is the one record that exists so an unverified state cannot be mistaken
  # for a pass, and an unattended run that erases it on the way in has destroyed the evidence it most
  # needed to read.
  if gate_gave_up; then
    printf 'loop: the last gate here ended in a verdict, not a pass.\n' >&2
    bash "$GATE_SH" status >&2 2>/dev/null || true
    die "that work was NOT verified. Read the verdict and deal with it before starting another
  unattended run -- arming would erase it."
  fi

  # The expensive precondition goes last, after every cheap refusal above: one verify costs a full
  # suite, and it is not worth paying for before a missing tier or an unapproved plan has had its
  # chance to stop this. `gate.sh verify` is the state-free probe -- da-verify's own Step 3 says to use
  # it and that it can be run as often as you like -- so reading it here duplicates no rule.
  dim "checking the gate before starting ..."
  if gate_verify_ok; then STARTED_GREEN=1; else STARTED_GREEN=0; fi
  gate_has_profile || die "no profile matches this repository, so there are no gating checks -- and
  \`gate.sh verify\` answers ok:true when nothing matched. An unchecked repository is not a green one.
  Run /da-verify to get a profile written, then come back."
  [[ "$STARTED_GREEN" == 1 ]] \
    && dim "  starting green" \
    || dim "  starting red: $(gate_field check) ($(gate_field kind)) -- inherited, not caused by this run"

  # Arming goes through the skill, by typing it. `da-verify` is the only thing that runs `gate.sh arm`
  # (AGENTS.md invariant 2), and that is not a formality: it is also the step that reports the evidence
  # table, delegates the checks this repository forbids the agent from running, and refuses when no
  # profile matches. A driver that called `gate.sh arm` itself would get the arming and none of that --
  # which is what the first version of this did, and then the invariant was reworded to permit it.
  # Bending the invariant to fit the code is the wrong direction.
  dim "arming the gate through /da-verify ..."
  claude_round "/da-verify"
  if [[ "$ROUND_EXIT" == "143" ]]; then die "interrupted while arming the gate"; fi

  local rows req
  if [[ "$tier" == "S" && -z "$plan" ]]; then
    # Tier S has no landing plan by design -- README's own standing rule is that a change you can
    # describe in one sentence skips the plan. The sentence is the request `size` was given, read back
    # from the ledger so the landing is named by what was asked for rather than by a placeholder.
    req="$(ledger_last size request)"
    rows="$(printf '1\t%s\tno' "${req:-the sized change}")"
  else
    rows="$(parse_plan "$plan")"
    [[ -n "$rows" ]] || die "no landing rows found in $plan. An absent table means nobody decided how
  this splits into changes to ship."
  fi

  local n what oneway attempted=0
  while IFS=$'\t' read -r n what oneway; do
    [[ -n "$n" ]] || continue
    [[ -n "$want_landing" && "$n" != "$want_landing" ]] && continue
    attempted=$((attempted+1))
    HALT=""
    run_landing "$n" "$what" "$oneway"
    [[ -n "$HALT" ]] && break
  done <<<"$rows"

  echo
  if [[ -n "$GATE_DEFERRED" ]]; then
    say "ローカルで検証していないチェック: $GATE_DEFERRED"
    say "  このリポジトリがエージェントに実行を禁じているものです（走らせていません）。**CI が gate です** ——"
    say "  merge 前にそこが緑であることを確認してください。ローカルのゲートは、走らせて良いものだけを見ました。"
  fi
  dim "spent \$$SPENT across $attempted landing(s). scripts/loop.sh report"
  [[ -n "$HALT" ]] && return 1
  return 0
}

# ---------------------------------------------------------------- report
cmd_report() {
  [[ -f "$LEDGER" ]] || { say "no ledger yet at $LEDGER"; return 0; }
  local as_json=0; [[ "${1:-}" == "--json" ]] && as_json=1
  node -e '
    const fs = require("fs");
    const [ledger, repo, asJson] = process.argv.slice(1);
    const rows = fs.readFileSync(ledger, "utf8").split("\n").filter((l) => l.trim())
      .map((l) => { try { return JSON.parse(l) } catch { return null } })
      .filter((o) => o && o.repo === repo);
    const byPhase = {}, landings = new Set(), accepted = new Set(), halts = {};
    let total = 0, rounds = 0;
    for (const r of rows) {
      const c = Number(r.cost_usd) || 0;
      total += c;
      byPhase[r.phase] = (byPhase[r.phase] || 0) + c;
      if (r.phase === "size") continue;
      if (r.landing != null) landings.add(String(r.landing));
      if (r.outcome === "opened-pr") accepted.add(String(r.landing));
      if (r.halt_reason) halts[r.halt_reason] = (halts[r.halt_reason] || 0) + 1;
      if (r.phase === "implement") rounds++;
    }
    const n = landings.size, a = accepted.size;
    const money = (x) => "$" + x.toFixed(2);
    if (asJson === "1") {
      process.stdout.write(JSON.stringify({
        landings_attempted: n, reached_pr: a,
        acceptance_rate: n ? a / n : null,
        cost_total_usd: total, cost_per_accepted_usd: a ? total / a : null,
        implement_rounds: rounds, rounds_per_landing: n ? rounds / n : null,
        cost_by_phase: byPhase, halted: halts,
      }, null, 2) + "\n");
    } else {
      const pct = n ? Math.round((a / n) * 100) : 0;
      console.log(`landings attempted      ${n}`);
      console.log(`reached PR              ${a}   (${pct}%)`);
      console.log(`cost per accepted       ${a ? money(total / a) : "--"}`);
      console.log(`rounds per landing      ${n ? (rounds / n).toFixed(1) : "--"}`);
      const phases = Object.keys(byPhase).map((k) => `${k} ${money(byPhase[k])}`).join(" / ");
      console.log(`cost by phase           ${phases || "--"}`);
      const h = Object.keys(halts).map((k) => `${k} ${halts[k]}`).join(", ");
      console.log(`halted                  ${h || "nothing"}`);
      if (n && a / n < 0.5) {
        console.log("");
        console.log("Acceptance is under 50%: the loop is handing review work back to you rather than");
        console.log("taking it off you. Read the halt reasons before buying more rounds.");
      }
    }
  ' "$LEDGER" "$(repo_key)" "$as_json"
}

cmd_status() {
  local tier; tier="$(ledger_last size tier)"
  if [[ -n "$tier" ]]; then
    say "last size    tier $tier  ($(ledger_last size files) files, $(ledger_last size layers) layers, $(ledger_last size unconfirmed) unconfirmed)"
  else
    say "last size    (never sized -- run: loop.sh size \"<what you want>\")"
  fi
  say "ledger       $LEDGER"
  echo
  bash "$GATE_SH" status 2>/dev/null || true
}

# ---------------------------------------------------------------- dispatch
case "${1:-}" in
  ''|-h|--help|help) usage ;;
  size)   shift; cmd_size   "${1:-}" ;;
  design) shift; cmd_design ;;
  run)    shift; cmd_run    "$@" ;;
  report) shift; cmd_report "${1:-}" ;;
  status) shift; cmd_status ;;
  # Not a subcommand? Then it is what you want done. This is the entry point people actually use, so it
  # is the default rather than something to remember a verb for.
  -*)     printf 'loop: unknown option: %s\n\n' "$1" >&2; usage >&2; exit 1 ;;
  *)      cmd_auto "$1" ;;
esac
