#!/usr/bin/env bash
# Behaviour of the loop driver: the state machine only.
#
# `claude` and `gh` are stubbed on PATH. The gate is NOT stubbed -- a hermetic profile with one
# trivial check (`test -f GREEN`) is used instead, so the driver is exercised against the real
# gate.sh and the real hook. Stubbing the gate would have meant testing the driver against a second
# implementation of the thing it exists to read, which is the failure this repository keeps finding.
#
# What is deliberately NOT asserted here: anything about what the real `claude` does. Whether a Stop
# hook fires at the end of a `claude -p` turn, whether a slash command reaches a skill carrying
# disable-model-invocation, and whether da-review-all can satisfy its mandatory Canvas step headless
# are all unmeasured -- see docs/loops.md. The driver is written so that neither answer changes its
# behaviour: it aborts a landing on the gate's VERDICT *or* on its own round cap, and records which
# one fired. These tests cover both branches; the first real run is what says which one is live.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOOP="$REPO/scripts/loop.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/dotagents-test-loop.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT INT TERM

pass=0; fail=0
if [[ -n "${NO_COLOR:-}" || ! -t 1 ]]; then c_red=''; c_green=''; c_dim=''; c_off=''
else c_red=$'\033[31m'; c_green=$'\033[32m'; c_dim=$'\033[2m'; c_off=$'\033[0m'; fi
ok() { printf '%s✓%s %s\n' "$c_green" "$c_off" "$1"; pass=$((pass+1)); }
no() { printf '%s✗%s %s\n' "$c_red" "$c_off" "$1"; fail=$((fail+1)); }
detail() { [[ -n "${1:-}" ]] && printf '%s    %s%s\n' "$c_dim" "$1" "$c_off"; }

# --- the stubs ---------------------------------------------------------------
# Responses are scripted per phase (see the stub below), so a test declares "the first review returns
# this" rather than "the third claude call returns this". The stub also appends its argv to a log, which
# is how "the driver never passed --bare" and "the driver typed /da-verify" are asserted rather than
# assumed.
BIN="$TMP/bin"; mkdir -p "$BIN"
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_CLAUDE_LOG"

# Responses are keyed by PHASE, not by call index. An earlier version numbered them 1,2,3... in call
# order, which coupled every fixture to how many times the driver happens to invoke claude: adding one
# call (`/da-verify`) silently shifted every response by one, and a shifted fixture does not fail
# loudly -- the stub returns nothing, the driver reads cost 0 and no structured output, and tests pass
# for no reason. Keying on the prompt makes a fixture mean what it says.
# The PROMPT's first line decides the phase, not the whole argv. Matching anywhere in "$*" bit twice:
# the executing-plans prompt deliberately contains "/test-driven-development" (the only thing that
# guarantees TDD under it), and the triage prompt carries "/da-review-all" and "/find-bugs" as section
# headers over the reports it is handed. Both were misread as the phase they merely mention. The prompt
# is always the last argument and always starts with the command, so that is what gets matched.
prompt="${!#}"
first="${prompt%%$'\n'*}"
phase=other
case "$first" in
  */da-investigate*)          phase=investigate ;;
  */using-git-worktrees*)     phase=worktree ;;
  */da-verify*)               phase=verify ;;
  */executing-plans*)         phase=execplan ;;
  */test-driven-development*) phase=implement ;;
  */systematic-debugging*)    phase=debug ;;
  */da-review-all*)           phase=review ;;
  */find-bugs*)               phase=findbugs ;;
  */da-fix-plan*)             phase=triage ;;
  */receiving-code-review*)   phase=fix ;;
  */da-pr-describe*)          phase=pr ;;
esac

# `/da-verify` is the only thing that arms the gate (AGENTS.md invariant 2), so the stub does what the
# real skill's Step 0 does. Without this the gate is never armed in these tests, and the VERDICT cases
# would be exercising an unarmed gate -- a state the driver never actually meets.
[[ "$phase" == "verify" ]] && { bash "$DOTAGENTS_REPO/scripts/gate.sh" arm "$PWD" >/dev/null 2>&1 || true; }
# Likewise the worktree skill actually creates one, because the driver finds the result by reading
# `git worktree list` rather than by trusting the reply. A stub that only answered would leave the
# driver correctly reporting "no worktree appeared" and the test would prove nothing.
if [[ "$phase" == "worktree" && ! -f "$FAKE_CLAUDE_DIR/no-worktree" ]]; then
  git worktree add -q "$PWD/.worktrees/loop" -b loop-wt >/dev/null 2>&1 || true
fi

n=1
[[ -f "$FAKE_CLAUDE_DIR/$phase.counter" ]] && n=$(cat "$FAKE_CLAUDE_DIR/$phase.counter")
printf '%s' "$((n+1))" > "$FAKE_CLAUDE_DIR/$phase.counter"

resp="$FAKE_CLAUDE_DIR/$phase.$n.json"
# `execplan` and `implement` are the same ROLE -- round 1 of implementation -- and which one the driver
# types depends only on the tier. A fixture that says "the first implementation round returns this"
# should not have to know the tier, so execplan falls back to the implement fixtures. The tests that
# assert the distinction check the phase counters directly.
if [[ ! -f "$resp" && "$phase" == "execplan" ]]; then
  resp="$FAKE_CLAUDE_DIR/implement.$n.json"
  [[ -f "$FAKE_CLAUDE_DIR/implement.$n.sh" && ! -f "$FAKE_CLAUDE_DIR/execplan.$n.sh" ]] \
    && bash "$FAKE_CLAUDE_DIR/implement.$n.sh"
fi
[[ -f "$resp" ]] || resp="$FAKE_CLAUDE_DIR/$phase.json"
# A response may carry a side effect -- the edits a real round would have made. A per-phase default
# covers "every round of this phase does the same thing", which the round-cap case needs: a round that
# changes NOTHING is a different failure (round_changed_nothing) from one that changes something and
# stays red, and the cap case is about the latter.
if [[ -f "$FAKE_CLAUDE_DIR/$phase.$n.sh" ]]; then bash "$FAKE_CLAUDE_DIR/$phase.$n.sh"
elif [[ -f "$FAKE_CLAUDE_DIR/$phase.sh" ]]; then bash "$FAKE_CLAUDE_DIR/$phase.sh"; fi
# A round can be made to hang. Measured against the real CLI: `--json-schema` with a FILE PATH hangs
# forever instead of erroring, so "the round never returns" is a real state, not a hypothetical.
[[ -f "$FAKE_CLAUDE_DIR/$phase.$n.sleep" ]] && sleep "$(cat "$FAKE_CLAUDE_DIR/$phase.$n.sleep")"
code=0
[[ -f "$FAKE_CLAUDE_DIR/$phase.$n.exit" ]] && code=$(cat "$FAKE_CLAUDE_DIR/$phase.$n.exit")
cat "$resp" 2>/dev/null
exit "$code"
STUB
cat > "$BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
case "$1 ${2:-}" in
  "extension list")
    [[ -f "$FAKE_GH_DIR/no-stack-ext" ]] && { printf ''; exit 0; }
    printf 'gh stack\tgithub/gh-stack\tv0.1.0\n' ;;
  "stack view")
    [[ -f "$FAKE_GH_DIR/stack" ]] || exit 1
    printf '{"layers":[]}\n' ;;
  "stack init")
    # The real `gh stack init` takes the branches as POSITIONAL arguments and, given none, tries to ask:
    # "interactive input required; provide branch names as arguments". Headless, that is a hard failure.
    # This stub used to accept `stack init` with flags alone, so the suite was green against a call the
    # real extension rejects -- the stacked-PR path could never have worked unattended, and nothing here
    # could say so. A stub that accepts what the real tool refuses is not a test, it is a second bug.
    shift 2   # drop "stack" and "init"; what remains is flags and branch names
    branches=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -b|--base) shift 2 ;;
        -*) shift ;;
        *) branches="$branches $1"; shift ;;
      esac
    done
    [[ -n "${branches// /}" ]] || { printf 'interactive input required; provide branch names as arguments\n' >&2; exit 1; }
    : > "$FAKE_GH_DIR/stack" ;;
  "stack add")
    # The real extension creates and checks out the new layer branch; the driver commits onto it, so
    # the stub has to actually move HEAD or every layer after the first would commit to the wrong branch.
    shift 2; git checkout -q -b "${1:-layer}" 2>/dev/null ;;
  "stack push") : ;;
  "stack submit")
    printf 'https://github.com/probe/x/pull/7\n' ;;
  "pr list")
    cat "$FAKE_GH_DIR/pr-list" 2>/dev/null || printf '' ;;
  *) printf '' ;;
