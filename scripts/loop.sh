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
# 3, not 6. **6 was unreachable in the case a cap exists for.** The gate's `max_attempts` is 3 and
# `attempts` rises by TWO per turn -- one for the block, one for the re-entry release -- so a check that
# keeps failing gets a VERDICT after about two rounds and `gate_gave_up` halts the landing there. The
# driver's own cap could only ever fire when *different* checks failed on successive rounds, which is the
# case where more rounds are least likely to help: the work is not converging on anything.
# A cap you cannot hit is not a cap; it is a number that reads like one.
MAX_ROUNDS=3          # implementation attempts per landing before handing back
REVIEW_ROUNDS=2       # review passes at tier M/L; the third would buy approval, not correctness
REVIEW_ROUNDS_LEAN=1     # tier S: a ceiling on the worst case, not a cut in review depth (see run_landing)
MAX_OPEN_PRS=5        # open layers in one stack; the reviewer is the bottleneck, not the agent
# **15, and this one is arithmetic rather than a preference.** Measured maxima per phase, all from this
# repository's ledger: size $0.74 · implement $4.56 · review $2.07 (cut off, so the true figure is higher)
# · triage $0.74 · fix $1.19 · describe $1.50 (ceiling, never yet reached). That sums to **$10.8 before a
# single CI fix round**, so a $10 run could not complete one landing however well each phase behaved --
# and did not: run 7 spent $9.18 and stopped at CI, run 8 spent $7.77 and stopped at review.
#
# The number that actually needs bringing down is `implement` ($0.83 -> $4.56 across six runs, unbounded).
# Raising the run budget buys the loop the chance to finish a landing; it does not make anything cheaper,
# and it is recorded here as the honest cost of one tier S landing rather than as a target.
BUDGET_USD=15         # per `run` invocation

# Per-ROUND ceilings. $BUDGET_USD above bounds the run; until these existed nothing bounded a single
# round, so one phase could eat the whole run's budget and the halt would name `budget` -- true, and
# useless, because it does not say which round did it.
#
# Review is that round. Two consecutive landings: /da-review-all at $5.64 and $6.19 against $1.30 and
# $1.50 for the implementations being reviewed, and both times the run halted on `budget` at triage,
# one step short of the PR. The numbers below are chosen, not measured: they sit above what a review
# of that tier should now cost with the brief form (skills/_shared/review-process-brief.md) and below
# what an unbounded one demonstrably does.
BUDGET_ROUND_REVIEW=5.00     # tier M/L
BUDGET_ROUND_REVIEW_LEAN=3.00   # tier S -- the tier that exists because it is meant to cost less.
# **3.00, measured -- and raised twice, because chasing the spread does not work.** Six tier S reviews:
# $1.25 / $1.22 / $1.40 / $0.88 / $1.43 / $2.07. The last one was CUT OFF at a 2.00 ceiling, so its true
# cost is higher than it reads. 1.50 was outrun in one run; 2.00 in two.
#
# **The spread grows because the FILE grows, not because the change does.** Every one of those runs was
# the same request shape -- one file, `docs/loops.md` -- and a review reads the file the changed lines sit
# in, not just the lines. So the honest fix is not a bigger number: it is a smaller file, and the 206-line
# measurement log has been moved to `docs/loop-measurements.md` for exactly that reason. 3.00 buys room
# while that takes effect; if it is outrun again, raise the *question*, not the ceiling.
#
# Raising it does not weaken anything: `truncated` still halts loudly, and the only thing 2.00 buys is
# that a normal run stops hitting the wall. It is still well under the $5.92 average this phase cost
# before the brief form, the tool grant and the subagent removal.
BUDGET_ROUND_TRIAGE=3.00     # tier M/L
BUDGET_ROUND_TRIAGE_LEAN=0.75   # measured at $2.08 and $1.90 to count three buckets on an 11-line diff
BUDGET_ROUND_FINDBUGS=3.00   # the second reviewer, tier M/L
BUDGET_ROUND_FINDBUGS_LEAN=1.50 # tier S
# `size` runs before any tier is known, so it gets one number. Measured at $1.68 / $1.72 / $1.98 across
# three measurements in one session -- 37% of that session's total spend on deciding how much process to
# buy. Measuring is allowed to cost something; it is not allowed to cost more than the work.
BUDGET_ROUND_SIZE=1.25
# MEASURED ONCE, at $1.55 -- and raised on the asymmetry, not on the number. The first end-to-end run
# (2026-08-19, tier XS) had `/da-pr-describe` cut off at $1.50, and the PR opened with the template
# UNFILLED: no summary, no verification, and unchecked boxes that claim nothing. Too low costs the
# entire body and the landing continues anyway (`opened-pr-partial-body` does not halt); too high costs
# money and says so out loud, because a ceiling overrun surfaces as `truncated`. One sample cannot pick
# a number -- this repository's own note says deciding from one sample always misses -- so the value is
# taken from its sibling round rather than from $1.55 + a guess.
BUDGET_ROUND_PR=2.50         # writing one PR body; same as COMMENTS, which is the same kind of work
BUDGET_ROUND_CI=2.00         # one attempt at a red CI
BUDGET_ROUND_COMMENTS=2.50   # addressing a round of human review comments
BUDGET_ROUND_REPLY=1.00      # composing the replies (posting is the driver's job, not the round's)

# What happens after the PR is open.
CI_ATTEMPTS=2         # fix attempts for a red CI before it becomes a human's problem
CI_WAIT_SECONDS="${DOTAGENTS_LOOP_CI_WAIT:-900}"    # how long to wait for pending checks to settle
CI_GRACE_SECONDS="${DOTAGENTS_LOOP_CI_GRACE:-120}"  # how long to wait for checks to EXIST after a push

# **The tier S numbers are tight on purpose, and what makes that safe is that overrun is now LOUD.**
# Before `truncated` existed, a ceiling could only be set generously: a round cut off mid-report returned
# exit 0 with a partial answer, was recorded `advanced`, and its half-written findings went to triage as
# though finished -- so a tight ceiling bought a silently worse review. Now hitting one halts the landing
# and says so in the ledger. That inverts the risk: too tight costs a visible halt and a number to raise,
# where too loose costs $6.19 and a run that dies before the PR. Both measured runs did the latter.
#
# What is NOT being cut to reach these: the five always-covered clusters, the 80-point threshold, and the
# one fresh verifier. Those live in the review skills, and `review-process-brief.md` keeps all three.

# Measured against claude 2.1.148, not assumed: `--json-schema` exists, and it takes the schema as an
# INLINE JSON STRING. Handing it a file path does not error -- it HANGS, with stdin closed, forever.
# That is why the deadline below is not optional: the two phases that ask for structured output would
# have hung on first real use, and a hang is the one failure neither the round cap, the budget nor the
# gate can stop.
SCHEMA_FLAG="--json-schema"

# Measured, not assumed: `claude --print --permission-mode acceptEdits` cannot run git in an unattended
# run. `git status --short` came back "This command requires approval", and headless there is nobody to
# approve -- so it is denied. `/da-review-all`'s Step 1 IS `git diff`, which means **the review phase
# never established its scope**: the two landings that reached it burned 50 turns and $5.64 / $6.19
# retrying against a permission wall, not reviewing deeply. `echo` and `Read` were allowed; `Glob` was
# not available either.
#
# READ-ONLY BY ENUMERATION, deliberately. `Bash(git:*)` is one token shorter and would hand an
# unattended round `git push`, `git reset --hard` and `git branch -D` in order to let it run `git diff`.
# The loop does its own committing, branching and pushing from bash, so no round needs to write.
#
# `--allowedTools` ADDS permissions; it is not an allowlist that removes the rest, so Edit and Write
# still work under acceptEdits. Verified in `claude --help`: "list of tool names to allow".
#
# EVERY ENTRY IS LISTED TWICE, bare and `rtk`-prefixed, and that is not belt-and-braces. Measured:
#
#   --allowedTools "Bash(git status:*)"      -> DENIED, "This command requires approval"
#   --allowedTools "Bash"                    -> ran
#   --allowedTools "Bash(rtk git status:*)"  -> ran
#
# A command-rewriting PreToolUse hook runs BEFORE the permission match, so on a machine whose hook
# rewrites `git status` to `rtk git status` the bare pattern matches nothing -- silently, which is the
# same shape as having passed no grant at all. The first version of this line shipped bare-only and was
# therefore a no-op on the machine it was written on.
#
# Both forms, statically, rather than detecting the hook: this toolkit has to work on a machine that
# has no rtk, and a list that is built by probing is a list that is wrong in a new way when the probe
# is wrong. An unmatched pattern costs nothing.
ROUND_ALLOWED_TOOLS="Bash(git diff:*),Bash(git log:*),Bash(git show:*),Bash(git status:*),Bash(git rev-parse:*),Bash(git symbolic-ref:*),Bash(git ls-files:*),Bash(git diff-tree:*),Bash(gh pr view:*),Bash(rtk git diff:*),Bash(rtk git log:*),Bash(rtk git show:*),Bash(rtk git status:*),Bash(rtk git rev-parse:*),Bash(rtk git symbolic-ref:*),Bash(rtk git ls-files:*),Bash(rtk git diff-tree:*),Bash(rtk gh pr view:*),Grep,Glob"

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
  # `ok: true` is not "verified": a check that never executed reports the same thing as one that
  # passed. `verify --json` now carries `checked` -- true only when at least one gating check actually
  # ran a command -- so this asks instead of matching sentences. `checked: null` means the gate could
  # not say, which is not a yes.
  #
  # This used to grep for the prose "nothing blocking" and a long comment here called it "the SECOND
  # prose coupling to the gate's output". Both couplings are gone; the field is the answer now.
  case "$(gate_json_field checked)" in
    true) GATE_UNRAN="" ;;
    false) GATE_UNRAN="$(gate_json_field skipped_ids)"; GATE_UNRAN="${GATE_UNRAN:-skipped}"; return 1 ;;
    *) GATE_UNRAN="unreadable"; return 1 ;;
  esac

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
# trusted. `verify --json` now reports the resolved profile path, or null when nothing matched. This
# used to grep for the string "no profile matches"; that was the FIRST of two prose couplings and it
# is gone with the second.
#
# It reads the LAST verify rather than running its own. Running one costs a full suite -- minutes on
# this repository -- and the first version did that on top of the implement loop's own first verify,
# so every `run` paid for two complete suite runs before any work started. Call gate_verify_ok first.
gate_has_profile() {
  [[ -n "${GATE_JSON:-}" ]] || return 1     # empty is "I could not tell", not "yes"
  [[ -n "$(gate_json_field profile)" ]]
}

# One reader for the sidecar fields, so nothing goes back to matching sentences. `skipped_ids` is
# synthesised: the ids of every check the gate declined to run, space-separated, for a halt message
# that can name them.
gate_json_field() { # <checked|profile|ran|skipped_ids> -> value, empty when absent or unreadable
  node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      let o = null; try { o = JSON.parse(s) } catch {}
      if (!o) return;
      const f = process.argv[1];
      if (f === "skipped_ids") {
        const a = Array.isArray(o.skipped) ? o.skipped : [];
        process.stdout.write(a.map((x) => x && x.id).filter(Boolean).join(" "));
        return;
      }
      const v = o[f];
      if (v != null) process.stdout.write(String(v));
    });
  ' "$1" <<<"${GATE_JSON:-}" 2>/dev/null || true
}

gate_gave_up() { # -> 0 when a VERDICT has been recorded
  bash "$GATE_SH" status --json 2>/dev/null | node -e '
    let s = "";
    process.stdin.on("data", (d) => s += d).on("end", () => {
      try { process.exit(JSON.parse(s).gave_up ? 0 : 1) } catch { process.exit(1) }
    });
  '
}

# Says, where the loop gives up, whether the check it gave up on is the one that was already failing
# before it started. Without this the two read identically, and the expensive case -- somebody else's
# breakage burning every round -- looks exactly like the landing's own failure. Deliberately silent when
# the names differ: a run that started red on A and died on B did break B, and excusing that would turn
# a useful sentence into an alibi the driver hands itself.
inherited_note() {
  [[ -n "${STARTED_RED_CHECK:-}" ]] || return 0
  [[ "$(gate_field check)" == "$STARTED_RED_CHECK" ]] || return 0
  printf '\n  This check was ALREADY RED before the run started -- the loop did not break it. It may be what
  you asked to fix, or breakage the landing inherited; either way no number of rounds here turns it
  green, and the work is not verified against it.'
}

# ---------------------------------------------------------------- rounds
SPENT=0
GATE_UNRAN=""
GATE_DEFERRED=""
ROUND_TIMED_OUT=0
REVIEW_REPORT=""
SECOND_REPORT=""
ROUND_COST=0; ROUND_TURNS=0; ROUND_EXIT=0; ROUND_OUT=""
ROUND_BUDGET=""       # per-round ceiling in USD; empty means unbounded. Set by the caller, cleared here.
ROUND_TRUNCATED=""    # the subtype that cut the round off; EMPTY means it ran to completion. Not `0` --
                      # this is read with `-n`, and the string "0" is not empty, so a `0` here would
                      # halt every round the moment anything reached post_round without a claude_round.