esac
exit 0
STUB
chmod +x "$BIN/claude" "$BIN/gh"

# --- fixtures ----------------------------------------------------------------
CASE=0
setup() { # -> exports REPO_DIR, GATE, PROFILES, LOOPDIR, FAKE_* for one case
  CASE=$((CASE+1))
  local root="$TMP/case$CASE"
  REPO_DIR="$root/repo"; GATE="$root/gate"; PROFILES="$root/profiles"; LOOPDIR="$root/loop"
  FAKE_CLAUDE_DIR="$root/claude"; FAKE_GH_DIR="$root/gh"
  FAKE_CLAUDE_LOG="$root/claude.log"; FAKE_GH_LOG="$root/gh.log"
  mkdir -p "$REPO_DIR" "$GATE" "$PROFILES" "$LOOPDIR" "$FAKE_CLAUDE_DIR" "$FAKE_GH_DIR"
  : > "$FAKE_CLAUDE_LOG"; : > "$FAKE_GH_LOG"
  export FAKE_CLAUDE_DIR FAKE_GH_DIR FAKE_CLAUDE_LOG FAKE_GH_LOG
  # A real bare remote, not a fictional URL: the PR phase pushes, and a driver whose push is stubbed
  # is a driver whose push is untested. The directory is named so the profile's `match.remote`
  # substring still finds it.
  git init -q --bare "$root/dotagents-loop-probe.git"
  git -C "$REPO_DIR" init -q
  # A real checkout has an author identity, and the driver's own `git commit` inherits it -- the loop
  # commits AS YOU. Setting it per-fixture rather than passing -c on the fixture's own commits: the -c
  # form hid the fact that the repository had no identity at all, so `commit_landing` worked here and
  # failed on CI with "could not commit landing 1". A test that only passes where the machine already
  # has state is not a test of the driver.
  git -C "$REPO_DIR" config user.email loop@test
  git -C "$REPO_DIR" config user.name "loop test"
  git -C "$REPO_DIR" remote add origin "$root/dotagents-loop-probe.git"
  printf 'x\n' > "$REPO_DIR/a.txt"
  git -C "$REPO_DIR" add a.txt
  git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm init
  git -C "$REPO_DIR" branch -M main
  git -C "$REPO_DIR" push -q origin main 2>/dev/null
  git -C "$REPO_DIR" checkout -q -b work
  cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true,
                "agent_may_run": true, "scope": "all", "timeout": 10 } ],
  "timeout_total": 60 }
JSON
}

commit_in_repo() { git -C "$REPO_DIR" -c user.email=t@t -c user.name=t commit -qm "$1"; }

# A measurement as /da-investigate would return it, wrapped the way `claude -p --output-format json`
# wraps structured output.
measurement() { # <files> <layers> <one_way> <risk> <unconfirmed>  -> writes 1.json
  local files="$1" layers="$2" oneway="$3" risk="$4" unconf="$5"
  node -e '
    const [f, l, o, r, u] = process.argv.slice(1).map(Number);
    const arr = (n, p) => Array.from({length: n}, (_, i) => p + i);
    process.stdout.write(JSON.stringify({
      total_cost_usd: 0.01, num_turns: 2, result: "ok",
      structured_output: {
        files: arr(f, "src/f"), layers: arr(l, "layer"),
        one_way: arr(o, "door"), risk_surfaces: arr(r, "surface"),
        unconfirmed: arr(u, "unknown"),
      },
    }));
  ' "$files" "$layers" "$oneway" "$risk" "$unconf" > "$FAKE_CLAUDE_DIR/investigate.1.json"
  # Every phase gets a benign default, so a test only writes the responses it actually cares about and
  # an unscripted phase does not silently return an empty body.
  local p
  for p in worktree verify implement execplan debug review findbugs fix pr other; do
    printf '{"total_cost_usd":0.01,"num_turns":1,"result":"ok"}' > "$FAKE_CLAUDE_DIR/$p.json"
  done
  printf '{"total_cost_usd":0.01,"num_turns":1,"result":"ok","structured_output":{"fix_now":0,"needs_decision":0,"decline":0}}' \
    > "$FAKE_CLAUDE_DIR/triage.json"
}

# A round as a given phase would return it. Keyed by phase and occurrence, never by call order.
respond() { # <phase> <n> <cost> <turns> [fix_now] [needs_decision] [decline]
  node -e '
    const [c, t, fn, nd, dc] = process.argv.slice(1);
    const o = { total_cost_usd: Number(c), num_turns: Number(t), result: "done" };
    if (fn !== "-") o.structured_output = {
      fix_now: Number(fn), needs_decision: Number(nd), decline: Number(dc) };
    process.stdout.write(JSON.stringify(o));
  ' "$3" "$4" "${5:--}" "${6:-0}" "${7:-0}" > "$FAKE_CLAUDE_DIR/$1.$2.json"
}
side_effect() { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.sh"; }   # <phase> <n> <shell>
side_effect_all() { printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/$1.sh"; }   # <phase> <shell>, every round
fails_with()  { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.exit"; } # <phase> <n> <exit-code>
hangs_for()   { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.sleep"; } # <phase> <n> <seconds>

runloop() { # <args...> -> stdout+stderr in $OUT, status in $RC
  OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" \
    DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" "$@" 2>&1)"
  RC=$?
}

ledger() { cat "$LOOPDIR/ledger.jsonl" 2>/dev/null; }
ledger_field() { # <jq-ish path via node> -> last line's field
  ledger | node -e '
    let last = null;
    require("readline").createInterface({input: process.stdin})
      .on("line", (l) => { if (l.trim()) try { last = JSON.parse(l) } catch {} })
      .on("close", () => {
        const p = process.argv[1].split(".");
        let v = last;
        for (const k of p) v = v == null ? v : v[k];
        process.stdout.write(String(v));
      });
  ' "$1"
}

echo "loop driver"
echo

# ---------------------------------------------------------------- usage
setup
runloop
[[ $RC -eq 0 ]] && grep -q 'loop\.sh size' <<<"$OUT" && grep -q 'loop\.sh run' <<<"$OUT" \
  && grep -q 'loop\.sh report' <<<"$OUT" \
  && ok "no arguments prints usage naming every subcommand" \
  || { no "no arguments did not print a usage listing every subcommand (exit $RC)"; detail "$OUT"; }

runloop --help
[[ $RC -eq 0 ]] && grep -q 'loop\.sh size' <<<"$OUT" \
  && ok "--help prints the same usage" || no "--help did not print usage (exit $RC)"

# ---------------------------------------------------------------- tier arithmetic
# The boundaries, from the table in docs/loops.md. Each is one measurement through `size`.
tier_case() { # <label> <expected> <files> <layers> <oneway> <risk> <unconfirmed>
  local label="$1" want="$2"; shift 2
  setup
  measurement "$@"
  runloop size "a request"
  if [[ $RC -eq 0 ]] && grep -qE "tier[[:space:]]+$want\b" <<<"$OUT"; then
    ok "$label -> $want"
  else
    no "$label should be $want (exit $RC)"; detail "$(head -3 <<<"$OUT" | tr '\n' ' ')"
  fi
}
tier_case "5 files, 1 layer, nothing else"      S  5  1 0 0 0
tier_case "6 files crosses into M"              M  6  1 0 0 0
tier_case "15 files is still M"                 M 15  1 0 0 0
tier_case "16 files crosses into L"             L 16  1 0 0 0
tier_case "2 layers is M"                       M  3  2 0 0 0
tier_case "3 layers is L"                       L  3  3 0 0 0
tier_case "one one-way door forces L"           L  1  1 1 0 0
tier_case "one risk surface forces L"           L  1  1 0 1 0
tier_case "one unconfirmed item forces L"       L  1  1 0 0 1

# The tier rule above is right and stays. What broke on the first real run is the OTHER half of it:
# `unconfirmed > 0` only means "a human should look" if `unconfirmed` means "something that could make
# this bigger than it looks". The first live measurement returned 21 unconfirmed items for a one-file
# docs edit and it was classified L -- correctly, by a rule fed a field that meant something else.
# /da-investigate's job is to name what it could not confirm, so it will essentially always name
# something, and tier S was therefore unreachable in practice. The fix is the field's definition, not
# the threshold, so what is asserted is that the driver ships that definition: an empty list has to be
# stated as a correct and expected answer, or the measurer pads it and every change is L forever.
if grep -q 'an empty list is the' scripts/loop.sh && grep -q 'NOT everything you failed to look at' scripts/loop.sh; then
  ok "the size prompt scopes unconfirmed to what changes the size, and permits an empty list"
else
  no "the size prompt does not permit an empty unconfirmed list -- tier S is unreachable, everything is L"
fi

setup
measurement 1 1 0 0 0
runloop size "a request"
grep -q 'structured_output' "$FAKE_CLAUDE_LOG" >/dev/null 2>&1
grep -q -- '--bare' "$FAKE_CLAUDE_LOG" \
  && no "the driver passed --bare, which disables the hooks and skills the loop is built on" \
  || ok "the driver never passes --bare"
grep -q -- '--dangerously-skip-permissions' "$FAKE_CLAUDE_LOG" \
  && no "the driver passed --dangerously-skip-permissions" \
  || ok "the driver never passes --dangerously-skip-permissions"
grep -q -- '--output-format json' "$FAKE_CLAUDE_LOG" \
  && ok "the driver asks for --output-format json, so cost is recorded" \
  || no "the driver did not request --output-format json -- nothing would measure cost"

# `size` must record its verdict, because `run` reads it back rather than re-deciding.
[[ "$(ledger_field 'tier')" == "S" ]] \
  && ok "size records its tier in the ledger" \
  || no "size did not record its tier (got '$(ledger_field 'tier')')"

# The same distinction on the way in: `size` must refuse when no measurement arrived, rather than
# reading five absent fields as five zeroes and calling an unmeasured change tier S.
setup
printf '{"total_cost_usd":0.01,"num_turns":1,"result":"I looked around a bit"}' > "$FAKE_CLAUDE_DIR/investigate.1.json"
runloop size "a request"
[[ $RC -ne 0 ]] && grep -qi 'no measurement came back' <<<"$OUT" \
  && ok "size refuses when the measurement is missing, instead of defaulting to tier S" \
  || { no "size accepted a reply with no measurement (exit $RC)"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"; }
# "null" is what the reader prints when no line matched at all, so it counts as absent here.
case "$(ledger_field 'tier')" in
  ''|null) ok "and it records no tier, so run still has nothing to read" ;;
  *)       no "size recorded tier '$(ledger_field 'tier')' from a reply that contained no measurement" ;;
esac

# ---------------------------------------------------------------- run preconditions
setup
runloop run
[[ $RC -ne 0 ]] && grep -qi 'no size recorded' <<<"$OUT" \
  && ok "run refuses when size was never taken" \
  || { no "run did not refuse without a recorded size (exit $RC)"; detail "$OUT"; }

setup; measurement 1 1 0 0 0; runloop size "r"
printf 'dirty\n' > "$REPO_DIR/dirty.txt"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'not clean' <<<"$OUT" \
  && ok "run refuses on a dirty working tree" \
  || { no "run did not refuse on a dirty tree (exit $RC)"; detail "$OUT"; }

# Only when the work would actually land on it. With isolation the run moves to its own branch, so
# being on main when you type the command is no longer the problem it was -- but working IN PLACE on
# main still is, and that is the case pinned here.
setup; measurement 1 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
git -C "$REPO_DIR" checkout -q main
runloop run
[[ $RC -ne 0 ]] && grep -qi 'default branch' <<<"$OUT" \
  && ok "run refuses to work in place on the default branch" \
  || { no "run did not refuse on the default branch without isolation (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

setup; measurement 1 1 0 0 0; runloop size "r"
git -C "$REPO_DIR" checkout -q main
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -eq 0 ]] \
  && ok "starting on the default branch is fine once the work is isolated onto its own" \
  || { no "an isolated run refused because the command was typed on main (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# Tier M and L must not start unattended without a plan a human committed.
setup; measurement 6 1 0 0 0; runloop size "r"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'landing plan' <<<"$OUT" \
  && ok "tier M refuses to run without a landing plan" \
  || { no "tier M ran without a landing plan (exit $RC)"; detail "$OUT"; }

# A plan that is merely present but untracked leaves the tree dirty, so the clean-tree precondition
# reaches it first. That is a correct refusal, and it is what the common case actually hits.
setup; measurement 6 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] \
  && ok "an untracked landing plan does not start a run" \
  || { no "run started with an untracked landing plan (exit $RC)"; detail "$OUT"; }

# The plan-is-committed check on its own, reached by making the tree clean while the plan stays
# untracked -- a gitignored plan is the one way those two conditions come apart, and without this
# case the check would be unreachable and could rot green.
setup; measurement 6 1 0 0 0; runloop size "r"
printf 'plan.md\n' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add .gitignore; commit_in_repo ignore
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] && grep -qi 'not committed' <<<"$OUT" \
  && ok "an uncommitted landing plan is not an approved one, even with a clean tree" \
  || { no "run accepted an uncommitted landing plan (exit $RC)"; detail "$OUT"; }

setup; measurement 6 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
printf '\n| 2 | snuck in later | ? | yes |\n' >> "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] \
  && ok "a landing plan edited after the commit does not start a run" \
  || { no "run accepted a plan modified after its commit (exit $RC)"; detail "$OUT"; }

# ---------------------------------------------------------------- the loop, green path
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3           # nothing to fix now
respond pr 1 0.10 3
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "a green landing with nothing to fix reaches a PR"
else
  no "a green landing did not reach a PR (exit $RC)"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"
fi
# `gh stack submit` creates drafts unless told otherwise, and the drafts are not what is wanted here:
# these PRs have already been through the gate and a review pass, so they are ready for a human.
grep -q 'stack submit.*--open' "$FAKE_GH_LOG" \
  && ok "PRs are submitted --open (ready for review), not left as drafts" \
  || no "the stack was not submitted with --open"
grep -q -- '--draft' "$FAKE_GH_LOG" \
  && no "the driver passed --draft" || ok "the driver never passes --draft"
grep -q 'stack init' "$FAKE_GH_LOG" \
  && ok "the run establishes a stack rather than a lone branch" \
  || no "no stack was initialised -- landings would collide on one branch"
# `gh stack init` takes its branches positionally. The driver shipped `gh stack init -b main` and nothing
# else, which headless returns "interactive input required" for -- so the stacked-PR path halted at the
# first landing on the first real run, before implementing anything. The branch name must be an argument.
grep -E 'stack init .*[^-] ?[A-Za-z0-9]' "$FAKE_GH_LOG" | grep -qvE 'stack init( +--?[a-z-]+( +[^ ]+)?)* *$' \
  && ok "stack init names the branch positionally, which is the only non-interactive form" \
  || { no "stack init was called with flags only -- the real extension demands interactive input and fails"
       detail "$(grep 'stack init' "$FAKE_GH_LOG" | head -1)"; }

# --- the driver types the skills; it does not reach past them -----------------
# The whole premise is that this is a person's keystrokes with the person automated away. Where a skill
# owns a step, the driver types the skill. Reaching for the underlying tool instead is how the first
# version ended up calling `gate.sh arm` directly -- and then AGENTS.md invariant 2 got reworded to
# permit it, which is bending the invariant to fit the code.
grep -q '/da-verify' "$FAKE_CLAUDE_LOG" \
  && ok "the driver types /da-verify rather than arming the gate itself" \
  || no "the driver never typed /da-verify -- something else armed the gate, or nothing did"
grep -nE '"\$GATE_SH"[[:space:]]+arm|gate\.sh[[:space:]]+arm' "$LOOP" \
  | grep -qv '^[0-9]*:[[:space:]]*#' \
  && no "loop.sh calls gate.sh arm directly -- invariant 2 says da-verify is the only thing that does" \
  || ok "loop.sh never calls gate.sh arm directly"
# Checked in the source, anchored to the start of the prompt. Grepping the call log would pass on the
# prose version too -- "Use /test-driven-development: ..." contains the string without invoking it, and
# a skill named but not invoked is a skill not applied.
grep -q 'claude_round "/test-driven-development' "$LOOP" \
  && ok "the implement phase opens by typing /test-driven-development, not by describing it" \
  || no "the implement prompt does not begin with /test-driven-development -- naming a skill is not invoking it"