# One `claude -p`. Never --bare: that switch turns off hooks, skills and CLAUDE.md, which is the
# whole mechanism here -- the official docs recommend it for scripted calls and for this loop it is
# the one fail-open in the manual. Never --dangerously-skip-permissions either; acceptEdits plus the
# profile's `forbidden` list plus the scorer check is the containment.
claude_round() { # <prompt> [inline-schema-json]
  local prompt="$1" schema="${2:-}" raw out pid t
  # An ARRAY, not a string expanded unquoted. The tool grant contains spaces and parentheses
  # (`Bash(git diff:*)`), and word-splitting would hand `claude` the fragments `Bash(git` and `diff:*)`
  # -- two grants that match nothing, silently, leaving git denied exactly as before. Indexed arrays and
  # `+=` are bash 3.2, so this stays macOS-safe; the associative kind would not be.
  local args
  # ORDER IS LOAD-BEARING. `--allowedTools` is variadic (`<tools...>`), so it keeps consuming arguments
  # until the next flag -- and the prompt is the final argument. Left last, the prompt is swallowed as
  # one more tool name and `claude` exits 1 with "Input must be provided either through stdin or as a
  # prompt argument", having spent nothing: $0, 0 turns, and a phase that looks like it declined.
  #
  # It shipped that way for a day and only half the loop was broken, which is why it was not obvious:
  # `--max-budget-usd` happened to terminate the list, so every round WITH a ceiling worked (size,
  # review, triage, pr) and every round without one did not (isolate, verify, implement, debug, fix).
  # `--permission-mode` now always follows the grant, so the terminator is unconditional.
  args=(--print --output-format json)
  args+=(--allowedTools "$ROUND_ALLOWED_TOOLS")
  args+=(--permission-mode acceptEdits)
  # This build has no --max-turns; --max-budget-usd is the only per-round ceiling the CLI offers, and it
  # is the better one anyway -- it bounds what is actually being complained about, and the harness
  # enforces it rather than the prompt. Verified against `claude --help`: the only --max* flag present.
  [[ -n "$ROUND_BUDGET" ]] && args+=(--max-budget-usd "$ROUND_BUDGET")
  [[ -n "$schema" ]] && args+=("$SCHEMA_FLAG" "$schema")
  out="$(mktemp "${TMPDIR:-/tmp}/dotagents-loop-round.XXXXXX")" || die "mktemp failed"

  # Bounded, and stdin closed. macOS has no `timeout`, so this polls the way
  # scripts/test-non-interactive.sh does. stdin is closed because a `claude` whose credentials have
  # expired will otherwise sit waiting for a login it can never get in an unattended run.
  claude "${args[@]}" "$prompt" >"$out" 2>/dev/null </dev/null &
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

  # A round that stopped early exits 0 and returns a PARTIAL `result`. Until this existed the driver read
  # only cost and turns, so a review cut off mid-report was recorded `advanced` and its half-written
  # findings were handed to triage as though they were finished ones -- and nothing downstream could
  # tell, because the model does not know it was cut off either, so its own 🔎 does not say so.
  #
  # DENY by default: any subtype that is not "success" is a truncation, including one invented by a
  # later CLI version. An allowlist of the failures known today starts silently accepting new ones.
  # ABSENCE is success -- some builds omit the field entirely, and treating missing as failure would
  # halt every round on those.
  ROUND_TRUNCATED="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try { const o = JSON.parse(s);
      const bad = (o.subtype != null && o.subtype !== "success") || o.is_error === true;
      process.stdout.write(bad ? String(o.subtype ?? "is_error") : "") }
    catch { process.stdout.write("") }})' <<<"$raw")"
  ROUND_BUDGET=""   # one round, one ceiling. A leaked ceiling would silently cap the next phase too.
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
# Two axes, not one. **How big** the change is decides how much process it needs; **whether one step
# cannot be taken back** decides whether a human must see it. The first version mixed them and the
# ladder collapsed: `risk_surfaces > 0` and `unconfirmed > 0` each forced L on their own, and on a real
# repository almost every backend change touches authorization while /da-investigate names something
# unconfirmed essentially always. So everything was L, nothing ran unattended, and the tier carried no
# information -- a classifier whose every input maps to one class.
#
# What moved, and why each was wrong rather than merely strict:
#
#   `risk_surfaces` was charged TWICE. It already buys the second reviewer below (/find-bugs runs only
#   when it is non-zero). Spending the same measurement on the attended design phase as well is paying
#   for one signal out of two budgets. It now sets a floor of M.
#
#   `unconfirmed` means "this measurement is not reliable". That is a reason not to run unattended, and
#   it is NOT evidence the change is wide or irreversible -- which is what L buys a human for. Its own
#   definition was already fixed once to permit an empty list (#35) and it still returned 9 for a
#   one-file docs edit, so the threshold was wrong too, not just the wording. Floor of M.
#
#   `one_way` still forces L, and this one is not up for revision. An irreversible step is exactly the
#   thing that must not ship without somebody looking at it.
# dotagents:tier-ladder XS S M L
# ^ THE DECLARED LADDER. `scripts/test-loop.sh` reads this line and asserts that every predicate below
# answers every tier on it. Removing the marker removes the check, which is why it is called out here
# the same way the dmi-gate markers are in AGENTS.md.
#
# WHY PREDICATES AND NOT `[[ "$tier" == "S" ]]`. Seven sites used to compare the tier letter, and each
# meant something DIFFERENT: may this run without a plan / is there a design phase to print / does the
# interview apply / may the review dispatcher be skipped / which budgets / does a plan become required /
# is a landing row synthesised. A string comparison accepts any tier and does something plausible with
# it: `!= "S"` is true for a tier that has not been invented yet, and the plausible thing it does is
# demand a landing plan that will never exist. This repository's record says adding a tier "broke three
# places silently"; these are those places, plus a fourth (`tier_needs_interview`) that was missed when
# the list was first drawn up.
#
# Every predicate is a `case` whose `*)` arm DIES. A tier no predicate answers is a tier whose behaviour
# is a guess, and a guess about whether work needs human approval is not a thing to fail open on.
tier_die() { # <tier> <predicate>
  die "unknown tier '$1' in $2. The ladder is declared on the dotagents:tier-ladder line in this file,
  and every predicate has to answer every tier on it. A tier that falls through is a tier whose
  behaviour would be a guess."
}

# May a landing run with no committed 🧱 Landing plan? Deliberately a separate name from
# tier_has_design_phase even though the answers match today: :730 asks "can this proceed", :798 asks
# "is there a phase to print", and a future rung could answer those differently.
tier_needs_landing_plan()      { case "$1" in XS|S) return 1 ;; M|L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
tier_has_design_phase()        { case "$1" in XS|S) return 1 ;; M|L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# /grill-me and /research: an interview needs somebody in the room, so only the top rung prints them.
tier_needs_interview()         { case "$1" in XS|S|M) return 1 ;; L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
tier_synthesises_landing_row() { case "$1" in XS|S) return 0 ;; M|L) return 1 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# One known layer and a small change: type the layer skill, skip the cross-layer dispatcher.
review_may_skip_dispatcher()   { case "$1" in XS|S) return 0 ;; M|L) return 1 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# THE ONE THING XS DROPS. A review still runs -- nothing ships unreviewed -- but its findings are not
# taken to /da-fix-plan and no /receiving-code-review round applies them. What that buys: triage ($0.7)
# + fix ($1.2) + a second full gate run. What it costs is in the notes below, and the cost is why the
# report is written to disk before the PR round rather than living only in a prompt argument.
tier_runs_fix_loop()           { case "$1" in XS) return 1 ;; S|M|L) return 0 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }
# Which tiers get the lean review allocation. THIS WAS AN INLINE `case` for one landing, and the
# exhaustiveness test -- which finds predicates by name -- could not see it. So it was the single place
# XS was not armed, and 61 assertions died on it. A decision the tests cannot enumerate is a decision
# that will be forgotten exactly once per new tier.
tier_gets_lean_budgets()       { case "$1" in XS|S) return 0 ;; M|L) return 1 ;; *) tier_die "$1" "${FUNCNAME[0]}" ;; esac; }

decide_tier() {
  TIER=XS
  if [[ "$M_FILES" -gt 5  || "$M_UNCONF" -gt 0 ]];                     then TIER=S; fi
  if [[ "$M_FILES" -gt 10 || "$M_LAYERS" -ge 2 || "$M_RISK" -gt 0 ]];  then TIER=M; fi
  if [[ "$M_FILES" -gt 30 || "$M_LAYERS" -ge 3 || "$M_ONEWAY" -gt 0 ]]; then TIER=L; fi
}