grep -q 'claude_round "/systematic-debugging' "$LOOP" \
  && ok "a repeatedly red check switches to /systematic-debugging" \
  || no "nothing types /systematic-debugging -- a red gate just gets more TDD rounds, which is the patching da-verify says to stop"
grep -q 'claude_round "/receiving-code-review' "$LOOP" \
  && ok "the fix round goes through /receiving-code-review rather than applying findings blindly" \
  || no "nothing types /receiving-code-review -- fix-plan items get implemented without being evaluated"
grep -q '/using-git-worktrees' "$FAKE_CLAUDE_LOG" \
  && ok "the run isolates itself by typing /using-git-worktrees" \
  || no "nothing types /using-git-worktrees -- the loop edits and commits in whatever checkout it was started from"
grep -nE 'git[[:space:]]+worktree[[:space:]]+add' "$LOOP" \
  | grep -qv '^[0-9]*:[[:space:]]*#' \
  && no "loop.sh calls git worktree add directly -- the skill carries the submodule guard, the check-ignore verification and the baseline check" \
  || ok "loop.sh does not reimplement worktree creation"
grep -q '/da-review-all' "$FAKE_CLAUDE_LOG" \
  && ok "review goes through /da-review-all, the repository's single review entry" \
  || no "the driver did not type /da-review-all"
grep -q '/da-fix-plan' "$FAKE_CLAUDE_LOG" \
  && ok "triage goes through /da-fix-plan, which owns the stop condition" \
  || no "the driver did not type /da-fix-plan"
grep -q '/da-pr-describe' "$FAKE_CLAUDE_LOG" \
  && ok "the PR body is written by /da-pr-describe, not by the driver" \
  || no "the driver did not type /da-pr-describe"

# The driver has to work when the skill legitimately declines to create one -- the skill itself
# sanctions working in place on a sandbox permission error or a declined consent. Continuing is correct;
# continuing while claiming isolation would not be.
setup; measurement 1 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -eq 0 ]] && grep -qi 'in place' <<<"$OUT" \
  && ok "when no worktree appears the run continues in place and says so" \
  || { no "a run without isolation did not say it was working in place (exit $RC)"; detail "$(head -6 <<<"$OUT" | tr '\n' ' ')"; }

# Already isolated: the skill's own Step 0 says do not create another, and the driver must not ask for
# one either. `git rev-parse --git-dir != --git-common-dir` is what makes a linked worktree detectable.
setup; measurement 1 1 0 0 0
git -C "$REPO_DIR" worktree add -q "$REPO_DIR/.worktrees/pre" -b pre >/dev/null 2>&1
WT="$REPO_DIR/.worktrees/pre"
OUT="$(cd "$WT" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" size "r" 2>&1)"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
OUT="$(cd "$WT" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" run 2>&1)"; RC=$?
grep -q '/using-git-worktrees' "$FAKE_CLAUDE_LOG" \
  && no "the driver asked for a worktree while already inside one" \
  || ok "already inside a linked worktree, the driver does not create another"

# size and run must agree on which repository this is even across worktrees, or `run` cannot find the
# tier that `size` recorded in the main checkout. The gate solves this by keying repository identity on
# the shared git dir; the ledger does the same.
setup; measurement 1 1 0 0 0; runloop size "r"
git -C "$REPO_DIR" worktree add -q "$REPO_DIR/.worktrees/other" -b other >/dev/null 2>&1
tier_seen="$(cd "$REPO_DIR/.worktrees/other" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" \
  DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 \
  bash "$LOOP" status 2>&1 | grep -o 'tier [SML]' | head -1)"
[[ "$tier_seen" == "tier S" ]] \
  && ok "a size taken in the main checkout is visible from a linked worktree" \
  || no "the tier was invisible from a worktree (saw '$tier_seen') -- run would refuse work that was already sized"

# Swept from the source, not from a call log: `git add -A` would only show up in a log on the run that
# happened to stage something, and the property wanted is that the construct is not there at all.
# Comments are excluded, because loop.sh names the construct in order to say it is forbidden -- a
# sweep that matches its own pattern reports a failure that is not there, which check.sh:56 already
# records happening for real, and which this line did on its first run.
grep -nE 'git[^|;]*add[[:space:]]+(-A|--all|\.)' "$LOOP" \
  | grep -qv '^[0-9]*:[[:space:]]*#' \
  && no "loop.sh contains git add -A/--all/. -- it must stage named paths only" \
  || ok "loop.sh stages named paths, never git add -A"

# No profile means no gate, and `gate.sh verify` reports ok:true in that case -- so a driver that
# trusts `ok` alone treats "nothing was checked" as green. This is the fail-open the whole design is
# against, so it is asserted rather than assumed.
setup; measurement 1 1 0 0 0
rm -f "$PROFILES/probe.json"
runloop size "r"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'no profile' <<<"$OUT" \
  && ok "run refuses when no profile matches -- an unchecked repo is not a green one" \
  || { no "run proceeded with no profile, so nothing was verifying it (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# ---------------------------------------------------------------- red path, round cap
setup; measurement 1 1 0 0 0; runloop size "r"
# Each round changes something and still leaves the check red -- otherwise round_changed_nothing fires
# first, which is a different finding.
respond implement 1 0.10 3; side_effect_all implement 'date >> churn.txt'
side_effect_all debug 'date >> churn.txt'
respond debug 1 0.10 3
runloop run --max-rounds 3
[[ $RC -ne 0 ]] && grep -qi 'round_cap\|round cap' <<<"$OUT" \
  && ok "a check that stays red halts at the round cap" \
  || { no "a permanently red check did not halt at the cap (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "round_cap" ]] \
  && ok "the ledger records round_cap as the reason it stopped" \
  || no "ledger halt_reason was '$(ledger_field 'halt_reason')', not round_cap"
grep -q 'stack submit' "$FAKE_GH_LOG" && no "a halted landing still opened a PR" || ok "a halted landing opens no PR"
# The run reports which check was red before it started, and then never used that answer again --
# STARTED_GREEN was assigned, printed, and read by nothing. On the first real run that line was the only
# way to know the loop had inherited a red installer suite rather than broken it, and it was one dim
# line thirty lines above the halt. Attribution belongs where the loop gives up, not where it starts.
grep -qi 'already red before' <<<"$OUT" \
  && ok "the halt says the check was already red before the run, so an inherited failure is not misread" \
  || no "the halt does not distinguish a check this run broke from one it inherited"

# The switch, observed rather than read out of the source: round 1 writes code, and every round after a
# red gate hands over to root-cause work. Counted, because "it appeared once" would also be true if the
# driver typed it and then went back to piling on TDD rounds.
[[ "$(grep -c 'test-driven-development' "$FAKE_CLAUDE_LOG")" -eq 1 ]] \
  && ok "/test-driven-development is typed exactly once -- round 1 only" \
  || no "/test-driven-development was typed $(grep -c 'test-driven-development' "$FAKE_CLAUDE_LOG") times; a red check should not buy another TDD round"
[[ "$(grep -c 'systematic-debugging' "$FAKE_CLAUDE_LOG")" -ge 2 ]] \
  && ok "every round after the first red gate is /systematic-debugging" \
  || no "only $(grep -c 'systematic-debugging' "$FAKE_CLAUDE_LOG") debugging round(s) across the cap"

# And the other direction, which is the half that makes the first one mean anything: a check that was
# GREEN when the run started and is red at the cap was broken BY this run, and saying "already red" there
# would be a lie that reads like exoneration. An unconditional sentence passes the assertion above.
setup; measurement 1 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"        # keep the gate in REPO_DIR so the fixture can stage it green
: > "$REPO_DIR/GREEN"                     # `test -f GREEN` -- green before the first round
git -C "$REPO_DIR" add -A >/dev/null 2>&1
git -C "$REPO_DIR" commit -qm "green before the run" >/dev/null 2>&1
respond implement 1 0.10 3; side_effect_all implement 'rm -f GREEN; date >> churn.txt'
respond debug 1 0.10 3; side_effect_all debug 'date >> churn.txt'
runloop run --max-rounds 2
grep -qi 'already red before' <<<"$OUT" \
  && no "the halt claimed an inherited failure for a check this run broke -- the sentence is unconditional" \
  || ok "a check the run broke itself is not excused as inherited"

# ---------------------------------------------------------------- the gate gave up
# The state dir is deterministic: <gate>/<basename of repo root>/wt/main. Named here rather than read
# back from `status --json`, because the run has to be the thing that arms the gate.
plant_verdict() { printf 'mkdir -p "%s/repo/wt/main" && printf "2026-08-11T00:00:00Z\\nred\\nprobe-gate\\n3\\n1\\nclaude\\ntest -f GREEN\\n" > "%s/repo/wt/main/VERDICT"\n' "$GATE" "$GATE"; }

# A verdict that already exists when `run` starts must stop it. `gate.sh arm` moves VERDICT to
# VERDICT.prev and restarts the attempt budget, so a driver that armed first would erase exactly the
# record that says the previous work was never verified.
# The gate has to be genuinely armed for its state dir to exist -- planting the file under an
# unarmed gate makes `status` report gave_up:false, the run proceeds, and `arm` consumes the verdict
# while printing a NOTE that contains the word "verdict". A looser assertion here matched that NOTE
# and passed for the wrong reason; the on-disk check below is what caught it.
setup; measurement 1 1 0 0 0; runloop size "r"
( cd "$REPO_DIR" && DOTAGENTS_GATE_DIR="$GATE" bash "$REPO/scripts/gate.sh" arm >/dev/null 2>&1 )
: > "$FAKE_CLAUDE_DIR/no-worktree"
printf '2026-08-11T00:00:00Z\nred\nprobe-gate\n3\n1\nclaude\ntest -f GREEN\n' > "$GATE/repo/wt/main/VERDICT"
respond implement 1 0.10 3
runloop run
[[ $RC -ne 0 ]] && grep -q 'ended in a verdict, not a pass' <<<"$OUT" \
  && ok "a verdict left from a previous run refuses to start another, rather than being armed away" \
  || { no "run started on top of an existing verdict (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
[[ -f "$GATE/repo/wt/main/VERDICT" ]] \
  && ok "the verdict is still on disk afterwards -- refusing did not consume the evidence" \
  || no "the verdict was erased by a run that refused to start"

# A verdict appearing mid-landing, which is the case the gate actually produces.
setup; measurement 1 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3; side_effect implement 1 "$(plant_verdict)"
runloop run --max-rounds 5
[[ $RC -ne 0 ]] && grep -qi 'gave_up\|gave up' <<<"$OUT" \
  && ok "a VERDICT written mid-landing aborts it instead of reading as green" \
  || { no "a mid-landing VERDICT did not abort (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "gave_up" ]] \
  && ok "the ledger distinguishes gave_up from round_cap" \
  || no "ledger halt_reason was '$(ledger_field 'halt_reason')', not gave_up"

# ---------------------------------------------------------------- scorer immutability
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0.10 3
side_effect implement 1 'mkdir -p profiles && printf "{}" > profiles/loosened.json && touch GREEN'
runloop run
[[ $RC -ne 0 ]] && grep -qi 'scorer' <<<"$OUT" \
  && ok "a round that edits the scorer aborts the landing" \
  || { no "a round edited profiles/ and was not stopped (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" && no "a scorer-touching landing opened a PR" || ok "a scorer-touching landing opens no PR"
[[ "$(ledger_field 'halt_reason')" == "scorer_touched" ]] \
  && ok "and the ledger names the scorer as the reason" \
  || no "the scorer-touching landing recorded halt_reason '$(ledger_field 'halt_reason')'"

# Moving a guarded file OUT of a guarded location, rather than editing it in place. `git status
# --porcelain -z` reports a rename as two NUL-separated fields -- the new path, then the old one, with
# no " -> " between them. A parser that strips a 3-character status prefix from every field mangles the
# old path, and the loop can then rename the gate out of the way without being stopped: the new path is
# not guarded, and the old path no longer matches anything.
setup; measurement 1 1 0 0 0; runloop size "r"
mkdir -p "$REPO_DIR/scripts"; printf 'gate\n' > "$REPO_DIR/scripts/gate.sh"
git -C "$REPO_DIR" add scripts/gate.sh; commit_in_repo "add a guarded file"
respond implement 1 0.10 3
side_effect implement 1 'git mv scripts/gate.sh gate-old.sh && touch GREEN'
runloop run
[[ "$(ledger_field 'halt_reason')" == "scorer_touched" ]] \
  && ok "renaming a guarded file out of a guarded path is caught, not just editing it in place" \
  || { no "a round renamed scripts/gate.sh away and was not stopped (halt_reason '$(ledger_field 'halt_reason')')"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# ---------------------------------------------------------------- triage exits
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 1 0           # one finding needs a human decision
runloop run
[[ $RC -ne 0 ]] && grep -qi 'needs_decision' <<<"$OUT" \
  && ok "a finding that needs a decision halts immediately" \
  || { no "needs_decision did not halt the loop (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" && no "needs_decision still opened a PR" || ok "needs_decision opens no PR"

setup; measurement 6 1 0 0 0; runloop size "r"        # 6 files -> tier M, which still gets two rounds
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 2 0 1     # review 1: 2 to fix
respond fix    1 0.20 4                                    # the fix round
respond review 2 0.30 7; respond triage 2 0.05 2 1 0 1     # review 2: still 1
runloop run plan.md
[[ $RC -ne 0 ]] && grep -qi 'review_cap' <<<"$OUT" \
  && ok "tier M: findings still open after the second review halt rather than buying a third" \
  || { no "the review loop did not stop at two rounds (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# A review round is NOT one skill: it is /da-review-all plus a /da-fix-plan triage, and the first real
# landing measured that pair at $5.64 + $2.08 -- against $1.30 for the implementation it was reviewing.
# Two rounds is therefore a ~$15 ceiling on a change that tier S already decided was small enough to skip
# the design phase for. The second round is where that ceiling lives, so tier S does not buy one.
# Measured on that landing: the review had ALREADY self-scaled to the bottom fan-out tier ("inline, no
# find subagents"), so this is not depth being cut -- depth was already minimal. It is the worst case.
setup; measurement 1 1 0 0 0; runloop size "r"        # 1 file -> tier S
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 2 0 1     # review 1: 2 still to fix
respond fix    1 0.20 4
respond review 2 0.30 7; respond triage 2 0.05 2 0 0 0     # would pass, if it were ever reached
runloop run
# Anchored to the END of the line, and every other spelling of this is wrong -- this file's own header
# says so and it still caught me twice. The triage prompt QUOTES "=== /da-review-all の所見 ===" as a
# section header, so a bare grep double-counts. Anchoring to the line START fails because the stub logs
# the whole argv, so every line begins with the flags. Excluding lines that mention da-fix-plan fails
# because the stub logs `$*`, and a multi-line prompt becomes MULTIPLE log lines -- the quoted header is
# a line of its own with no da-fix-plan on it. The invocation is the only line ENDING in the skill name.
rounds="$(grep -c -- '/da-review-all$' "$FAKE_CLAUDE_LOG")"
[[ "$rounds" -eq 1 ]] \
  && ok "tier S buys exactly one review round -- the second is the \$15 ceiling, not more correctness" \
  || no "tier S ran $rounds review rounds; S skips the design phase, so it must not pay the L review bill"
[[ "$(ledger_field 'halt_reason')" == "review_cap" ]] \
  && ok "and open findings still halt it rather than being shipped" \
  || no "tier S with open findings recorded halt_reason '$(ledger_field 'halt_reason')'"

# ---------------------------------------------------------------- one-way doors and the draft cap
setup; measurement 6 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | yes |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run plan.md
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "a one-way landing opened a PR" \
  || ok "a one-way landing stops short of a PR and hands over to a human"
# "nothing was submitted" is true of every early halt too, so the reason is pinned. Without this the
# assertion above passes when the landing died of something unrelated.
[[ "$(ledger_field 'halt_reason')" == "one_way" ]] \
  && ok "and it stopped because it was one-way, not because something else broke" \
  || no "one-way landing recorded halt_reason '$(ledger_field 'halt_reason')'"

setup; measurement 1 1 0 0 0; runloop size "r"
# Head branch names, not PR numbers: the cap counts branches belonging to this stack, so that PRs the
# human opened by hand do not trip a cap meant to bound the loop's own output.
: > "$FAKE_CLAUDE_DIR/no-worktree"     # the cap matches head branches from this checkout
printf 'work\nwork-2\nwork-3\nwork-4\nwork-5\n' > "$FAKE_GH_DIR/pr-list"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "another PR was submitted while the cap's worth were already open" \
  || ok "the open-PR cap stops the loop outrunning the reviewer"
[[ "$(ledger_field 'halt_reason')" == "pr_cap" ]] \
  && ok "and it stopped because of the cap, not because something else broke" \
  || no "the capped landing recorded halt_reason '$(ledger_field 'halt_reason')'"

# ---------------------------------------------------------------- stacking, and its precondition
# Landings are inherently a stack: landing 2 builds on landing 1. The first version of this driver used
# one branch for the whole run, so a second landing's PR would have collided with the first's.
setup; measurement 6 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | first | probe-gate | no |\n| 2 | second | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
# landing 1
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
# landing 2 -- the second occurrence of each phase, so the fixture says which landing it belongs to
respond implement 2 0.20 5; side_effect implement 2 'printf b > b.txt'
respond review 2 0.30 7; respond triage 2 0.05 2 0 0 0; respond pr 2 0.10 3
runloop run plan.md
[[ "$(grep -c 'stack add' "$FAKE_GH_LOG")" -ge 1 ]] \
  && ok "landing 2 gets its own layer via gh stack add, not the same branch as landing 1" \
  || { no "no layer was added for the second landing -- both would target one branch"; detail "$(tr '\n' ';' < "$FAKE_GH_LOG")"; }
[[ "$(grep -c 'stack submit' "$FAKE_GH_LOG")" -ge 2 ]] \
  && ok "each landing is submitted as it completes, so review can start on the lower layer" \
  || no "the stack was submitted $(grep -c 'stack submit' "$FAKE_GH_LOG") time(s) for 2 landings"

# The extension is a hard dependency. Falling back to `gh pr create` would silently produce an
# unstacked PR -- a different shape of output than the one asked for, with nothing saying so.
setup; measurement 1 1 0 0 0; runloop size "r"
: > "$FAKE_GH_DIR/no-stack-ext"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -ne 0 ]] && grep -q 'gh extension install github/gh-stack' <<<"$OUT" \
  && ok "a missing gh-stack extension refuses with the install command, rather than silently unstacking" \
  || { no "a missing gh-stack extension did not stop the run (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# A triage round that comes back with no structured output at all. This is not hypothetical: the flag
# that asks for schema-conforming output is unverified (see the header), so if its name is wrong EVERY
# triage round returns nothing. Defaulting the counts to 0 would read as "the review found nothing to
# fix" and submit a PR that was never triaged -- and the ledger would record fix_now:0, which is
# indistinguishable from a clean review. Absence has to halt.
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2          # no fix_now argument -> the response carries no structured_output
runloop run
[[ $RC -ne 0 ]] \
  && ok "a triage round with no structured output halts instead of reading as 'nothing to fix'" \
  || { no "an unreadable triage was treated as a clean review (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "a PR was submitted on the back of a triage that returned nothing" \
  || ok "no PR is submitted when the triage could not be read"
[[ "$(ledger_field 'halt_reason')" == "triage_unreadable" ]] \
  && ok "the ledger says the triage was unreadable, not that there was nothing to fix" \
  || no "ledger halt_reason was '$(ledger_field 'halt_reason')', not triage_unreadable"

# ================================================================ fix plan 2026-08-11
# Each case below corresponds to a numbered item in docs/fix-plans/2026-08-11-loop-driver.md.

# #3 -- "clean" and "I could not tell" are the same answer from `changed_paths`, and all four consumers
# take the benign branch. Simulated by pointing GIT_DIR at something that is not a git directory, which
# is what an index.lock, a dubious-ownership refusal or a cwd outside a work tree look like from here.
setup; measurement 1 1 0 0 0; runloop size "r"
OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" GIT_DIR=/nonexistent-git-dir \
  DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
  DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" run 2>&1)"; RC=$?
[[ $RC -ne 0 ]] && grep -qi 'could not read the working tree' <<<"$OUT" \
  && ok "#3 an unreadable working tree refuses, rather than reading as clean" \
  || { no "#3 an unreadable tree was treated as clean (exit $RC)"; detail "$(head -3 <<<"$OUT" | tr '\n' ' ')"; }

# #1 -- the vacuous green. A profile whose only gating check is `{files}`-scoped is SKIPPED when the tree
# is clean, and the hook then exits 0 saying "nothing blocking". `verify --json` reports ok:true for
# that, so the driver cannot tell it from a real pass. This shape was never exercised: the hermetic
# profile above is scope:all.
setup; measurement 1 1 0 0 0
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "probe-changed", "cmd": "test -f GREEN {files}", "gate": true,
                "agent_may_run": true, "scope": "changed", "timeout": 10 } ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5      # changes nothing at all, so the tree stays clean
runloop run
# The gate cannot be asked whether anything ran -- verified by hand: on a clean tree with a
# `{files}`-only profile, `verify --json` returns ok:true, check:null and detail "all gating checks
# green", identical to a real pass. So the driver's defence is that a round which changed nothing has
# not earned the green, and that is what is asserted here.
[[ $RC -ne 0 ]] && grep -q 'round_changed_nothing' <<<"$OUT" \
  && ok "#1 a round that changed nothing does not count as verified" \
  || { no "#1 a run where no check executed was treated as verified (exit $RC)"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "round_changed_nothing" ]] \
  && ok "#1 and the ledger names it, so the report does not show a phantom pass" \
  || no "#1 ledger halt_reason was '$(ledger_field 'halt_reason')'"
grep -q 'stack submit' "$FAKE_GH_LOG" \
  && no "#1 a PR was submitted although no gating check ever ran" \
  || ok "#1 no PR is submitted when no check ran"

# #2 -- post_round only looked at exit 143, so an API error, a rate limit or a rejected flag left the
# round's failure invisible and the loop carried on.
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; fails_with implement 1 1
runloop run
[[ "$(ledger_field 'halt_reason')" == "round_failed" ]] \
  && ok "#2 a round that exits non-zero halts instead of being ignored" \
  || no "#2 a failed round recorded halt_reason '$(ledger_field 'halt_reason')'"

# #4 -- tier S skipped every landing-plan validation, but still parsed a plan path if one was passed.
setup; measurement 1 1 0 0 0; runloop size "r"     # tier S
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | snuck in | ? | no |\n' \
  > "$REPO_DIR/plan.md"
printf 'plan.md\n' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add .gitignore; commit_in_repo ignore
runloop run plan.md
[[ $RC -ne 0 ]] && grep -qi 'not committed' <<<"$OUT" \
  && ok "#4 an uncommitted plan is refused even at tier S" \
  || { no "#4 tier S ran an uncommitted landing plan (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# #6 -- STACK_BASE_BRANCH was only set on the `gh stack init` path, so on the resume path (a stack
# already exists, which is the expected state after any halt) the layer names compounded and the
# open-PR cap counted against the wrong branch.
setup; measurement 6 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | one | probe-gate | no |\n| 2 | two | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
: > "$FAKE_GH_DIR/stack"        # a stack already exists -> the short-circuit path
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
respond implement 2 0.20 5; side_effect implement 2 'printf b > b.txt'
respond review 2 0.30 7; respond triage 2 0.05 2 0 0 0; respond pr 2 0.10 3
runloop run plan.md
# The negative assertion needs a companion: "no compounded name appeared" is also true when no layer
# was ever added, which would make this pass while testing nothing.
[[ "$(grep -c 'stack add' "$FAKE_GH_LOG")" -ge 1 ]] \
  && ok "#6 a layer was added on the resume path, so the naming assertion below means something" \
  || { no "#6 no layer was added at all -- the compounding assertion would be vacuous"; detail "$(tr '\n' ';' < "$FAKE_GH_LOG")"; }
grep -qE 'stack add .*-2-3' "$FAKE_GH_LOG" \
  && no "#6 layer names compounded (<branch>-2-3) on the resume path" \
  || ok "#6 layer names do not compound when the stack already exists"

# #7 -- `--budget-usd` with its value omitted spun forever, because `shift 2` with one argument left
# shifts nothing and does not abort under `set -uo pipefail`. A hang is the one outcome this repository
# has a whole suite about.
setup
( cd "$REPO_DIR" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" NO_COLOR=1 \
  bash "$LOOP" run --budget-usd >/dev/null 2>&1 ) &
hang_pid=$!
hang=0; ticks=0
while [[ $ticks -lt 25 ]]; do
  kill -0 "$hang_pid" 2>/dev/null || break
  sleep 0.2; ticks=$((ticks+1))
done
if kill -0 "$hang_pid" 2>/dev/null; then kill -KILL "$hang_pid" 2>/dev/null; hang=1; fi
wait "$hang_pid" 2>/dev/null
[[ $hang -eq 0 ]] \
  && ok "#7 an option with a missing value terminates instead of spinning" \
  || no "#7 'run --budget-usd' with no value did not terminate"

# #10 -- `record` hand-built its JSON, so a check id containing a quote made the whole ledger line
# unparseable. The line that vanishes is the one carrying halt_reason, so the report would say
# "halted nothing" about a landing that halted.
setup; measurement 1 1 0 0 0
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "prob\"e-gate", "cmd": "test -f GREEN", "gate": true,
                "agent_may_run": true, "scope": "all", "timeout": 10 } ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3
runloop run --max-rounds 1
if ledger | node -e '
    let bad = 0, n = 0;
    require("readline").createInterface({input: process.stdin})
      .on("line", (l) => { if (!l.trim()) return; n++; try { JSON.parse(l) } catch { bad++ } })
      .on("close", () => process.exit(bad || n === 0 ? 1 : 0));
  '; then
  ok "#10 a check id containing a quote still produces parseable ledger lines"
else
  no "#10 a quote in a check id broke the ledger line that carries halt_reason"
fi

# The schema is passed INLINE, not as a file path. Measured against claude 2.1.148: `--json-schema`
# takes the schema as a string, and handing it a path does not error -- it hangs forever. Every phase
# that asks for structured output (size, triage) would have hung on first real use.
setup; measurement 1 1 0 0 0; runloop size "r"
grep -qE -- '--json-schema[[:space:]]+\{' "$FAKE_CLAUDE_LOG" \
  && ok "the schema is passed inline as JSON, not as a file path" \
  || { no "--json-schema was not followed by inline JSON -- a path argument hangs the CLI"; detail "$(head -1 "$FAKE_CLAUDE_LOG" | head -c 160)"; }
grep -qE -- '--json-schema[[:space:]]+/' "$FAKE_CLAUDE_LOG" \
  && no "--json-schema was handed a path, which hangs instead of failing" \
  || ok "no path is ever passed to --json-schema"

# A round that never returns. Neither the round cap, the budget, nor the gate can stop a hang, and this
# repository keeps a whole suite about not hanging -- so the driver owns a deadline.
setup; measurement 1 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3; hangs_for implement 1 30
started=$(date +%s)
OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" \
  DOTAGENTS_PROFILES="$PROFILES" DOTAGENTS_REPO="$REPO" DOTAGENTS_LOOP_ROUND_TIMEOUT=3 \
  NO_COLOR=1 bash "$LOOP" run 2>&1)"; RC=$?
elapsed=$(( $(date +%s) - started ))
[[ $RC -ne 0 && $elapsed -lt 25 ]] \
  && ok "a round that never returns is killed by the driver's deadline (${elapsed}s)" \
  || { no "a hanging round was not bounded (exit $RC after ${elapsed}s)"; detail "$(tail -2 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" == "round_timeout" ]] \
  && ok "and the ledger says it timed out, not that it failed or did nothing" \
  || no "the hanging round recorded halt_reason '$(ledger_field 'halt_reason')'"

# ================================================================ checks only a human could run
# `agent_may_run: false` means the repository forbids the AGENT from running it -- dresscode-backend's
# typecheck needs 8 GB of heap and its own skill says never run it. Interactively /da-verify asks the
# user and waits. Unattended there is nobody to ask, and more rounds cannot satisfy it either, so the
# driver has to tell `needs_human` apart from `red`.

setup; measurement 1 1 0 0 0
# One check the agent may run (green), one it may not.
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [
    { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true, "agent_may_run": true, "scope": "all", "timeout": 10 },
    { "id": "probe-heavy", "cmd": "exit 7", "gate": true, "agent_may_run": false,
      "delegate_reason": "needs 8 GB of heap; the repository forbids the agent from running it" }
  ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
[[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" \
  && ok "a check only a human could run does not stop the loop -- it is deferred, not waited on" \
  || { no "the loop halted on a needs_human check (exit $RC)"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'halt_reason')" != "round_cap" ]] \
  && ok "and it did not burn the round cap on something no round can fix" \
  || no "it spent every round on a check the agent is not allowed to run"

# The deferral has to be loud in three places, or the loop quietly ships work whose local verification
# was incomplete. A released gate is not a green gate; neither is a deferred one.
grep -q 'probe-heavy' <<<"$OUT" \
  && ok "the run says which check it did not verify" \
  || { no "the deferred check is not named in the output"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }
ledger | grep -q 'probe-heavy' \
  && ok "the ledger records it, so report can show it later" \
  || no "the ledger does not record the deferred check"
grep -q 'da-pr-describe' "$FAKE_CLAUDE_LOG" && grep -q 'probe-heavy' "$FAKE_CLAUDE_LOG" \
  && ok "and /da-pr-describe is told, so the PR body can say it is CI's job" \
  || no "the PR body would not mention that a check was never run locally"

# A check the agent MAY run and that fails is still red. Deferral must not swallow real failures.
setup; measurement 1 1 0 0 0
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [
    { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true, "agent_may_run": true, "scope": "all", "timeout": 10 },
    { "id": "probe-heavy", "cmd": "exit 7", "gate": true, "agent_may_run": false,
      "delegate_reason": "needs 8 GB of heap" }
  ],
  "timeout_total": 60 }
JSON
runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.10 3; side_effect_all implement 'date >> churn.txt'
side_effect_all debug 'date >> churn.txt'; respond debug 1 0.10 3
runloop run --max-rounds 2
[[ $RC -ne 0 ]] \
  && ok "a red check the agent CAN run still stops the loop -- deferral does not swallow it" \
  || { no "deferral made a genuinely red check look green (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# ================================================================ the single entry point
# `loop.sh "<request>"` is the only thing anyone should have to remember. Typing it repeatedly advances
# one step: size if unsized, hand over if the design phase is yours, run when there is something to run.

# Unsized + small -> it sizes and goes straight on to running.
setup
measurement 1 1 0 0 0
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop "usage に design を1行足す"
[[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" \
  && ok "one entry point: an unsized small change is sized and run in one command" \
  || { no "the single entry point did not carry a tier-S change through (exit $RC)"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
[[ "$(ledger_field 'phase')" != "size" ]] \
  && ok "and it did not stop after sizing" || no "it sized and stopped"

# Unsized + large -> it sizes, then hands the design phase over. Not an error: it advanced as far as it
# could, and the next step belongs to a human.
setup; measurement 20 3 1 1 1
runloop "大きいこと"
[[ $RC -eq 0 ]] \
  && ok "a large change exits 0 -- handing over is not a failure" \
  || { no "handing the design phase over exited $RC"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -qE 'あなたの手番|your turn' <<<"$OUT" \
  && ok "and it says plainly that it is your turn" \
  || { no "it did not say whose turn it is"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }
for want in grilling writing-plans da-design-review; do
  grep -q "$want" <<<"$OUT" && ok "  names /$want" || no "  omitted /$want"
done
grep -q 'stack submit' "$FAKE_GH_LOG" && no "it opened a PR without a design phase" || ok "and opens nothing"

# Same command again, now that a landing plan is committed -> it finds the plan itself and runs.
# Nobody should have to remember the path.
mkdir -p "$REPO_DIR/docs/plans"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/docs/plans/thing.md"
git -C "$REPO_DIR" add docs/plans/thing.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop "大きいこと"
[[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" \
  && ok "the same command finds the committed landing plan and runs it" \
  || { no "it did not pick up the committed plan (exit $RC)"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }

# Two candidate plans -> it refuses rather than guessing which one you meant.
# Same request both times, or the second call re-measures (a changed request must re-size) and consumes
# an investigate response the fixture did not script.
setup; measurement 20 3 0 0 0; runloop size "大きいこと"
mkdir -p "$REPO_DIR/docs/plans"
for n in one two; do
  printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
    > "$REPO_DIR/docs/plans/$n.md"
done
git -C "$REPO_DIR" add docs/plans; commit_in_repo plans
runloop "大きいこと"
[[ $RC -ne 0 ]] && grep -q 'docs/plans/one.md' <<<"$OUT" && grep -q 'docs/plans/two.md' <<<"$OUT" \
  && ok "two candidate plans are listed rather than one being guessed at" \
  || { no "it did not refuse on an ambiguous plan (exit $RC)"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }

# ================================================================ the all-skills flow

# `loop.sh design` must never prompt: test-non-interactive.sh asserts there is no interactive path, and
# the design phase is attended, so the temptation to ask is exactly here.
setup; measurement 1 1 0 0 0; runloop size "r"
runloop design
[[ $RC -eq 0 ]] && ok "design exits 0" || { no "design exited $RC"; detail "$(tail -2 <<<"$OUT" | tr '\n' ' ')"; }
# "design does not prompt" is NOT asserted here. test-non-interactive.sh already sweeps every
# scripts/*.sh for terminal reads and runs `loop.sh design` with stdin closed, so a second copy of that
# rule here would be two implementations of one check -- and the first version of it literally contained
# the forbidden pattern as a string, which made that suite report this file as an offender.

# Tier decides the sequence, and the tiers differ in DEPTH of human involvement, not in whether one is
# present. S has no design phase at all.
setup; measurement 1 1 0 0 0; runloop size "r"      # S
runloop design
grep -qi 'no design phase\|設計フェーズ' <<<"$OUT" \
  && ok "design at tier S says there is no design phase" \
  || { no "tier S design did not say the phase is empty"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"; }

setup; measurement 20 3 1 1 1; runloop size "r"     # L
runloop design
for want in grilling writing-plans da-design-review; do
  grep -q "$want" <<<"$OUT" \
    && ok "design at tier L names /$want" \
    || no "design at tier L omitted /$want"
done

# The three stages that leave nothing on disk must be reported as uncheckable rather than shown green.
grep -qiE 'cannot be checked|検査でき' <<<"$OUT" \
  && ok "design states which stages it cannot verify" \
  || { no "design did not say anything is unverifiable -- it would read as all-clear"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }

# The one artifact with a strong signal: writing-plans' file carries a mandatory header.
setup; measurement 20 3 0 0 0; runloop size "r"     # L via layers/files
mkdir -p "$REPO_DIR/docs/superpowers/plans"
printf '# Thing Implementation Plan\n\n**Goal:** x\n**Architecture:** y\n\n## Global Constraints\n\n- [ ] step one\n' \
  > "$REPO_DIR/docs/superpowers/plans/2026-08-11-thing.md"
runloop design
grep -q '2026-08-11-thing.md' <<<"$OUT" \
  && ok "design finds the plan file writing-plans left behind" \
  || { no "design did not report the plan file"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }

# A file at that path WITHOUT the mandatory header is not a plan -- writing-plans requires the header,
# so accepting any .md there would let an empty file satisfy the gate.
setup; measurement 20 3 0 0 0; runloop size "r"
mkdir -p "$REPO_DIR/docs/superpowers/plans"
printf 'just some notes\n' > "$REPO_DIR/docs/superpowers/plans/2026-08-11-notes.md"
runloop design
grep -qiE 'header|見出し|not a plan' <<<"$OUT" \
  && ok "a file without the mandatory header is not accepted as a plan" \
  || { no "design accepted a headerless file as a plan"; detail "$(tail -6 <<<"$OUT" | tr '\n' ' ')"; }

# implement splits by tier. M/L have a committed plan, so /executing-plans is the right skill; S has no
# plan at all, so it types /test-driven-development.
setup; measurement 6 1 0 0 0; runloop size "r"       # M
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run plan.md
grep -q '/executing-plans' "$FAKE_CLAUDE_LOG" \
  && ok "tier M implements through /executing-plans" \
  || { no "tier M did not type /executing-plans"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
# The executing-plans prompt MENTIONS /test-driven-development on purpose -- that mention is the only
# thing guaranteeing TDD, since executing-plans delegates to whatever the plan's steps say. So the
# assertion is that the TDD phase never RAN, not that the string is absent.
[[ ! -f "$FAKE_CLAUDE_DIR/implement.counter" ]] \
  && ok "and the TDD phase never ran -- one implement skill per round" \
  || no "tier M ran both /executing-plans and the /test-driven-development phase"
grep -q 'executing-plans.*\n*.*test-driven-development\|Use /test-driven-development' "$FAKE_CLAUDE_LOG" \
  && ok "the executing-plans prompt states TDD per step, which is the only guarantee of it" \
  || no "the executing-plans prompt does not require TDD -- executing-plans alone does not imply it"

setup; measurement 1 1 0 0 0; runloop size "r"       # S
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
grep -q '/test-driven-development' "$FAKE_CLAUDE_LOG" \
  && ok "tier S implements through /test-driven-development (there is no plan to execute)" \
  || no "tier S did not type /test-driven-development"
grep -q '/executing-plans' "$FAKE_CLAUDE_LOG" \
  && no "tier S typed /executing-plans with no plan file" || ok "and not /executing-plans"

# The second reviewer is metered on risk, and its FULL report reaches triage. Counts alone would buy
# zero coverage, which is the entire reason for a differently-built second reviewer.
setup; measurement 3 1 0 2 0; runloop size "r"       # risk_surfaces = 2 -> L
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7
respond findbugs 1 0.40 6
respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run plan.md
grep -q '/find-bugs' "$FAKE_CLAUDE_LOG" \
  && ok "a landing touching a risk surface gets the second reviewer" \
  || { no "no second reviewer on a risk surface"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'da-fix-plan' "$FAKE_CLAUDE_LOG" && grep -q 'find-bugs の所見\|second reviewer' "$FAKE_CLAUDE_LOG" \
  && ok "and its report text is handed to /da-fix-plan, not just a count" \
  || no "the second reviewer's findings never reached triage"

setup; measurement 3 1 0 0 0; runloop size "r"       # no risk surface
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
grep -q '/find-bugs' "$FAKE_CLAUDE_LOG" \
  && no "the second reviewer ran with no risk surface -- review is where the cost is" \
  || ok "no risk surface, no second reviewer"

# ---------------------------------------------------------------- interruption
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0 0; fails_with implement 1 143
runloop run
[[ "$(ledger_field 'halt_reason')" == "interrupted" ]] \
  && ok "exit 143 is recorded as interrupted, not as a failure" \
  || no "exit 143 recorded halt_reason '$(ledger_field 'halt_reason')'"

# ---------------------------------------------------------------- the ledger itself
setup; measurement 1 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 2; respond pr 1 0.10 3
runloop run
if ledger | node -e '
    let n = 0, bad = 0;
    require("readline").createInterface({input: process.stdin})
      .on("line", (l) => { if (!l.trim()) return; n++;
        try { const o = JSON.parse(l);
          for (const k of ["ts","repo","branch","phase"]) if (!(k in o)) bad++;
        } catch { bad++ } })
      .on("close", () => process.exit(bad || n === 0 ? 1 : 0));
  '; then
  ok "every ledger line is valid JSON carrying ts, repo, branch and phase"
else
  no "the ledger contains malformed or fieldless lines"; detail "$(ledger | tail -2 | tr '\n' ' ')"
fi

# The whole point of the phase field: cost has to be attributable, because the review side can be
# the overwhelming majority of it.
if runloop report; [[ $RC -eq 0 ]] && grep -qi 'cost by phase' <<<"$OUT"; then
  ok "report splits cost by phase"
else
  no "report did not split cost by phase (exit $RC)"; detail "$(head -8 <<<"$OUT" | tr '\n' ' ')"
fi
if grep -qi 'cost per accepted' <<<"$OUT"; then
  ok "report states cost per accepted landing"
else
  no "report omitted cost per accepted landing"
fi

# ---------------------------------------------------------------- the ledger is never trimmed
setup
node -e '
  const fs = require("fs");
  const l = [];
  for (let i = 0; i < 400; i++) l.push(JSON.stringify({ts:"t",repo:"r",branch:"b",phase:"implement"}));
  fs.writeFileSync(process.argv[1], l.join("\n") + "\n");
' "$LOOPDIR/ledger.jsonl"
measurement 1 1 0 0 0; runloop size "r"
lines="$(wc -l < "$LOOPDIR/ledger.jsonl" | tr -d ' ')"
[[ "$lines" -gt 400 ]] \
  && ok "the ledger is append-only and never trimmed ($lines lines)" \
  || no "the ledger lost lines (400 planted, $lines left) -- trace.log self-trims, this must not"

echo
if (( fail )); then
  printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