cmd_size() {
  local request="${1:-}"
  [[ -n "$request" ]] || die "size needs the request: loop.sh size \"<what you want>\""
  # Inline, not a file. `--json-schema` takes the schema as a string; a path makes the CLI hang.
  local schema
  schema='{"type":"object","required":["files","layers","one_way","risk_surfaces","unconfirmed","unverified_claims"],'
  schema="$schema"'"properties":{"files":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"layers":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"one_way":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"risk_surfaces":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"unconfirmed":{"type":"array","items":{"type":"string"}},'
  schema="$schema"'"unverified_claims":{"type":"array","items":{"type":"string"}}}}'

  dim "measuring with /da-investigate (ceiling \$$BUDGET_ROUND_SIZE) ..."
  ROUND_BUDGET="$BUDGET_ROUND_SIZE"
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
see it.

\`unverified_claims\` is the OTHER thing, and it has its own field so it stops landing in the one above:
assertions THE REQUEST ITSELF makes that you could not verify -- \"the ledger has no such entry\", \"the
count is 105\", \"this is no longer true\". These say the request needs fixing, not that the change is
big. **A request full of unverified claims about a one-line edit is still a one-line edit.** Put each
such claim here and none of them under \`unconfirmed\`; this field does not affect the tier." \
    "$schema"

  local files layers oneway risk unconf claims
  # Asked BEFORE the missing-measurement check, because a cut-off round produces no structured output
  # either -- and the two diagnoses send you to different places. Blaming the schema flag for a round
  # that ran out of budget is a full detour into the CLI for a problem whose fix is a number in this file.
  # `size` does not go through post_round, so this is the only place it can be caught.
  [[ -z "$ROUND_TRUNCATED" ]] || die "the size round was cut off (subtype: $ROUND_TRUNCATED) after
  \$$ROUND_COST and ${ROUND_TURNS} turns, against a ceiling of \$$BUDGET_ROUND_SIZE. No measurement was
  produced, and a truncated one would not be a measurement either.

  Raise BUDGET_ROUND_SIZE, or narrow the request -- a request carrying many claims to verify makes the
  measurer work through all of them (that is what \`unverified_claims\` records)."
  round_has_structured || die "no measurement came back (exit $ROUND_EXIT). Check that \`$SCHEMA_FLAG\`
  is the right flag for structured output on this version of the CLI.

  Not falling back to a guess: sizing is the step that decides whether this may run unattended at all,
  and an unmeasured change treated as small is the worst outcome available here."
  files="$(round_structured files)"; layers="$(round_structured layers)"
  oneway="$(round_structured one_way)"; risk="$(round_structured risk_surfaces)"
  unconf="$(round_structured unconfirmed)"; claims="$(round_structured unverified_claims)"

  count() { node -e 'const v=process.argv[1];process.stdout.write(String(v?v.split(",").filter(Boolean).length:0))' "$1"; }
  M_FILES="$(count "$files")"; M_LAYERS="$(count "$layers")"
  M_ONEWAY="$(count "$oneway")"; M_RISK="$(count "$risk")"; M_UNCONF="$(count "$unconf")"
  M_CLAIMS="$(count "$claims")"
  decide_tier

  # The layer NAMES, not just how many. `run` uses them to skip the review dispatcher when there is
  # exactly one and the toolkit has a skill for it -- a count cannot answer "which one".
  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" phase size \
    request "$request" \
    tier "$TIER" files "$M_FILES" layers "$M_LAYERS" one_way "$M_ONEWAY" \
    risk_surfaces "$M_RISK" unconfirmed "$M_UNCONF" unverified_claims "$M_CLAIMS" \
    layer_names "$layers" \
    cost_usd "${ROUND_COST:-0}" turns "${ROUND_TURNS:-0}" exit "$ROUND_EXIT" \
    outcome sized halt_reason __null__
  consume_round_numbers   # this row is the size round's only row -- see `consume_round_numbers`

  echo
  say "tier $TIER"
  say "  files $M_FILES · layers $M_LAYERS · one-way $M_ONEWAY · risk surfaces $M_RISK · unconfirmed $M_UNCONF"
  # Printed separately because it does NOT move the tier, and putting it on the line above invites
  # exactly the conflation the field exists to end.
  [[ "$M_CLAIMS" -gt 0 ]] && say "  依頼文に未確認の主張 $M_CLAIMS 件（段には影響しません。依頼文の方を直す材料です）"
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

  if ! tier_needs_landing_plan "$tier"; then
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
  if ! tier_has_design_phase "$tier"; then
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
  tier_needs_interview "$tier" && {
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
  # Every other outcome of the round used to be swallowed here: the code went straight to "did a
  # worktree appear", so a round that timed out, errored, or was cut off at a ceiling reported itself as
  # "the skill declined to isolate" -- a wrong diagnosis that sends you to read the skill instead of the
  # round. The round's own numbers are the first thing to look at, so they are printed.
  dim "   isolate round: exit $ROUND_EXIT, \$$ROUND_COST, ${ROUND_TURNS} turns${ROUND_TRUNCATED:+, CUT OFF ($ROUND_TRUNCATED)}"
  if [[ "$ROUND_EXIT" != "0" || -n "$ROUND_TRUNCATED" ]]; then
    halt isolate_round_failed "the isolation round did not complete (exit $ROUND_EXIT${ROUND_TRUNCATED:+, $ROUND_TRUNCATED}).
  No worktree can be expected from a round that did not finish, and 'working in place' is the one
  fallback this loop must not take silently -- in place means on whatever branch you are standing on."
    return 1
  fi
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

# A ROUND'S NUMBERS ARE CONSUMED ONCE, and this is where that happens. `ROUND_COST` / `ROUND_TURNS` are
# globals that outlive the round that set them, and `report`'s `cost by phase` sums exactly `cost_usd` --
# so any row written WITHOUT a new round behind it bills its phase for money another phase spent.
#
# Measured on the first end-to-end run (2026-08-19): `pr-reached` is written outside any round and
# carried the review round's $1.93 / 26 turns, so `cost by phase` reported `pr $5.27` with $1.93 of
# review inside it -- and `review` itself was counted twice, once on `advanced` and again on
# `advanced-untriaged`, which is a second row for the same round. Zeroing here is not a cosmetic
# correction: those rows genuinely cost nothing, and the round that did cost something is already on
# the row that consumed it.
#
# It also gets the CI loop right without any per-call-site decision. A CI-fix round's money lands on
# whichever row is written after it (a halt, or the `advanced` row once CI turns green); the next pass
# with no round writes 0. `SPENT` is accumulated in `claude_round` and is untouched by this, so the
# run's budget accounting does not depend on it.
consume_round_numbers() { ROUND_COST=0; ROUND_TURNS=0; }

record() { # <phase> <landing> <round> <outcome> [halt_reason]
  local rc=0
  ledger_append repo "$(repo_key)" branch "$(branch)" worktree "$PWD" \
    phase "$1" landing "$2" round "$3" outcome "$4" \
    halt_reason "${5:-__null__}" \
    gate "{\"ok\":$([[ "${LAST_OK:-0}" == 1 ]] && echo true || echo false),\"check\":\"$(gate_field check)\",\"kind\":\"$(gate_field kind)\"}" \
    fix_now "${FIX_NOW:-0}" needs_decision "${NEEDS_DECISION:-0}" decline "${DECLINE:-0}" \
    unverified "${UNVERIFIED:-0}" \
    cost_usd "${ROUND_COST:-0}" turns "${ROUND_TURNS:-0}" exit "${ROUND_EXIT:-0}" \
    deferred "$(node -e 'const v=process.argv[1];process.stdout.write(JSON.stringify(v?v.split(" ").filter(Boolean):[]))' "${GATE_DEFERRED:-}")" \
    spent_usd "$SPENT" scorer_touched "$(node -e 'const v=process.argv[1];process.stdout.write(JSON.stringify(v?v.split("\n").filter(Boolean):[]))' "${SCORER_HITS:-}")" || rc=$?
  consume_round_numbers
  return "$rc"
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
  # BEFORE the generic non-zero check below, because a ceiling overrun EXITS NON-ZERO. Measured:
  # `claude --max-budget-usd 0.02 ...` returns exit 1 with subtype error_max_budget_usd and is_error true.
  # Checked after the exit code, this branch was dead for the one case it was built for -- the budget case
  # reported `round_failed` ("exited 1. Nothing is claimed about what it did"), which is true and useless,
  # while the actionable reason sat here unreachable. The eighth run died that way at $2.07 against $2.00.
  #
  # 143 and 124 still come first: "you killed it" and "it never returned" say more than "it was cut off".
  if [[ -n "$ROUND_TRUNCATED" ]]; then
    halt truncated "the $1 round was cut off at its ceiling (subtype: $ROUND_TRUNCATED) after
  \$$ROUND_COST and ${ROUND_TURNS} turns. Its answer is PARTIAL and nothing downstream may treat it as a
  finished one. Raise that round's ceiling if the work genuinely needs it, or make the round cheaper --
  but do not read the partial report as a clean result."
    record "$1" "$2" "$3" halted truncated; return 1
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
  one: the work is NOT verified. Read: scripts/gate.sh status$(inherited_note)"
    record "$1" "$2" "$3" halted gave_up; return 1
  fi
  if node -e 'process.exit(Number(process.argv[1]) > Number(process.argv[2]) ? 0 : 1)' "$SPENT" "$BUDGET_USD"; then
    halt budget "spent \$$SPENT against a budget of \$$BUDGET_USD."
    record "$1" "$2" "$3" halted budget; return 1
  fi
  return 0
}

# Which review skill to type. `/da-review-all` earns its cost when a change spans layers: it classifies,
# runs each layer, then finds the risks that live BETWEEN them. On a single-layer change it classifies
# one file list, runs one layer, and prints "no cross-layer impact" -- and it pays a cold read of its own
# 12 KB body plus a classification pass to get there.
#
# So at tier S with exactly one layer the toolkit has a skill for, the layer skill is typed directly.
# Anything else falls back to the dispatcher, and the fallback is deliberately dumb: guessing a skill
# name would review a layer against the wrong checklist and report it as covered, which is the exact
# failure /da-review-all's own "Done when" list exists to catch.
review_skill_for_tier() {
  local names layer
  review_may_skip_dispatcher "$(ledger_last size tier)" || { printf '/da-review-all'; return 0; }
  names="$(ledger_last size layer_names)"
  # One name, no comma. Zero layers (a docs-only change) is not one layer -- it has no skill either, so
  # it goes to the dispatcher rather than to a guess.
  case "$names" in
    ''|null|*,*) printf '/da-review-all'; return 0 ;;
  esac
  case "$names" in
    backend|server|api)          layer=backend ;;
    frontend|client|web)         layer=frontend ;;
    infra|infrastructure|iac)    layer=infra ;;
    *) printf '/da-review-all'; return 0 ;;
  esac
  printf '/x-review-%s' "$layer"
}

# One line, because it is passed as an argument rather than written to a file.
triage_schema() {
  printf '%s' '{"type":"object","required":["fix_now","needs_decision","decline","unverified"],"properties":{"fix_now":{"type":"integer"},"needs_decision":{"type":"integer"},"decline":{"type":"integer"},"unverified":{"type":"integer"}}}'
}

# One landing, start to submitted PR. Sets HALT when it stops early.
run_landing() { # <n> <what-lands> <one-way>
  local n="$1" what="$2" oneway="$3" r rr schema
  LAST_OK=0; FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0; UNVERIFIED=0
  UNREVIEWED_FIXES_NOTE=""; CI_NONE_NOTE=""; XS_UNTRIAGED_NOTE=""; XS_REVIEW_FILE=""
  # UNVERIFIED_NOTE is assigned inside the TRIAGE block, which XS skips -- so without initialising it
  # here, `set -u` kills the describe round on an unbound variable. Every note that the describe prompt
  # interpolates has to exist on every path that can reach it, and XS added a path.
  UNVERIFIED_NOTE=""

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

**Weight the tests toward INTEGRATION level** -- exercise the units together across the seam they meet
at, through the real boundary rather than a mock of it. Unit tests still matter and a pure function
still gets one; what is being ruled out is a suite that is green because every collaborator was stubbed.
For a change that spans frontend and backend, the test that counts is the one that goes through both.

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
      halt gate_unran "nothing was checked. No gating check ran, so nothing here is verified.
  Skipped: $GATE_UNRAN
  The gate now reports this in a field (\`ran\`) instead of leaving it to be inferred, and it BLOCKS
  when files changed that no check claims -- so reaching here means either the tree was clean, or every
  check that could have judged this work declined it. A \`paths\` that matches nothing looks exactly
  like a check that is not needed."
      record implement "$n" "$r" halted gate_unran; return 1
    fi
    dim "   round $r: $(gate_field check) is $(gate_field kind)"
    record implement "$n" "$r" held
  done
  if [[ "$LAST_OK" != 1 ]]; then
    halt round_cap "the gate never went green in $MAX_ROUNDS rounds. Last: $(gate_field check) ($(gate_field kind)).$(inherited_note)
  Repeated correction piles failed approaches on top of each other -- this is the point to read the
  ledger and rewrite the request rather than buy another round."
    record implement "$n" "$MAX_ROUNDS" halted round_cap; return 1
  fi
  commit_landing "$n" "$what" || return 1

  # --- review, capped ------------------------------------------------------
  # A review ROUND is not one skill: it is /da-review-all plus a /da-fix-plan triage. The first landing
  # that reached this code measured that pair at $5.64 (50 turns) + $2.08 (20) -- against $1.30 for the
  # implementation being reviewed. Two rounds is therefore a ~$15 ceiling on a change that tier S has
  # already judged small enough to skip the design phase for, and the whole point of S is that it costs
  # less. It buys one round.
  #
  # This is a CEILING, not a depth cut, and the distinction is the measurement: on that landing the
  # review had already self-scaled to the bottom fan-out tier -- "inline, no find subagents", per the
  # budget table in skills/_shared/review-process.md, because the diff was 11 lines in one file. There
  # was no depth left to remove. The 50 turns were spent verifying eleven claims against the code, and
  # they found a real error in one of them. Cutting THAT would be buying a cheaper wrong answer.
  local review_rounds="$REVIEW_ROUNDS" review_budget="$BUDGET_ROUND_REVIEW"
  local triage_budget="$BUDGET_ROUND_TRIAGE" findbugs_budget="$BUDGET_ROUND_FINDBUGS" review_skill
  if tier_gets_lean_budgets "$(ledger_last size tier)"; then
    review_rounds="$REVIEW_ROUNDS_LEAN"; review_budget="$BUDGET_ROUND_REVIEW_LEAN"
    triage_budget="$BUDGET_ROUND_TRIAGE_LEAN"; findbugs_budget="$BUDGET_ROUND_FINDBUGS_LEAN"
  fi
  review_skill="$(review_skill_for_tier)"
  schema="$(triage_schema)"
  for (( rr = 1; rr <= review_rounds; rr++ )); do
    dim "   review $rr: $review_skill (ceiling \$$review_budget)"
    ROUND_BUDGET="$review_budget"
    claude_round "$review_skill"
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
      dim "   review $rr: second reviewer (/find-bugs, ceiling \$$findbugs_budget) -- this landing touches a risk surface"
      ROUND_BUDGET="$findbugs_budget"
      claude_round "/find-bugs"
      post_round findbugs "$n" "$rr" || return 1
      SECOND_REPORT="$(round_result)"
      record findbugs "$n" "$rr" advanced
    fi

    # Both reports go in, not counts. The review skills write no file, so the process boundary between
    # rounds is where their findings would be lost -- and a count would buy zero coverage, when coverage
    # is the entire reason for a second reviewer. da-fix-plan's own template says "**Source:** which
    # review(s)", plural, so two reports is a shape it already expects.
    # XS DROPS THE FIX MACHINERY -- but not the review, and not the record of it.
    if ! tier_runs_fix_loop "$(ledger_last size tier)"; then
      # The report goes to DISK, with bash, before anything else. This is not optional.
      # `REVIEW_REPORT` is a shell variable in a process that exits; the only thing that used to persist
      # a review was /da-fix-plan writing docs/fix-plans/. Remove triage and the sole copy becomes an
      # argument to /da-pr-describe -- whose ceiling overrun does NOT halt (it records
      # opened-pr-partial-body and continues). So: PR opens, describe is cut off, the whole review is
      # gone. The eighth unattended run died on exactly a ceiling overrun, so this is measured, not
      # hypothetical. Costs one file write and zero rounds.
      mkdir -p "$LOOP_DIR/reviews" 2>/dev/null || true
      XS_REVIEW_FILE="$LOOP_DIR/reviews/$(basename "$(repo_root)")-$(branch)-$n.md"
      printf '%s\n' "$REVIEW_REPORT" > "$XS_REVIEW_FILE" 2>/dev/null || XS_REVIEW_FILE=""
      [[ -n "$XS_REVIEW_FILE" ]] && dim "   review $rr: untriaged (tier XS); report kept at $XS_REVIEW_FILE"

      # The halt this tier gives up is `needs_decision` -- the only mechanism that stops a landing on a
      # finding a human must DECIDE. At XS that becomes prose in a PR body, which is a defensible trade
      # for a handful of files only if the human is told it happened.
      XS_UNTRIAGED_NOTE="

このレビューの所見は **triage されていません**（tier XS）。\`fix_now\` / \`needs_decision\` の切り分けは
行われておらず、**判断が要る所見があっても駆動系は止まりません**。所見の全文は
${XS_REVIEW_FILE:-（保存に失敗しました）} にあります。**PR 本文にその所見を転記し、「未 triage」と
明記してください。**"

      # A distinct outcome, so `report` can tell a clean review from one that was never triaged. Without
      # it the ledger's absent fix_now reads as "the review found nothing to fix".
      record review "$n" "$rr" advanced-untriaged
      break
    fi

    ROUND_BUDGET="$triage_budget"
    claude_round "/da-fix-plan

Triage the review(s) below. Report only the bucket counts. \`fix_now\` counts Fix now plus Fix now
smaller. \`decline\` counts what you decided not to fix.

The last two are a split, and getting it wrong stops work that should not stop:

\`needs_decision\` -- a person has to CHOOSE something. A trade-off, an approval, a product call, a
question only the owner of the code can answer. **This stops the landing**, so count only what genuinely
cannot proceed without someone deciding.

\`unverified\` -- something the review COULD NOT CONFIRM. A guard it did not read, a path it could not
follow, a clear it could not substantiate. This is a statement about the review's own reach, not a
request for a decision. **It does not stop anything**; it is carried into the PR body as a caveat.
A 👤 saying that reading some file:line would settle it is this one, not the one above.

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
    # Absent is 0 here, deliberately, unlike the two above: an older triage round -- or a hand-run
    # /da-fix-plan -- has no reason to know about this field, and treating its absence as unreadable
    # would halt on a report that is otherwise complete. Absence means "none were reported", which for
    # a caveat is the safe reading; for `fix_now` it would not be, which is why those still refuse.
    UNVERIFIED="$(round_structured unverified)"; UNVERIFIED="${UNVERIFIED:-0}"
    # The NOTE, not the count, is what gets interpolated into the describe prompt: `${UNVERIFIED:+...}`
    # expands on "0" too, because "0" is not the empty string. Making the note the empty thing means the
    # caveat appears exactly when there is one.
    UNVERIFIED_NOTE=""
    [[ "$UNVERIFIED" =~ ^[0-9]+$ && "$UNVERIFIED" -gt 0 ]] && UNVERIFIED_NOTE="

このレビューが **確認できなかった (unverified) 所見が $UNVERIFIED 件** あります。詳細は
docs/fix-plans/ の該当ファイルです。**PR 本文にその件数と、何が確認されていないのかを明記してください。**
これは「直すべき欠陥」でも「あなたが決めるべきこと」でもなく、**レビューの届かなかった範囲**です ——
綺麗な結果を「安全」と読ませないために、読者に渡す必要があります。"
    if [[ -z "$FIX_NOW" || -z "$NEEDS_DECISION" ]]; then
      halt triage_unreadable "the triage round returned no bucket counts (exit $ROUND_EXIT).
  Nothing is claimed about what the review found."
      FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0; UNVERIFIED=0
      record triage "$n" "$rr" halted triage_unreadable; return 1
    fi
    # Non-numeric is also not zero, and `[[ x -gt 0 ]]` on a non-number exits non-zero under set -u
    # rather than comparing -- which would be a silent pass in the branch below.
    case "$FIX_NOW$NEEDS_DECISION$DECLINE$UNVERIFIED" in
      *[!0-9]*)
        halt triage_unreadable "the triage counts were not numbers (fix_now='$FIX_NOW',
  needs_decision='$NEEDS_DECISION', decline='$DECLINE')."
        FIX_NOW=0; NEEDS_DECISION=0; DECLINE=0; UNVERIFIED=0
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

    # NOTE THE ORDER. The cap used to be checked HERE, before the fixes were applied -- so at tier S,
    # where `review_rounds` is 1, a single Fix-now finding halted the landing with the fix never
    # attempted and `/receiving-code-review` unreachable. A review reliably finds at least one thing
    # worth fixing, so tier S -- the tier meant to run unattended end to end -- could essentially never
    # reach a PR. Fourth time a cap made its own downstream unreachable.
    #
    # What `REVIEW_ROUNDS` governs is **how many times we REVIEW**, not whether the last review's
    # findings get acted on. Applying is one cheap round that the gate re-verifies; buying another
    # review is the expensive thing the cap exists to stop. So the fix is applied first, and the cap
    # decides only whether another REVIEW follows.

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
      # Last round: the fixes are in and gate-verified, but nothing reviewed them. That is a real gap,
      # so it is carried to the PR body rather than being the reader's job to notice -- same shape as
      # GATE_DEFERRED and the unverified count.
      if [[ "$rr" -ge "$review_rounds" ]]; then
        UNREVIEWED_FIXES_NOTE="

このレビュー周回で **$FIX_NOW 件の修正を適用しましたが、その修正自体は再レビューされていません**
（tier の review 周回数が $review_rounds のため）。ゲートは通っていますが、機械的な検証だけです。
**PR 本文にその件数と、再レビューされていないことを明記してください。**"
        say "   review $rr: applied $FIX_NOW fix(es); no round left to re-review them"
        break
      fi
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
# --- after the PR is open ----------------------------------------------------
# The loop used to end at `gh stack submit`, which meant it handed back a PR nobody had watched: the CI
# it triggers and the comments a human leaves on it were both outside the machine. They are the half of
# review that costs a person the most attention, because each arrival is an interrupt.
#
# `gh pr checks` exit codes are the contract: 0 all green, 1 something failed, 8 still running.
# 0 green, 1 red, 2 gave up waiting on pending, 3 this PR reports no checks at all. Sets CI_OUT.
#
# **Decided from the STATES, never from the exit code.** `gh` documents exit 1 as "failed for any
# reason", and `gh pr checks` only adds 8 for pending -- so an exit-code reading collapses these into
# one answer: a check that failed, checks that **do not exist yet** (the normal state for the seconds
# after a push), and an auth failure. Measured on the seventh run: the driver looked before GitHub had
# registered the workflow, read "red", and spent $1.71 / 41 turns debugging a failure that did not exist.
ci_state() { # <pr-number>
  local num="$1" waited=0 graced=0 states
  while :; do
    CI_OUT="$(gh pr checks "$num" 2>&1)"
    states="$(gh pr checks "$num" --json name,state --jq '.[].state' 2>/dev/null)"

    if [[ -z "$states" ]]; then
      # No checks REPORTED. Right after a push that means "not registered yet"; after the grace window
      # it means this repository has nothing to report, which is a fact to carry, not a failure to fix.
      (( graced >= CI_GRACE_SECONDS )) && return 3
      sleep 5; graced=$((graced + 5)); continue
    fi
    # Any terminal-bad state is red. Named explicitly: a state this list does not know must not silently
    # count as green, so the pending set is named too and anything else falls through to red.
    grep -qE '^(FAILURE|ERROR|CANCELLED|TIMED_OUT|ACTION_REQUIRED|STARTUP_FAILURE)$' <<<"$states" && return 1
    if grep -qE '^(PENDING|QUEUED|IN_PROGRESS|WAITING|REQUESTED|EXPECTED)$' <<<"$states"; then
      (( waited >= CI_WAIT_SECONDS )) && return 2
      sleep 10; waited=$((waited + 10)); continue
    fi
    grep -qvE '^(SUCCESS|NEUTRAL|SKIPPED)$' <<<"$states" && return 1   # an unknown state is not green
    return 0
  done
}

ci_settle() { # <landing> <pr-number>
  local n="$1" num="$2" a
  for (( a = 1; a <= CI_ATTEMPTS + 1; a++ )); do
    ci_state "$num"
    case $? in
      0) dim "   CI green"; record ci "$n" "$a" advanced; return 0 ;;
      2) halt ci_pending "CI was still running after ${CI_WAIT_SECONDS}s on PR #$num. The PR is open and
  its code passed the local gate; what is unknown is what CI thinks. Nothing is claimed about it."
         record ci "$n" "$a" halted ci_pending; return 1 ;;
      3) # No checks after the grace window. Not a failure and not a pass: there is nothing to read.
         # Carried to the PR body rather than silently treated as green -- the same shape as a deferred
         # gate, and the reason `gate.sh verify` reporting ok:true for "nothing ran" is a known trap here.
         CI_NONE_NOTE="

**この PR には報告されるチェックが1つもありません**（${CI_GRACE_SECONDS}s 待った結果）。ローカルの
ゲートは通っていますが、**CI が何かを言ったわけではありません。** PR 本文にその旨を明記してください。"
         say "   CI: this PR reports no checks at all -- nothing to read, and that is not a pass"
         record ci "$n" "$a" advanced; return 0 ;;
    esac
    # Red. The last iteration exists only to report, never to fix -- so the cap is a cap.
    if (( a > CI_ATTEMPTS )); then
      halt ci_red "CI is still red on PR #$num after $CI_ATTEMPTS attempt(s):
  $(printf '%s' "$CI_OUT" | head -3 | tr '\n' ' ')
  More attempts pile failed approaches on each other. Read the run, then decide."
      record ci "$n" "$a" halted ci_red; return 1
    fi
    dim "   CI red -- attempt $a/$CI_ATTEMPTS"
    ROUND_BUDGET="$BUDGET_ROUND_CI"
    claude_round "/systematic-debugging

CI is red on PR #$num. This is the output:

$CI_OUT

Find the root cause before proposing a fix. CI runs what this machine may not, so the failure may be
real even where the local gate is green -- do not assume the difference is CI's fault.

Do not modify profiles/, hooks/, or anything under scripts/. Do not touch the CI configuration to make
a check stop running: a check removed is not a check passed."
    post_round ci "$n" "$a" || return 1
    if [[ -z "$(changed_paths)" ]]; then
      halt ci_fix_changed_nothing "the CI-fix round changed nothing, so the next look at CI would ask
  the same question and get the same answer."
      record ci "$n" "$a" halted ci_fix_changed_nothing; return 1
    fi
    gate_verify_ok || { halt red_after_ci "the CI fix took the LOCAL gate red: $(gate_field check).
  Pushing it would trade a red CI for a red gate."; record ci "$n" "$a" halted red_after_ci; return 1; }
    commit_landing "$n" "CI fix" || return 1
    prune_stale_remotes; gh stack push >/dev/null 2>&1 || { halt push_failed "gh stack push failed after the CI fix"; \
      record ci "$n" "$a" halted push_failed; return 1; }
  done
}

# Human review comments. Two rounds, deliberately in this order and only when there are comments:
# addressing changes code and must pass the gate; replying is an outward-facing act and happens only
# after that. Merging them would announce "done" to a person before anything verified it.
pr_comments_settle() { # <landing> <pr-number>
  local n="$1" num="$2" body count
  body="$(gh api "repos/{owner}/{repo}/pulls/$num/comments" --paginate 2>/dev/null)"
  count="$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const a=JSON.parse(s);process.stdout.write(String(Array.isArray(a)?a.length:0))}
    catch{process.stdout.write("0")}})' <<<"$body")"
  [[ "${count:-0}" -gt 0 ]] || return 0
  dim "   $count review comment(s) on PR #$num"

  ROUND_BUDGET="$BUDGET_ROUND_COMMENTS"
  claude_round "/receiving-code-review

These are the review comments on PR #$num. Evaluate each one against the actual code before changing
anything -- a remedy applied because it was written down is the failure that skill exists to prevent.
Apply what holds up. Leave what does not, and note why; that is an answer, not a refusal.

**Do not post anything.** Replies are composed in a separate step and posted by the driver.

$body"
  post_round comments "$n" 1 || return 1

  if [[ -n "$(changed_paths)" ]]; then
    gate_verify_ok || { halt red_after_comments "the comment fixes took the gate red: $(gate_field check)."
      record comments "$n" 1 halted red_after_comments; return 1; }
    commit_landing "$n" "review comments" || return 1
    prune_stale_remotes; gh stack push >/dev/null 2>&1 || { halt push_failed "gh stack push failed after the comment fixes"
      record comments "$n" 1 halted push_failed; return 1; }
  fi
  record comments "$n" 1 advanced

  # The round writes the replies; the DRIVER posts them. Handing an unattended round `Bash(gh api:*)` so
  # it can reply would also hand it merging, deleting and resolving -- and resolving is precisely the
  # thing this phase must not do. A reply says "here is what I did"; resolving says "you are satisfied",
  # which is not the driver's claim to make. Same shape as /da-pr-describe: the driver makes the shell.
  ROUND_BUDGET="$BUDGET_ROUND_REPLY"
  claude_round "Write one reply per review comment on PR #$num, using what you just did.

Each reply says what changed and where, or -- when you did not act -- what you found and why the comment
does not hold against the code. Cite \`file:line\`. Be brief and do not thank anybody for the review.
**Never claim something was fixed that was not.**

$body" '{"type":"object","required":["replies"],"properties":{"replies":{"type":"array","items":{"type":"object","required":["comment_id","body"],"properties":{"comment_id":{"type":"integer"},"body":{"type":"string"}}}}}}'
  post_round reply "$n" 1 || return 1

  local posted=0 line cid rbody
  while IFS=$'\t' read -r cid rbody; do
    [[ -n "$cid" ]] || continue
    # `-f body=@-` is not used: the body is multi-line and shell-quoted here, where it is visible.
    printf '%s' "$rbody" | gh api "repos/{owner}/{repo}/pulls/$num/comments/$cid/replies" \
      --method POST -F body=@- >/dev/null 2>&1 && posted=$((posted + 1))
  done < <(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    try{const o=JSON.parse(s).structured_output;for(const r of (o&&o.replies)||[])
      process.stdout.write(String(r.comment_id)+"\t"+String(r.body).replace(/\n/g," ")+"\n")}catch{}})' \
    <<<"$ROUND_OUT")

  say "   replied to $posted of $count comment(s) -- nothing resolved; closing a thread is yours"
  record reply "$n" 1 advanced
  return 0
}

# Stale remote-tracking refs make `git push` refuse a branch the remote no longer has:
#
#   ! [rejected] worktree-unattended-run -> worktree-unattended-run (stale info)
#
# GitHub deletes the head branch when a PR merges (auto-delete-branch), so after the loop's FIRST
# landing merges, `refs/remotes/origin/<that branch>` survives locally pointing at something gone. The
# next landing that lands on the same branch name -- which is what happens when the isolation skill
# picks its name from the repository rather than from the clock -- cannot push at all.
#
# Measured: the sixth run spent $7.84 and 2h13m, applied four review fixes, and died at `gh stack push`.
# **Any repository with auto-delete-branch hits this on its second landing.**
prune_stale_remotes() {
  git fetch --prune --quiet origin 2>/dev/null || git remote prune origin >/dev/null 2>&1 || true
}

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

  prune_stale_remotes; gh stack push >/dev/null 2>&1 || { halt push_failed "gh stack push failed"; \
    record pr "$1" 0 halted push_failed; return 1; }
  local url
  # --open, not the default: `gh stack submit` creates drafts, and these layers have already been
  # through the gate and a review pass. --auto because there is no editor to open.
  gh stack submit --auto --open >/dev/null 2>&1
  # ASK GITHUB, do not scrape stdout. `gh stack submit` prints a URL when it CREATES the PR and prose
  # when the PR is already current -- "PR #45 for <branch> is up to date". Both are success, and the
  # driver used to grep for a URL and call the second one `pr_failed`: **measured, on a PR that was open
  # the whole time.** CI, the comments and the description never ran, and the PR kept its
  # auto-generated title with no body, because the submit that made it did not print the right shape.
  #
  # This repository already names the same disease twice about the gate (`gate_has_profile` and
  # `gate_verify_ok` both read prose, and the comments there say so). Third place, same cure: ask the
  # tool that knows. `gh pr view` answers for the current branch and cannot be reworded.
  url="$(gh pr view --json url --jq .url 2>/dev/null)"
  [[ -n "$url" ]] || { halt pr_failed "no PR exists for this branch after \`gh stack submit\`.
  Asked with \`gh pr view --json url\`, which is the authority -- this is not a parse failure."; \
    record pr "$1" 0 halted pr_failed; return 1; }
  local num; num="$(printf '%s' "$url" | sed 's@.*/@@')"

  # RECORDED HERE, not at the end. The PR exists from this line onward -- CI, the comments and the
  # description all run after it and any of them can halt. Writing the only `pr` row after all three
  # meant a halt downstream left the ledger with NO row, and `report` then led with
  # `reached PR 0 (0%)` and "acceptance is under 50%, the loop is handing review work back to you".
  # Measured: the seventh run halted at `ci_fix_changed_nothing` with a real PR open on GitHub, counted
  # as zero. Same disease as the `pr_failed` bug above -- the ledger saying something untrue about the
  # outward world -- and the cure is the same shape: record the fact when it becomes a fact.
  #
  # `pr-reached` and `opened-pr` are different facts on purpose: reached a PR, and finished one. The
  # names deliberately do not differ by word order alone -- `pr-opened` vs `opened-pr` is one typo, and
  # one grep, away from silently reading as the other.
  record pr "$1" 0 pr-reached

  # CI and the human's comments settle BEFORE the description is written. The description is the last
  # thing that happens to this PR, so that it describes what the change ended up being -- including the
  # CI fixes and whatever the review comments moved. Written at submit time it described a snapshot one
  # minute old, and nothing ever came back to correct it.
  ci_settle "$1" "$num" || return 1
  pr_comments_settle "$1" "$num" || return 1

  # The driver makes the shell; the skill writes the body. da-pr-describe's own precondition is that
  # a PR already exists and that it must not create one -- which stays literally true this way.
  ROUND_BUDGET="$BUDGET_ROUND_PR"
  claude_round "/da-pr-describe $num${GATE_DEFERRED:+

このリポジトリがエージェントに実行を禁じているため、ローカルで検証していないチェックがあります:
  $GATE_DEFERRED

PR 本文にそれを明記してください —— **CI が走らせるまで、その分は未検証**です。}${UNVERIFIED_NOTE}${UNREVIEWED_FIXES_NOTE}${CI_NONE_NOTE}${XS_UNTRIAGED_NOTE}"

  # The one place halting cannot undo what already happened: `gh stack submit` opened the PR above,
  # before the body was written. So a cut-off /da-pr-describe leaves a REAL, open PR carrying a
  # half-written description -- and the plain `opened-pr` row would read as a finished one.
  #
  # It does not halt the run, following the same precedent as a deferred gate: the work itself passed,
  # what is incomplete is the description, and that is said loudly and recorded rather than silently
  # accepted or used to stop the remaining landings. A human reading the ledger can see which PR to fix.
  if [[ -n "$ROUND_TRUNCATED" ]]; then
    # Read before the record: `record` consumes the round's numbers, so this message has to hold its
    # own copy or it prints the cost as 0 -- the number a reader needs in order to raise the ceiling.
    local cut_cost="$ROUND_COST"
    record pr "$1" 0 opened-pr-partial-body
    say ""
    say "landing $1 -> $url  (layer $1 of the stack)"
    printf '%sloop: the PR body is PARTIAL -- /da-pr-describe was cut off (%s) after $%s.%s\n' \
      "$c_red" "$ROUND_TRUNCATED" "$cut_cost" "$c_off" >&2
    printf '  The PR is open and its code went through the gate and the review. Its DESCRIPTION did not
  finish being written -- read it before anyone reviews from it, and raise BUDGET_ROUND_PR.\n' >&2
    return 0
  fi
  record pr "$1" 0 opened-pr
  say ""
  say "landing $1 -> $url  (layer $1 of the stack, ready for review)"
  return 0
}

parse_plan() { # <path> -> "n<TAB>what<TAB>oneway" per landing row
  node -e '
    const fs = require("fs");
    const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
    // Anchored on the HEADER ROW, which is what landing_plans() already uses to identify a plan file.
    // The previous trigger was any line matching /Landing plan/i -- and the first such line in a real
    // plan is its own title, so parsing locked onto whatever table came next. The first plan this
    // driver was handed that it had not generated itself had an evidence table above the 🧱 one, and
    // its rows became the landings: `gh stack add` was asked for a layer named after a table cell.
    // Discovery and parsing must key on the same thing, or a file can be found and then misread.
    let inTable = false, out = [];
    for (const l of lines) {
      // The trigger must BE the header row, not prose that mentions it -- this file, and any plan that
      // explains its own format, contains the phrase in running text as well.
      if (l.trim().startsWith("|") && /what gates it/i.test(l)) { inTable = true; continue }
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

  if tier_needs_landing_plan "$tier"; then
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

  # THE BASE THE GATE DIFFS AGAINST, for the whole landing. Without this the gate answers a different
  # question after every commit, and the answer gets worse as the landing progresses.
  #
  # `commit_landing` runs mid-landing (before review), and the gate's changed set is computed against
  # HEAD. So the verify that follows the fix round sees ONLY the fix's delta -- the implementation it
  # is supposed to be verifying is already committed and therefore invisible. Today that is harmless
  # because every check is `scope: all` and ignores the file list. The moment a check declares which
  # paths it cares about, it becomes the primary way to break a healthy landing: the checks that match
  # the implementation are all "not applicable", nothing runs, and the gate blocks work that was fine.
  #
  # Pinned to the merge-base so every verify in this landing asks about the same thing: everything this
  # landing has done, committed or not. Left unset outside `run`, so interactive `gate.sh verify` keeps
  # its HEAD-relative behaviour exactly.
  LANDING_BASE="$(git merge-base "$(default_branch)" HEAD 2>/dev/null || true)"
  if [[ -n "$LANDING_BASE" ]]; then
    export DOTAGENTS_GATE_DIFF_BASE="$LANDING_BASE"
    dim "  gate diffs against $(printf '%.12s' "$LANDING_BASE") (this landing's base, not HEAD)"
  fi

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
  # STARTED_RED_CHECK, not just the boolean. The boolean was assigned, printed, and read by nothing --
  # on the first real run this line was the only place that said the loop had inherited a red installer
  # suite rather than broken it, and it scrolled past thirty lines above the halt that mattered. The
  # name is kept so the give-up messages can say which of the two happened.
  if [[ "$STARTED_GREEN" == 1 ]]; then
    STARTED_RED_CHECK=""
    dim "  starting green"
  else
    STARTED_RED_CHECK="$(gate_field check)"
    dim "  starting red: $STARTED_RED_CHECK ($(gate_field kind)) -- inherited, not caused by this run"
  fi

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
  if tier_synthesises_landing_row "$tier" && [[ -z "$plan" ]]; then
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
    // ROWS WRITTEN BEFORE `consume_round_numbers` KEEP THEIR WRONG NUMBERS, and the ledger is
    // append-only on purpose -- a test asserts that it is never trimmed. So the totals below cannot be
    // corrected; they can only be qualified, and this counts by how much. Detected by the SYMPTOM, not
    // by a date: `record` wrote the round globals, so a round whose numbers were written twice appears
    // as two rows of one landing with the same cost AND the same turn count. A date would need the
    // version of `loop.sh` that wrote each row, which the row does not carry.
    const seen = new Set();
    let dupExcess = 0, dupRows = 0;
    for (const r of rows) {
      const c = Number(r.cost_usd) || 0;
      if (c > 0) {
        const key = [r.landing, c, r.turns].join("|");
        if (seen.has(key)) { dupExcess += c; dupRows++; } else { seen.add(key); }
      }
      total += c;
      byPhase[r.phase] = (byPhase[r.phase] || 0) + c;
      if (r.phase === "size") continue;
      if (r.landing != null) landings.add(String(r.landing));
      // Both PR outcomes count as reaching a PR. The metric is "did the landing get there", and a
      // partial-bodied PR did: its code went through the gate and the review, and only the description
      // was cut off. Counting it as not-reached would understate acceptance for a documentation defect
      // -- and the `opened-pr-partial-body` row is where that defect is already recorded, per landing.
      // `pr-reached` counts too: the PR exists once submit resolved it, whatever halted afterwards.
      // Excluding it reported 0% for landings whose PR a human could open in a browser.
      if (r.outcome === "opened-pr" || r.outcome === "opened-pr-partial-body"
          || r.outcome === "pr-reached") accepted.add(String(r.landing));
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
        double_counted_usd: dupExcess, double_counted_rows: dupRows,
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
      if (dupRows) {
        console.log("");
        console.log(`${money(dupExcess)} of the figures above is counted twice, across ${dupRows} row(s).`);
        console.log("Those rows repeat the cost and turn count of a round already billed: they were");
        console.log("written before the driver stopped billing one round more than once. The ledger is");
        console.log("append-only, so they keep them: cost by phase and cost per accepted are overstated");
        console.log("by that much.");
      }
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
