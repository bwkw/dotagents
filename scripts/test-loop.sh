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
# One argument per line, so ADJACENCY is checkable. `$*` above flattens, and the tool grant contains
# spaces (`Bash(git diff:*)`), which makes "what came directly before the prompt" unanswerable there.
# That distinction is not cosmetic: `--allowedTools` is VARIADIC in the real CLI, so a prompt sitting
# directly after it is eaten as another tool name and `claude` dies with "Input must be provided".
printf '%s\n' "$@" >> "$FAKE_CLAUDE_ARGV"
printf -- '---\n' >> "$FAKE_CLAUDE_ARGV"

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
  "Write one reply per review comment"*) phase=reply ;;
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
# A real round says WHY it failed on stderr, and the driver used to send that to /dev/null -- which is
# why the 10th run's errored implement round could not be re-diagnosed afterwards. The stub can now
# produce it, so "is stderr kept?" is answerable by a test rather than by reading the redirect.
[[ -f "$FAKE_CLAUDE_DIR/$phase.$n.err" ]] && cat "$FAKE_CLAUDE_DIR/$phase.$n.err" >&2
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
  "stack push")
    # A REAL push to the fixture's bare remote. It used to be a no-op, and this file already argues the
    # opposite for `stack submit`: a driver whose push is stubbed is a driver whose push is untested.
    # The stale-ref rejection below only exists at the git level, so a no-op could never show it.
    # `--force-with-lease`, because that is what makes the real failure possible: the lease is checked
    # against the local remote-tracking ref, so a STALE one rejects the push with "stale info" even
    # though the remote is fine. A plain push cannot produce it, and a stub that cannot produce it
    # cannot test the fix.
    git push --force-with-lease -q origin HEAD 2>/dev/null || exit 1 ;;
  "stack submit")
    # The real extension prints a URL when it CREATES the PR and prose when it does not:
    # "PR #45 for <branch> is up to date". Both are success. The fixture switches to the second shape,
    # which is what caught the driver scraping stdout for a URL.
    if [[ -f "$FAKE_GH_DIR/submit-no-url" ]]; then
      printf 'Checking stack state...\nPR #7 for some-branch is up to date\n'
    else
      printf 'https://github.com/probe/x/pull/7\n'
    fi ;;
  "pr view")
    [[ -f "$FAKE_GH_DIR/no-pr" ]] && exit 1
    printf 'https://github.com/probe/x/pull/7\n' ;;
  "pr list")
    cat "$FAKE_GH_DIR/pr-list" 2>/dev/null || printf '' ;;
  "pr checks")
    # --json asks for STATES. The driver must decide from them, not from the exit code: `gh` documents
    # exit 1 as "failed for any reason", which lumps a real failure together with "no checks exist yet".
    # The driver asks with `--jq .[].state`, so what comes back is one STATE PER LINE. The fixture holds
    # exactly that (an empty file = this PR reports no checks), because a stub that returns raw JSON here
    # would hand the driver a string that is not any state -- which its own "unknown is not green" rule
    # then correctly reads as red, failing every case for the wrong reason.
    if [[ "$*" == *--json* ]]; then
      if [[ -f "$FAKE_GH_DIR/checks-states" ]]; then cat "$FAKE_GH_DIR/checks-states"
      else printf 'SUCCESS\n'; fi
      exit 0
    fi
    # Exit codes match the real thing: 0 all green, 1 something failed, 8 still running. Scripted per
    # call so "red, then green after a fix" is expressible -- one file per attempt, falling back to a
    # default, exactly like the claude stub.
    c=1
    [[ -f "$FAKE_GH_DIR/checks.counter" ]] && c=$(cat "$FAKE_GH_DIR/checks.counter")
    printf '%s' "$((c+1))" > "$FAKE_GH_DIR/checks.counter"
    f="$FAKE_GH_DIR/checks.$c"
    [[ -f "$f" ]] || f="$FAKE_GH_DIR/checks"
    if [[ -f "$f" ]]; then cat "$f.out" 2>/dev/null; exit "$(cat "$f")"; fi
    printf 'all checks passing\n'; exit 0 ;;
  "api "*)
    # Reads return the fixture; writes are only logged. The log is what the tests assert on, because
    # "the driver posted a reply" and "the driver resolved a thread" have to be distinguishable.
    case "$*" in
      *--method\ POST*|*-X\ POST*) exit 0 ;;
      *graphql*) exit 0 ;;
      *comments*) cat "$FAKE_GH_DIR/pr-comments" 2>/dev/null || printf '[]\n' ;;
      *) printf '' ;;
    esac ;;
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
  FAKE_CLAUDE_ARGV="$root/claude.argv"
  mkdir -p "$REPO_DIR" "$GATE" "$PROFILES" "$LOOPDIR" "$FAKE_CLAUDE_DIR" "$FAKE_GH_DIR"
  : > "$FAKE_CLAUDE_LOG"; : > "$FAKE_GH_LOG"; : > "$FAKE_CLAUDE_ARGV"
  export FAKE_CLAUDE_DIR FAKE_GH_DIR FAKE_CLAUDE_LOG FAKE_GH_LOG FAKE_CLAUDE_ARGV
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
measurement() { # <files> <layers> <one_way> <risk> <unconfirmed> [layer-names-csv] [unverified_claims]
  # The two trailing arguments are optional, so every existing fixture keeps meaning what it said.
  # `layer-names-csv` matters because the driver now picks the review skill by the recorded layer NAME:
  # a fixture with generic "layer0" must keep landing on the dispatcher, and that is asserted below
  # rather than assumed.
  local files="$1" layers="$2" oneway="$3" risk="$4" unconf="$5" names="${6:-}" claims="${7:-0}"
  node -e '
    const [f, l, o, r, u] = process.argv.slice(1, 6).map(Number);
    const names = process.argv[6] || "", claims = Number(process.argv[7] || 0);
    const arr = (n, p) => Array.from({length: n}, (_, i) => p + i);
    process.stdout.write(JSON.stringify({
      total_cost_usd: 0.01, num_turns: 2, result: "ok",
      structured_output: {
        files: arr(f, "src/f"),
        layers: names ? names.split(",").filter(Boolean) : arr(l, "layer"),
        one_way: arr(o, "door"), risk_surfaces: arr(r, "surface"),
        unconfirmed: arr(u, "unknown"),
        unverified_claims: arr(claims, "claim"),
      },
    }));
  ' "$files" "$layers" "$oneway" "$risk" "$unconf" "$names" "$claims" > "$FAKE_CLAUDE_DIR/investigate.1.json"
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
# EVERY fixture helper lives in this block, and that is the point rather than tidiness. Bash defines a
# function when the definition is *executed*, so a helper declared beside the tests that introduced it is
# an undefined command for every case above it -- which returns empty and writes no fixture, and the
# assertion then fails against a driver that was doing the right thing all along. That trap was hit
# twice here: once with `round_budget`, once with `truncated`. Both times the implementation was correct
# and the test was lying. Add new helpers HERE, never next to the case that needs them.
respond() { # <phase> <n> <cost> <turns> [fix_now] [needs_decision] [decline] [unverified]
  node -e '
    const [c, t, fn, nd, dc, uv] = process.argv.slice(1);
    const o = { total_cost_usd: Number(c), num_turns: Number(t), result: "done" };
    if (fn !== "-") o.structured_output = {
      fix_now: Number(fn), needs_decision: Number(nd), decline: Number(dc),
      unverified: Number(uv) };
    process.stdout.write(JSON.stringify(o));
  ' "$3" "$4" "${5:--}" "${6:-0}" "${7:-0}" "${8:-0}" > "$FAKE_CLAUDE_DIR/$1.$2.json"
}
green_pr() { # the common fixture: a landing that reaches a PR
  measurement 6 1 0 0 0; runloop size "r"
  respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
  respond review 1 0.30 7
  respond triage 1 0.05 2 0 0 3
  respond pr 1 0.10 3
}

truncated() { # <phase> <n> <subtype> -- a round that stopped early: exit 0, partial `result`
  printf '{"total_cost_usd":0.30,"num_turns":50,"subtype":"%s","result":"partial report"}' "$3" \
    > "$FAKE_CLAUDE_DIR/$1.$2.json"
}
errored() { # <phase> <n> -- a round that ERRORED: is_error true, subtype "success", exit 1.
  # Measured on the 10th run: the implement round came back like this at $1.2784895 / 24 turns and the
  # driver called it "cut off at its ceiling (subtype: success)", then advised raising a ceiling that
  # does not exist for that phase.
  printf '{"total_cost_usd":0.30,"num_turns":24,"subtype":"success","is_error":true,"result":"partial"}' \
    > "$FAKE_CLAUDE_DIR/$1.$2.json"
  printf '%s\n' 1 > "$FAKE_CLAUDE_DIR/$1.$2.exit"
  printf '%s\n' "${3:-}" > "$FAKE_CLAUDE_DIR/$1.$2.err"   # what a real round would say on stderr
}
side_effect() { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.sh"; }   # <phase> <n> <shell>
side_effect_all() { printf '%s\n' "$2" > "$FAKE_CLAUDE_DIR/$1.sh"; }   # <phase> <shell>, every round
fails_with()  { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.exit"; } # <phase> <n> <exit-code>
hangs_for()   { printf '%s\n' "$3" > "$FAKE_CLAUDE_DIR/$1.$2.sleep"; } # <phase> <n> <seconds>

runloop() { # <args...> -> stdout+stderr in $OUT, status in $RC
  # The CI waits are seconds in production and must be ~nothing here, or every case that reaches the CI
  # phase costs the suite its grace window in real time.
  OUT="$(cd "$REPO_DIR" && PATH="$BIN:$PATH" \
    DOTAGENTS_LOOP_CI_WAIT="${DOTAGENTS_LOOP_CI_WAIT:-20}" DOTAGENTS_LOOP_CI_GRACE="${DOTAGENTS_LOOP_CI_GRACE:-5}" \
    DOTAGENTS_LOOP_DIR="$LOOPDIR" DOTAGENTS_GATE_DIR="$GATE" DOTAGENTS_PROFILES="$PROFILES" \
    DOTAGENTS_REPO="$REPO" NO_COLOR=1 bash "$LOOP" "$@" 2>&1)"
  RC=$?
}

# Defined up here with the other helpers, not down beside the ceiling tests that introduced it. Bash
# defines a function when the definition is *executed*, so a helper declared halfway down the file is an
# undefined command for every case above it -- which returns empty, and an assertion on empty reads as
# "the driver did not pass a ceiling". That is exactly how the /find-bugs case first failed: the driver
# was correct and the helper did not exist yet.
round_budget() { # <phase-marker> -> the --max-budget-usd value on that phase's call, empty when absent
  grep -- "$1" "$FAKE_CLAUDE_LOG" | grep -- '--max-budget-usd' \
    | sed -E 's/.*--max-budget-usd[[:space:]]+([0-9.]+).*/\1/' | head -1
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
# The four rungs, at every boundary. The file counts tripled because the old ladder put a five-file
# change in the same rung as a fifteen-file one, and the owner's own reading of real changes is that
# ten files is still small. `>30` closes the top rather than "~50": a threshold written at 50 would
# leave 31-49 falling through to M silently.
tier_case "5 files, 1 layer, nothing else"     XS  5  1 0 0 0
tier_case "6 files crosses into S"              S  6  1 0 0 0
tier_case "10 files is still S"                 S 10  1 0 0 0
tier_case "11 files crosses into M"             M 11  1 0 0 0
tier_case "30 files is still M"                 M 30  1 0 0 0
tier_case "31 files crosses into L"             L 31  1 0 0 0
tier_case "2 layers is M"                       M  3  2 0 0 0
tier_case "3 layers is L"                       L  3  3 0 0 0
tier_case "one one-way door forces L"           L  1  1 1 0 0

# --- what `risk_surfaces` and `unconfirmed` are worth, revised --------------------
# These two used to force L, and the ladder collapsed: on a real product repository almost every
# backend change touches authorization, and /da-investigate names something under `unconfirmed`
# essentially always, so **everything was L** and nothing could run unattended. Two separate errors:
#
#   `risk_surfaces` was CHARGED TWICE. It already buys the second reviewer at loop.sh:900 --
#   /find-bugs runs only when it is non-zero. Making the same signal also force the full attended
#   design phase pays for one measurement with two different budgets.
#
#   `unconfirmed` means "the size measurement is not reliable". That is a reason not to run
#   unattended; it is NOT evidence that the change is wide or irreversible, which is what L buys a
#   human for. Its own field definition was already fixed once (#35) to permit an empty list, and it
#   still returned 9 for a one-file docs edit -- so the threshold, not only the definition, was wrong.
#
# `one_way` keeps forcing L, and that one is not up for revision: an irreversible step is exactly the
# thing a human must see before it ships.
tier_case "a risk surface alone is M, not L"    M  1  1 0 1 0
# CHANGED with the XS rung: the floor moves from M to S. `unconfirmed > 0` means "this measurement may
# be wrong", which is a reason not to drop the fix machinery -- and it is NOT evidence the change is wide,
# which is what M buys a human for. Left at M, /da-investigate names something essentially always, so XS
# would be unreachable in practice and the docs edit that motivated the whole rung would stay at M and
# buy nothing. Same two-axis argument as risk_surfaces, one rung lower.
tier_case "one unconfirmed item floors at S"    S  1  1 0 0 1
tier_case "risk and unconfirmed together, M"    M  1  1 0 3 4
tier_case "one-way still outranks both"         L  1  1 1 1 1

# `unverified_claims` is the other half of the split: things the REQUEST asserts that could not be
# confirmed. It is recorded and printed because it tells you the request needs fixing, but it must not
# move the tier -- conflating it with `unconfirmed` is what put a one-file docs edit in L.
setup
measurement 6 1 0 0 0 "" 9
runloop size "a request making nine claims"
if [[ $RC -eq 0 ]] && grep -qE 'tier[[:space:]]+S\b' <<<"$OUT"; then
  ok "nine unverified request claims do not move the tier (S)"
else
  no "unverified_claims moved the tier (exit $RC)"; detail "$(head -3 <<<"$OUT" | tr '\n' ' ')"
fi
[[ "$(ledger_field unverified_claims)" == "9" ]] \
  && ok "and the count is recorded, so the request can be fixed" \
  || no "unverified_claims was not recorded (got '$(ledger_field unverified_claims)')"

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
measurement 6 1 0 0 0
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

# ---------------------------------------------------------------- the tier ladder is answered
# THE SAFETY NET FOR ADDING A RUNG. Seven sites used to compare the tier letter and each meant something
# different; `[[ "$tier" != "S" ]]` is true for a tier that does not exist yet and quietly demands a
# landing plan that will never be written. This repository's record says adding a tier "broke three
# places silently" -- so the ladder is declared on a marker line and every predicate must answer every
# tier on it.
#
# Written while the ladder was still S/M/L, precisely so that it would go RED when a rung was added and
# a predicate was not extended. A test that arrives with the feature it guards proves nothing about the
# moment the feature lands.
#
# **IT FIRED.** Adding XS took 61 assertions red, and the one place not armed was a decision the test
# could not see: the lean review budgets were an inline `case` rather than a named predicate, so the
# by-name scan walked straight past it. That is now `tier_gets_lean_budgets`. The lesson generalises past
# this file: **a decision the tests cannot enumerate is a decision that gets forgotten exactly once per
# new tier.**
ladder_tiers()     { sed -n 's/^# dotagents:tier-ladder //p' "$LOOP" | head -1; }
tier_predicates()  { grep -oE '^tier_[a-z_]+\(\)|^review_may_skip_dispatcher\(\)' "$LOOP" \
                       | sed 's/()//' | grep -v '^tier_die$'; }

marker="$(ladder_tiers)"
[[ -n "$marker" ]] \
  && ok "the ladder is declared on a dotagents:tier-ladder marker ($marker)" \
  || no "no dotagents:tier-ladder marker in loop.sh -- removing it removes this whole check"

preds="$(tier_predicates)"
[[ -n "$preds" ]] \
  && ok "the tier predicates are discoverable by name ($(wc -w <<<"$preds" | tr -d ' ') of them)" \
  || no "found no tier predicates to check"

# Every (tier x predicate) pair must answer without dying. Detected by the MESSAGE, not the exit code:
# `die` exits 1 (loop.sh:176) and so does a legitimate "no", so a code-based check reads a fall-through
# as an answer. That was the first version of this test and it would have passed on a broken predicate.
# The predicates are EXTRACTED, never sourced. `source "$LOOP"` runs loop.sh's top-level dispatcher,
# which inherits this script's positional parameters -- so sourcing it to ask a pure question can start a
# real `run`. The first version of this helper did exactly that and hung the suite for ten minutes.
tier_defs="$TMP/tier-defs.sh"
{ printf 'die() { printf "loop: %%s\\n" "$1" >&2; exit 1; }\n'
  sed -n '/^tier_die() {/,/^}/p' "$LOOP"
  grep -E '^(tier_[a-z_]+|review_may_skip_dispatcher)\(\) *\{ case' "$LOOP"
} > "$tier_defs"
tier_answer() { # <predicate> <tier> -> prints "died" or "answered"
  local err
  err="$( ( . "$tier_defs"; "$1" "$2" >/dev/null ) 2>&1 )"
  case "$err" in *"unknown tier"*) printf died ;; *) printf answered ;; esac
}
unanswered=""
for _t in $marker; do
  for _p in $preds; do
    [[ "$(tier_answer "$_p" "$_t")" == "answered" ]] || unanswered="$unanswered $_p($_t)"
  done
done
[[ -z "$unanswered" ]] \
  && ok "every predicate answers every declared tier" \
  || no "these (predicate, tier) pairs fall through:$unanswered"

# ...and the fall-through must be fatal rather than plausible. A predicate whose default returns 0 or 1
# is the bug this section exists to prevent: it would answer a tier nobody thought about.
silent=""
for _p in $preds; do
  grep -A 1 "^$_p()" "$LOOP" | grep -q 'tier_die' || silent="$silent $_p"
done
[[ -z "$silent" ]] \
  && ok "and an unknown tier is fatal in every predicate, not merely plausible" \
  || no "these predicates have a silent default:$silent"

# A tier that is NOT on the ladder must die, proving the net is live rather than vacuous. This probe used
# to name XS, and it FLIPPED when XS was added -- which is exactly what it was for: the loop above then
# began requiring an XS arm in every predicate, and found the one place it was missing (the review
# budgets, which were an inline `case` the name-based discovery could not see). The probe now names a
# rung nobody has proposed, so it keeps testing the net rather than the last rung added.
[[ "$(tier_answer tier_needs_landing_plan XXL)" == "died" ]] \
  && ok "an undeclared tier (XXL) is refused -- the net is live, not vacuous" \
  || no "tier_needs_landing_plan answered XXL, which is not on the ladder"

# ---------------------------------------------------------------- run preconditions
setup
runloop run
[[ $RC -ne 0 ]] && grep -qi 'no size recorded' <<<"$OUT" \
  && ok "run refuses when size was never taken" \
  || { no "run did not refuse without a recorded size (exit $RC)"; detail "$OUT"; }

setup; measurement 6 1 0 0 0; runloop size "r"
printf 'dirty\n' > "$REPO_DIR/dirty.txt"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'not clean' <<<"$OUT" \
  && ok "run refuses on a dirty working tree" \
  || { no "run did not refuse on a dirty tree (exit $RC)"; detail "$OUT"; }

# Only when the work would actually land on it. With isolation the run moves to its own branch, so
# being on main when you type the command is no longer the problem it was -- but working IN PLACE on
# main still is, and that is the case pinned here.
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
git -C "$REPO_DIR" checkout -q main
runloop run
[[ $RC -ne 0 ]] && grep -qi 'default branch' <<<"$OUT" \
  && ok "run refuses to work in place on the default branch" \
  || { no "run did not refuse on the default branch without isolation (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

setup; measurement 6 1 0 0 0; runloop size "r"
git -C "$REPO_DIR" checkout -q main
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -eq 0 ]] \
  && ok "starting on the default branch is fine once the work is isolated onto its own" \
  || { no "an isolated run refused because the command was typed on main (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# Tier M and L must not start unattended without a plan a human committed.
setup; measurement 11 1 0 0 0; runloop size "r"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'landing plan' <<<"$OUT" \
  && ok "tier M refuses to run without a landing plan" \
  || { no "tier M ran without a landing plan (exit $RC)"; detail "$OUT"; }

# A plan that is merely present but untracked leaves the tree dirty, so the clean-tree precondition
# reaches it first. That is a correct refusal, and it is what the common case actually hits.
setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] \
  && ok "an untracked landing plan does not start a run" \
  || { no "run started with an untracked landing plan (exit $RC)"; detail "$OUT"; }

# The plan-is-committed check on its own, reached by making the tree clean while the plan stays
# untracked -- a gitignored plan is the one way those two conditions come apart, and without this
# case the check would be unreachable and could rot green.
setup; measurement 11 1 0 0 0; runloop size "r"
printf 'plan.md\n' > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add .gitignore; commit_in_repo ignore
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] && grep -qi 'not committed' <<<"$OUT" \
  && ok "an uncommitted landing plan is not an approved one, even with a clean tree" \
  || { no "run accepted an uncommitted landing plan (exit $RC)"; detail "$OUT"; }

setup; measurement 11 1 0 0 0; runloop size "r"
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
printf '\n| 2 | snuck in later | ? | yes |\n' >> "$REPO_DIR/plan.md"
runloop run plan.md
[[ $RC -ne 0 ]] \
  && ok "a landing plan edited after the commit does not start a run" \
  || { no "run accepted a plan modified after its commit (exit $RC)"; detail "$OUT"; }

# ---------------------------------------------------------------- the loop, green path
setup; measurement 6 1 0 0 0; runloop size "r"
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
# Integration-first is a standing preference, and it has to travel in the PROMPT rather than in AGENTS.md:
# the driver runs against product repositories, whose agents never read this repository's AGENTS.md.
# A preference recorded only here is a preference the unattended rounds never hear.
# A fixed window after the invocation, not a sed range ending in `^"$`: these prompts close with the
# quote at the end of a content line, so that range never terminates where it looks like it does.
for p in 'test-driven-development' 'executing-plans'; do
  awk -v pat="claude_round \"/$p" 'index($0,pat){n=25} n{print; n--}' "$LOOP" | grep -qiE 'INTEGRATION' \
    && ok "the $p prompt asks for integration-level tests" \
    || no "the $p prompt says nothing about integration tests -- the preference stops at this repo's AGENTS.md"
done
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
setup; measurement 6 1 0 0 0; runloop size "r"
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0
runloop run
[[ $RC -eq 0 ]] && grep -qi 'in place' <<<"$OUT" \
  && ok "when no worktree appears the run continues in place and says so" \
  || { no "a run without isolation did not say it was working in place (exit $RC)"; detail "$(head -6 <<<"$OUT" | tr '\n' ' ')"; }

# Already isolated: the skill's own Step 0 says do not create another, and the driver must not ask for
# one either. `git rev-parse --git-dir != --git-common-dir` is what makes a linked worktree detectable.
setup; measurement 6 1 0 0 0
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0
rm -f "$PROFILES/probe.json"
runloop size "r"
runloop run
[[ $RC -ne 0 ]] && grep -qi 'no profile' <<<"$OUT" \
  && ok "run refuses when no profile matches -- an unchecked repo is not a green one" \
  || { no "run proceeded with no profile, so nothing was verifying it (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# --- the default round cap ---------------------------------------------------
# 6 was a dead number. The gate's `max_attempts` is 3 and `attempts` rises by TWO per turn -- one for the
# block, one for the re-entry release -- so a check that keeps failing gets a VERDICT after about two
# rounds, and `gate_gave_up` halts the landing then. The driver's own cap was therefore unreachable in
# exactly the case a cap exists for, and reachable only when *different* checks fail on successive
# rounds. A cap you cannot hit is not a cap; it is a number that reads like one.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.10 3; side_effect_all implement 'date >> churn.txt'
side_effect_all debug 'date >> churn.txt'
respond debug 1 0.10 3
runloop run                                  # no --max-rounds: the default is what is under test
impl_n=$(( $(cat "$FAKE_CLAUDE_DIR/implement.counter" 2>/dev/null || echo 1) - 1 ))
debug_n=$(( $(cat "$FAKE_CLAUDE_DIR/debug.counter" 2>/dev/null || echo 1) - 1 ))
if [[ $(( impl_n + debug_n )) -eq 3 ]]; then
  ok "the default round cap is 3 implementation rounds (1 implement + 2 debug)"
else
  no "the default cap spent $(( impl_n + debug_n )) rounds ($impl_n implement, $debug_n debug), not 3"
fi

# ---------------------------------------------------------------- red path, round cap
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
mkdir -p "$REPO_DIR/scripts"; printf 'gate\n' > "$REPO_DIR/scripts/gate.sh"
git -C "$REPO_DIR" add scripts/gate.sh; commit_in_repo "add a guarded file"
respond implement 1 0.10 3
side_effect implement 1 'git mv scripts/gate.sh gate-old.sh && touch GREEN'
runloop run
[[ "$(ledger_field 'halt_reason')" == "scorer_touched" ]] \
  && ok "renaming a guarded file out of a guarded path is caught, not just editing it in place" \
  || { no "a round renamed scripts/gate.sh away and was not stopped (halt_reason '$(ledger_field 'halt_reason')')"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }

# ---------------------------------------------------------------- triage exits
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 1 0           # one finding needs a human decision
runloop run
[[ $RC -ne 0 ]] && grep -qi 'needs_decision' <<<"$OUT" \
  && ok "a finding that needs a decision halts immediately" \
  || { no "needs_decision did not halt the loop (exit $RC)"; detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q 'stack submit' "$FAKE_GH_LOG" && no "needs_decision still opened a PR" || ok "needs_decision opens no PR"

setup; measurement 11 1 0 0 0; runloop size "r"        # 6 files -> tier M, which still gets two rounds
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 2 0 1     # review 1: 2 to fix
respond fix    1 0.20 4                                    # the fix round
respond review 2 0.30 7; respond triage 2 0.05 2 1 0 1     # review 2: still 1
respond fix    2 0.20 4
respond pr     1 0.10 3
runloop run plan.md
# CHANGED DELIBERATELY, not silenced. This used to assert `review_cap` -- that the loop HALTS with the
# second review's findings unfixed. That reading of the cap made tier S unable to reach a PR at all
# (`REVIEW_ROUNDS_LEAN=1` meant the fix round was never reachable), so the cap now governs how many times
# we REVIEW, and the last review's fixes are applied and gate-verified before it stops reviewing.
# What must still hold is the thing the cap was for: no THIRD review is bought.
rounds="$(grep -c -- '/da-review-all$' "$FAKE_CLAUDE_LOG")"
[[ "$rounds" -eq 2 ]] \
  && ok "tier M: two reviews and no third -- the cap still bites where it costs" \
  || no "tier M ran $rounds review rounds, not 2"
grep -c -- '/receiving-code-review$' "$FAKE_CLAUDE_LOG" | grep -q '^2$' \
  && ok "and both rounds' findings were applied, including the last one's" \
  || no "the second review's findings were left unapplied ($(grep -c -- '/receiving-code-review$' "$FAKE_CLAUDE_LOG") fix round(s))"

# A review round is NOT one skill: it is /da-review-all plus a /da-fix-plan triage, and the first real
# landing measured that pair at $5.64 + $2.08 -- against $1.30 for the implementation it was reviewing.
# Two rounds is therefore a ~$15 ceiling on a change that tier S already decided was small enough to skip
# the design phase for. The second round is where that ceiling lives, so tier S does not buy one.
# Measured on that landing: the review had ALREADY self-scaled to the bottom fan-out tier ("inline, no
# find subagents"), so this is not depth being cut -- depth was already minimal. It is the worst case.
setup; measurement 6 1 0 0 0; runloop size "r"        # 1 file -> tier S
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
# Also changed deliberately: open findings are no longer SHIPPED UNFIXED, which is what halting here
# actually meant. They are fixed, gate-verified, and the PR body is told they were not re-reviewed.
grep -q '再レビューされていません' "$FAKE_CLAUDE_LOG" \
  && ok "and its findings are applied with the PR told they were not re-reviewed" \
  || no "tier S shipped or dropped its findings without saying which"

# ---------------------------------------------------------------- one-way doors and the draft cap
setup; measurement 11 1 0 0 0; runloop size "r"
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

setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 11 1 0 0 0; runloop size "r"
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

# A REAL plan file, which is the shape every fixture above avoided: a title that says "Landing plan",
# prose, ANOTHER table before the 🧱 one. `parse_plan` set inTable on the first line matching
# /Landing plan/i -- the title on line 1 -- and then locked onto the first table it found after it. The
# first landing came out numbered "主張" with "確認方法" as its content, and `gh stack add` was asked for
# a layer by that name. Measured on the first plan this driver was ever handed that it did not generate:
# the design-review output people actually copy has headings and evidence tables around the 🧱 one.
# The header row is what `landing_plans()` already uses to identify a plan; parsing must use the same.
setup; measurement 11 1 0 0 0; runloop size "r"
{ printf '# 🧱 Landing plan -- the title mentions it, deliberately\n\n'
  printf 'Some prose about why.\n\n'
  printf '| 主張 | 確認方法 | 結果 |\n|---|---|---|\n| the loop ran | the ledger | yes |\n\n'
  printf '## 🧱 Landing plan\n\n'
  printf '| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | the real one | probe-gate | no |\n'
} > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run plan.md
grep -q 'landing 1: the real one' <<<"$OUT" \
  && ok "a plan with an evidence table above the 🧱 one still parses the 🧱 one" \
  || { no "the wrong table was parsed as the landing list"; detail "$(grep -m1 'landing' <<<"$OUT")"; }
grep -qE 'landing (主張|確認方法)' <<<"$OUT" \
  && no "a row from the evidence table was treated as a landing" \
  || ok "and no row from the other table became a landing"

# The extension is a hard dependency. Falling back to `gh pr create` would silently produce an
# unstacked PR -- a different shape of output than the one asked for, with nothing saying so.
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0
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
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; fails_with implement 1 1
runloop run
[[ "$(ledger_field 'halt_reason')" == "round_failed" ]] \
  && ok "#2 a round that exits non-zero halts instead of being ignored" \
  || no "#2 a failed round recorded halt_reason '$(ledger_field 'halt_reason')'"

# #4 -- tier S skipped every landing-plan validation, but still parsed a plan path if one was passed.
setup; measurement 6 1 0 0 0; runloop size "r"     # tier S
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
setup; measurement 11 1 0 0 0; runloop size "r"
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
setup; measurement 6 1 0 0 0
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
setup; measurement 6 1 0 0 0; runloop size "r"
grep -qE -- '--json-schema[[:space:]]+\{' "$FAKE_CLAUDE_LOG" \
  && ok "the schema is passed inline as JSON, not as a file path" \
  || { no "--json-schema was not followed by inline JSON -- a path argument hangs the CLI"; detail "$(head -1 "$FAKE_CLAUDE_LOG" | head -c 160)"; }
grep -qE -- '--json-schema[[:space:]]+/' "$FAKE_CLAUDE_LOG" \
  && no "--json-schema was handed a path, which hangs instead of failing" \
  || ok "no path is ever passed to --json-schema"

# A round that never returns. Neither the round cap, the budget, nor the gate can stop a hang, and this
# repository keeps a whole suite about not hanging -- so the driver owns a deadline.
setup; measurement 6 1 0 0 0; runloop size "r"
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

setup; measurement 6 1 0 0 0
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
setup; measurement 6 1 0 0 0
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
measurement 6 1 0 0 0
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
for want in grilling da-spec da-design-review; do
  grep -q "$want" <<<"$OUT" && ok "  names /$want" || no "  omitted /$want"
done
# And it must NOT name the wrapper. `/grill-me` was a seven-line skill whose entire body was
# "Run a `/grilling` session." -- printing the wrapper sends you through a hop that adds nothing and
# can dangle, which is exactly how it spent three months executing nothing. Asserted as an absence
# because the positive assertion above cannot see it: "grill-me" does not contain "grilling", so both
# names could be printed and every green tick would still be green.
grep -q 'grill-me' <<<"$OUT" \
  && no "  still names the removed /grill-me wrapper" \
  || ok "  names no wrapper -- /grilling is the skill"
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
setup; measurement 6 1 0 0 0; runloop size "r"
runloop design
[[ $RC -eq 0 ]] && ok "design exits 0" || { no "design exited $RC"; detail "$(tail -2 <<<"$OUT" | tr '\n' ' ')"; }
# "design does not prompt" is NOT asserted here. test-non-interactive.sh already sweeps every
# scripts/*.sh for terminal reads and runs `loop.sh design` with stdin closed, so a second copy of that
# rule here would be two implementations of one check -- and the first version of it literally contained
# the forbidden pattern as a string, which made that suite report this file as an offender.

# Tier decides the sequence, and the tiers differ in DEPTH of human involvement, not in whether one is
# present. S has no design phase at all.
setup; measurement 6 1 0 0 0; runloop size "r"      # S
runloop design
grep -qi 'no design phase\|設計フェーズ' <<<"$OUT" \
  && ok "design at tier S says there is no design phase" \
  || { no "tier S design did not say the phase is empty"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"; }

setup; measurement 20 3 1 1 1; runloop size "r"     # L
runloop design
for want in grilling da-spec da-design-review; do
  grep -q "$want" <<<"$OUT" \
    && ok "design at tier L names /$want" \
    || no "design at tier L omitted /$want"
done
grep -q 'grill-me' <<<"$OUT" \
  && no "design at tier L still names the removed /grill-me wrapper" \
  || ok "design at tier L names no wrapper"

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
setup; measurement 11 1 0 0 0; runloop size "r"       # M
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

setup; measurement 6 1 0 0 0; runloop size "r"       # S
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
setup; measurement 3 1 0 2 0; runloop size "r"       # risk_surfaces = 2 -> M (it forced L until the revision above)
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
# Bounding this became necessary the moment `risk_surfaces` stopped forcing L: the signal that buys the
# second reviewer no longer also sends the change to an attended design phase, so /find-bugs now runs
# UNATTENDED on landings that previously never reached the review phase without a human. A third
# unbounded review skill in that path is how a tier that is supposed to cost less costs more.
[[ -n "$(round_budget '/find-bugs')" ]] \
  && ok "the second reviewer carries a ceiling too (\$$(round_budget '/find-bugs'))" \
  || no "/find-bugs was unbounded -- and lowering risk_surfaces to M is what put it on the unattended path"

setup; measurement 6 1 0 0 0; runloop size "r"       # no risk surface
: > "$FAKE_CLAUDE_DIR/no-worktree"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 0; respond pr 1 0.10 3
runloop run
grep -q '/find-bugs' "$FAKE_CLAUDE_LOG" \
  && no "the second reviewer ran with no risk surface -- review is where the cost is" \
  || ok "no risk surface, no second reviewer"

# --- "no checks yet" is not "CI failed" -------------------------------------------
# `gh` documents exit 1 as "failed for any reason". `gh pr checks` adds 8 for pending, so the driver read
# {0 -> green, 8 -> wait, everything else -> RED} and thereby called all of these a failing CI:
#   * a check genuinely failed
#   * **the checks do not exist yet**, which is the normal state for the seconds after a push
#   * authentication failed (exit 4)
#
# Measured on the seventh run: the push created workflow run 32007290138, the driver looked before GitHub
# had registered it, read "red", and spent $1.71 / 41 turns on /systematic-debugging for a failure that
# did not exist. The round correctly changed nothing, and `ci_fix_changed_nothing` stopped the landing —
# a guard catching the consequence of a misread, one phase downstream of the misread.
#
# The cure is to stop inferring from the exit code and read the states.
setup; green_pr
: > "$FAKE_GH_DIR/checks-states"                  # registered nothing yet
runloop run
# Asserted on the SENTENCE only the state-reading path can produce. "not ci_red" alone was too weak:
# the old exit-code path also reached green here, so the test passed either way.
grep -qi 'no checks' <<<"$OUT" \
  && ok "an empty check list is reported as 'no checks at all', not as a red CI" \
  || { no "no checks yet was not distinguished (halt=$(ledger_field halt_reason))"
       detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
grep -q '報告されるチェックが1つもありません' "$FAKE_CLAUDE_LOG" \
  && ok "and the PR body is told, because 'nothing ran' is not a pass" \
  || no "the PR body was not told that no checks exist"
grep -q '/systematic-debugging' "$FAKE_CLAUDE_LOG" \
  && no "a debugging round was spent on a CI failure that does not exist" \
  || ok "and no debugging round is bought for it"

# A genuine failure state still stops it.
setup; green_pr
printf 'FAILURE\n' > "$FAKE_GH_DIR/checks-states"
respond debug 1 0.10 3; side_effect_all debug 'date >> ci-fix.txt'
runloop run
grep -q '/systematic-debugging' "$FAKE_CLAUDE_LOG" \
  && ok "a FAILURE state still buys a debugging round" \
  || no "a real CI failure was ignored"

# --- XS drops the fix machinery, and must not drop the review with it -------------
# XS exists because a five-file docs edit does not need triage, a fix round and a second five-minute
# gate run. What it must NOT drop is the record: `REVIEW_REPORT` is a shell variable in a process that
# exits, and the only thing that used to persist a review was /da-fix-plan writing docs/fix-plans/. With
# triage gone the sole copy would be an argument to /da-pr-describe -- whose ceiling overrun does NOT
# halt. PR opens, describe is cut off, review gone. The eighth unattended run died on exactly a ceiling
# overrun, so that is measured rather than imagined.
setup; measurement 3 1 0 0 0; runloop size "r"        # 3 files -> XS
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond pr 1 0.10 3
runloop run
[[ "$(ledger_field tier 2>/dev/null)" == "" ]] || true
grep -qE -- '/da-review-all$|/x-review-' "$FAKE_CLAUDE_LOG" \
  && ok "XS still reviews -- nothing ships unreviewed" \
  || no "XS skipped the review entirely"
grep -q -- '/da-fix-plan' "$FAKE_CLAUDE_LOG" \
  && no "XS ran triage, which is the thing it exists to drop" \
  || ok "   ...and does not run /da-fix-plan"
grep -q -- '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && no "XS ran a fix round" || ok "   ...nor a fix round"
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "   ...and reaches a PR without them"
else
  no "XS did not reach a PR (exit $RC, halt=$(ledger_field halt_reason))"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi
# The three things that make the trade survivable, each asserted separately because each can be dropped
# on its own without the others noticing.
ls "$LOOPDIR/reviews/" >/dev/null 2>&1 && [[ -n "$(ls -A "$LOOPDIR/reviews/" 2>/dev/null)" ]] \
  && ok "   ...and the review is written to disk, so a cut-off describe cannot lose it" \
  || no "the review was never persisted -- a truncated describe round would erase it"
grep -q 'triage されていません' "$FAKE_CLAUDE_LOG" \
  && ok "   ...and the PR body is told the findings are untriaged" \
  || no "the PR body was not told that nothing triaged the findings"
[[ "$(ledger | grep -c 'advanced-untriaged')" -ge 1 ]] \
  && ok "   ...and the ledger says untriaged, not merely advanced" \
  || no "the ledger cannot tell a clean review from an untriaged one"
# Two rows for ONE review round. The round's money belongs to the row that consumed it, and the second
# row must bill nothing -- `report`'s `cost by phase` sums `cost_usd`, so a repeated figure counts the
# same spend twice. Measured on the first end-to-end run: `advanced` and `advanced-untriaged` both
# carried $1.93 / 26 turns for a single round.
if [[ "$(ledger | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const rows=s.split("\n").filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
    const adv=rows.find((r)=>r.outcome==="advanced"&&r.phase==="review");
    const unt=rows.find((r)=>r.outcome==="advanced-untriaged");
    process.stdout.write(!adv||!unt ? "missing"
      : (Number(adv.cost_usd) > 0 && Number(unt.cost_usd) === 0 && Number(unt.turns) === 0 ? "once" : "twice"))})')" == "once" ]]; then
  ok "   ...and the round is billed once: the untriaged row carries no cost of its own"
else
  no "one review round is billed on two rows, so cost-by-phase counts it twice"
fi

# S keeps everything XS drops. Same fixture, one more file.
setup; measurement 6 1 0 0 0; runloop size "r"        # 6 files -> S
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 1 0 0 0
respond fix 1 0.10 3; side_effect fix 1 'date >> f.txt'
respond pr 1 0.10 3
runloop run
grep -q -- '/da-fix-plan' "$FAKE_CLAUDE_LOG" && grep -q -- '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && ok "S still triages and applies fixes -- one file more than XS, opposite behaviour" \
  || no "S lost the fix machinery too (exit $RC, halt=$(ledger_field halt_reason))"
grep -q 'triage されていません' "$FAKE_CLAUDE_LOG" \
  && no "S claimed to be untriaged" || ok "   ...and does not claim to be untriaged"

# --- a paths profile must survive commit_landing ----------------------------------
# THE RISK THIS LANDING IS MOST LIKELY TO SHIP. `commit_landing` runs mid-landing, before review, and
# the gate's changed set is computed against a base. If that base is HEAD, the verify that follows the
# FIX round sees only the fix's delta -- the implementation is already committed and therefore
# invisible -- so every check whose paths matched the implementation becomes "not applicable", nothing
# runs, and `gate-nothing-ran` blocks a landing that was fine.
#
# Invisible on a `scope: all` profile, which is every other fixture in this file. So the fixture has to
# be a paths profile that goes all the way through the fix round, or nothing here tests the base at all.
setup; measurement 6 1 0 0 0; runloop size "r"
cat > "$PROFILES/probe.json" <<'JSON'
{ "match": { "remote": "dotagents-loop-probe" },
  "checks": [ { "id": "probe-gate", "cmd": "test -f GREEN", "gate": true,
                "agent_may_run": true, "paths": ["docs/**"], "timeout": 10 } ],
  "timeout_total": 60 }
JSON
# The implementation touches docs/ (so the check claims it). The FIX round touches something else, which
# is what makes a HEAD-relative base wrong: after commit_landing, docs/ is committed and only the fix's
# file is "changed".
respond implement 1 0.20 5; side_effect implement 1 'mkdir -p docs && touch GREEN docs/x.md'
respond review 1 0.30 7
respond triage 1 0.05 2 1 0 0 0
respond fix 1 0.10 3; side_effect fix 1 'printf y > note.txt'
respond pr 1 0.10 3
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "a paths profile survives the post-fix verify (the landing base is pinned, not HEAD)"
else
  no "a paths landing died after commit_landing (exit $RC, halt=$(ledger_field halt_reason))"
  detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"
fi
grep -q 'gate diffs against' <<<"$OUT" \
  && ok "   ...and the run says which base it pinned" \
  || no "   the run never reported pinning a diff base"

# --- a stale remote-tracking ref must not block the push --------------------------
# GitHub deletes the head branch when a PR merges, so after the loop's first landing merges,
# `refs/remotes/origin/<branch>` survives locally pointing at something gone. git then refuses:
#
#   ! [rejected] worktree-unattended-run -> worktree-unattended-run (stale info)
#
# Measured: the sixth run spent $7.84 over 2h13m, applied four review fixes, and died at `gh stack push`.
# **Any repository with auto-delete-branch hits this on its second landing.**
setup; green_pr
# The shape exactly: the branch was pushed, the remote deleted it (auto-delete-branch on merge), and the
# local remote-tracking ref survives pointing at a commit that ref no longer names. The lease check then
# compares against something the remote cannot confirm.
git -C "$REPO_DIR" branch -f loop-wt HEAD
git -C "$REPO_DIR" push -q origin loop-wt
git -C "$REPO_DIR" -c core.hooksPath=/dev/null push -q origin --delete loop-wt   # remote deletes it...
git -C "$REPO_DIR" update-ref refs/remotes/origin/loop-wt "$(git -C "$REPO_DIR" rev-parse HEAD)"  # ...ref stays
git -C "$REPO_DIR" branch -D loop-wt
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "a stale remote-tracking ref is pruned rather than halting the landing"
else
  no "a stale ref stopped the landing (exit $RC, halt=$(ledger_field halt_reason))"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi

# --- the ledger must not understate what happened outside it ----------------------
# `gh stack submit` opens the PR, and only then do CI, the comments and the description run. The `pr`
# row was written after ALL of them, so any halt downstream left the ledger with no `pr` row at all --
# and `report` leads with `reached PR 0 (0%)` plus "acceptance is under 50%, the loop is handing review
# work back to you". Measured: the seventh run halted at `ci_fix_changed_nothing` with a real PR open
# on GitHub, and the ledger counted zero.
#
# Same disease as the `pr_failed` bug one function below: the ledger saying something untrue about the
# outward world. Reaching a PR and finishing one are different facts and need different rows.
setup; green_pr
printf '1' > "$FAKE_GH_DIR/checks"; printf 'lint fail\n' > "$FAKE_GH_DIR/checks.out"
respond debug 1 0.10 3      # the CI fix round changes nothing -> halts, as it should
runloop run
[[ "$(ledger 2>/dev/null | grep -c '"outcome":"pr-reached"')" -ge 1 ]] \
  && ok "a PR that was opened is recorded as opened, even when a later phase halts" \
  || no "the landing opened a PR and the ledger has no row for it"
# Read from --json, not from the prose. The prose form was a FALSE GREEN: it passed with the fix
# removed, so it was asserting nothing. Verified by deleting the record line and re-running -- the row
# assertion above went red and this one did not. `reached_pr` is a number in the JSON and cannot be
# matched by accident.
runloop report --json
if node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{process.exit(JSON.parse(s).reached_pr === 1 ? 0 : 1)}catch{process.exit(1)}})' <<<"$OUT"; then
  ok "and report counts it as reached rather than leading with 0%"
else
  no "report still says the PR was not reached"; detail "$(head -c 160 <<<"$OUT")"
fi

# The row is a FACT, not a round: no `claude` round produced it, so it must bill nothing. `record`
# writes the round globals (`cost_usd` / `turns`), which still hold the PREVIOUS round's numbers, and
# `report`'s `cost by phase` sums exactly that field. Measured on the first end-to-end run: the
# `pr-reached` row carried the review round's $1.93 / 26 turns, and `report` said `pr $5.27` with
# $1.93 of review money inside it. **The PR that fixed one ledger lie shipped another one.**
if [[ "$(ledger | node -e '
  let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
    const rows=s.split("\n").filter(Boolean).map(l=>{try{return JSON.parse(l)}catch{return null}}).filter(Boolean);
    const r=rows.find((r)=>r.outcome==="pr-reached");
    process.stdout.write(r ? String(Number(r.cost_usd)) + "/" + String(Number(r.turns)) : "no-row")})')" == "0/0" ]]; then
  ok "the pr-reached row bills nothing -- it is a fact, not a round"
else
  no "the pr-reached row carries the previous round's cost, so cost-by-phase bills pr for review"
  detail "$(ledger | grep -o '\"outcome\":\"pr-reached\".*' | head -c 120)"
fi

# It must not count a landing that never got a PR at all.
setup; green_pr
: > "$FAKE_GH_DIR/submit-no-url"; : > "$FAKE_GH_DIR/no-pr"
runloop run
runloop report --json
if node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try{process.exit(JSON.parse(s).reached_pr === 0 ? 0 : 1)}catch{process.exit(1)}})' <<<"$OUT"; then
  ok "and a landing with no PR is still not counted"
else
  no "report counted a PR that never existed"; detail "$(head -c 160 <<<"$OUT")"
fi

# --- a PR that exists is not a PR that failed -------------------------------------
# `gh stack submit` prints a URL when it creates the PR and prose when the PR is already current:
# "PR #45 for <branch> is up to date". The driver scraped stdout for a URL and called the second shape
# `pr_failed` -- **for a PR that was open the whole time**. Measured on the fifth run: PR #45 sat open
# on the real repository while the landing halted, so CI, the comments and the description never ran
# and the PR kept an auto-generated title with no body.
#
# Same disease this repo already names twice about the gate: coupling to another tool's PROSE.
setup; green_pr
: > "$FAKE_GH_DIR/submit-no-url"
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "a submit that prints no URL is resolved through gh pr view, not called a failure"
else
  no "submit without a URL was treated as a failure (exit $RC, halt=$(ledger_field halt_reason))"
fi
grep -q '^pr view' "$FAKE_GH_LOG" \
  && ok "and the driver asks GitHub for the PR rather than scraping stdout" \
  || no "the driver never asked gh pr view -- it is still parsing prose"

# When there genuinely is no PR, it still fails. The fallback must not invent success.
setup; green_pr
: > "$FAKE_GH_DIR/submit-no-url"; : > "$FAKE_GH_DIR/no-pr"
runloop run
[[ "$(ledger_field halt_reason)" == "pr_failed" ]] \
  && ok "and a genuinely missing PR is still pr_failed" \
  || no "no PR exists yet the driver carried on (halt=$(ledger_field halt_reason))"

# --- the last review's fixes get applied ------------------------------------------
# Fourth instance of the shape. `REVIEW_ROUNDS_LEAN=1` capped COST, but the loop checked the cap BEFORE
# applying the fixes, so at tier S a single Fix-now finding halted the landing with the fix never
# attempted -- /receiving-code-review was unreachable there. Measured: the first landing to get past
# triage stopped on `fix_now=1`, one mechanical edit short of a PR.
#
# What the cap should govern is how many times we REVIEW, not whether the last review's findings get
# acted on. Applying is cheap and the gate re-verifies it; buying another review is the expensive thing.
setup; measurement 6 1 0 0 0; runloop size "r"      # tier S -> exactly 1 review round
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 1 0 0 0                      # fix_now 1
respond fix 1 0.10 3; side_effect fix 1 'date >> applied.txt'
respond pr 1 0.10 3
runloop run
grep -q '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && ok "tier S applies the single review round's fixes instead of halting on them" \
  || { no "the fix round never ran -- a one-line finding still blocks the landing"
       detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"; }
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "and the landing reaches a PR"
else
  no "the landing still did not reach a PR (exit $RC, halt=$(ledger_field halt_reason))"
fi
# The honesty half: those fixes were gate-verified but never re-reviewed, and the reader must be told.
grep -q '再レビューされていません' "$FAKE_CLAUDE_LOG" \
  && ok "and the PR body is told the fixes were not re-reviewed" \
  || no "fixes applied after the last review reach the PR with nothing said about it"

# A decision still outranks everything -- it stops before any fix is attempted.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 1 1 0 0                      # fix_now 1 AND needs_decision 1
runloop run
[[ "$(ledger_field halt_reason)" == "needs_decision" ]] \
  && ok "a decision still halts before any fix is applied" \
  || no "needs_decision was overtaken by the fix path (halt=$(ledger_field halt_reason))"

# --- "could not verify" is not "needs a decision" ---------------------------------
# The third instance of one shape. `needs_decision > 0` halted the run unconditionally -- and
# finding-discipline REQUIRES the review to file anything it could not confirm as 👤, exempt from the
# confidence threshold. So a review that did its job honestly almost always produces one, and the halt
# was close to tautological. Measured: the first landing to reach triage stopped here with 0 defects,
# 3 🧭 and 1 👤 -- nothing was wrong with the code at all.
#
# Same disease as `unconfirmed > 0` forcing tier L, same cure: the field mixed two things.
#   "a human must decide this"  -> still halts. The loop must not guess a judgement call.
#   "I could not verify this"   -> does NOT halt. It rides into the PR body as a caveat, exactly the way
#                                  GATE_DEFERRED already does for checks the agent may not run.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 0 3      # fix_now 0, needs_decision 0, decline 0, unverified 3
respond pr 1 0.10 3
runloop run
if [[ $RC -eq 0 ]] && grep -q 'pull/7' <<<"$OUT"; then
  ok "3 unverified findings do not stop the landing -- they are a caveat, not a decision"
else
  no "unverified findings halted the run (exit $RC, halt=$(ledger_field halt_reason))"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi
# ...and they must reach the reader. A caveat nobody is told is the same as no caveat.
# Asserted on the PROMPT THE DRIVER ACTUALLY SENT, not on the source: grepping loop.sh near
# /da-pr-describe for "未検証" passes on the GATE_DEFERRED text that was already there, which is a
# different caveat about a different thing. The count has to appear in the describe call itself.
# Searched across the WHOLE log, not on the line that carries `/da-pr-describe`. The stub logs `$*`, so
# a multi-line prompt lands as many lines and only its first one holds the command -- the same trap this
# file's header warns about, walked into twice more today.
grep -q '確認できなかった (unverified) 所見が 3 件' "$FAKE_CLAUDE_LOG" \
  && ok "and the describe round is handed the unverified count" \
  || { no "the unverified findings never reached the PR body -- silently dropped"
       detail "$(grep -c 'unverified' "$FAKE_CLAUDE_LOG") line(s) mention unverified at all"; }

# A real decision still stops everything, budget remaining or not.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 2 0 0      # needs_decision 2
runloop run
[[ "$(ledger_field halt_reason)" == "needs_decision" ]] \
  && ok "a genuine decision still halts the landing" \
  || no "needs_decision no longer halts (halt=$(ledger_field halt_reason)) -- the split went too far"

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 0 4
respond pr 1 0.10 3
runloop run
[[ "$(ledger 2>/dev/null | grep -c '"unverified":4')" -ge 1 ]] \
  && ok "the ledger records the unverified count, so report can show it" \
  || no "unverified was not recorded in the ledger"

# ---------------------------------------------------------------- after the PR is open
# The loop used to end at `gh stack submit`. Everything below is the half that was missing: the CI the
# PR triggers, the comments a human leaves on it, and the description -- which now comes LAST, so the
# body describes what actually happened rather than what was true one minute after opening.

setup; green_pr; runloop run
grep -q 'pr checks' "$FAKE_GH_LOG" \
  && ok "the driver checks CI after opening the PR" \
  || no "CI is never looked at -- the loop still ends at submit"

# Order is the point of this landing: the description is written after CI and comments have settled.
setup; green_pr; runloop run
if [[ -n "$(grep -n 'pr checks' "$FAKE_GH_LOG" | head -1 | cut -d: -f1)" ]]; then
  ci_line=$(grep -n 'pr checks' "$FAKE_GH_LOG" | head -1 | cut -d: -f1)
  desc_line=$(grep -n 'da-pr-describe' "$FAKE_CLAUDE_LOG" | head -1 | cut -d: -f1)
  # Different logs, so compare by wall order: the gh log gets the checks call before the claude log
  # gets the describe call only if describe moved last. Assert on the driver's own ordering instead.
  grep -q 'da-pr-describe' "$FAKE_CLAUDE_LOG" \
    && ok "the description round still runs" || no "the description round vanished"
fi
awk '/pr checks/{ci=1} /da-pr-describe/{if(!ci) bad=1} END{exit bad?1:0}' \
  <(cat "$FAKE_GH_LOG" "$FAKE_CLAUDE_LOG") >/dev/null 2>&1 || true

# A red CI is fixed and re-checked, not reported and abandoned.
setup; green_pr
printf 'FAILURE\n' > "$FAKE_GH_DIR/checks-states"
printf '1' > "$FAKE_GH_DIR/checks.1"; printf 'lint  fail\n' > "$FAKE_GH_DIR/checks.1.out"
respond debug 1 0.10 3; side_effect_all debug 'date >> ci-fix.txt'
runloop run
grep -q '/systematic-debugging' "$FAKE_CLAUDE_LOG" \
  && ok "a red CI gets a debugging round, not a shrug" \
  || { no "a red CI produced no fix attempt"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }

# ...but not forever. CI that stays red is a human's problem, and the ledger has to name it.
setup; green_pr
printf 'FAILURE\n' > "$FAKE_GH_DIR/checks-states"
printf '1' > "$FAKE_GH_DIR/checks"; printf 'lint  fail\n' > "$FAKE_GH_DIR/checks.out"
respond debug 1 0.10 3; side_effect_all debug 'date >> ci-fix.txt'
runloop run
[[ "$(ledger_field halt_reason)" == "ci_red" ]] \
  && ok "CI that stays red halts as ci_red rather than looping" \
  || no "a permanently red CI did not halt as ci_red (halt=$(ledger_field halt_reason))"

# Human comments: addressed, then replied to. NEVER resolved -- resolving is a claim about someone
# else's satisfaction, and it is the one thing this phase is not allowed to do.
setup; green_pr
printf '[{"id":11,"path":"a.txt","line":1,"body":"this looks wrong","user":{"login":"human"}}]' \
  > "$FAKE_GH_DIR/pr-comments"
respond fix 1 0.20 4; side_effect fix 1 'date >> comment-fix.txt'
node -e 'process.stdout.write(JSON.stringify({total_cost_usd:0.05,num_turns:2,result:"ok",
  structured_output:{replies:[{comment_id:11,body:"直しました"}]}}))' > "$FAKE_CLAUDE_DIR/reply.1.json"
runloop run
grep -q '/receiving-code-review' "$FAKE_CLAUDE_LOG" \
  && ok "a PR comment is taken to /receiving-code-review, not implemented on sight" \
  || { no "PR comments were never addressed"; detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"; }
grep -qE 'api .*(comments/11/replies|replies)' "$FAKE_GH_LOG" \
  && ok "and a reply is posted to the thread" \
  || { no "no reply was posted"; detail "$(grep api "$FAKE_GH_LOG" | head -3 | tr '\n' ' ')"; }
if grep -qiE 'resolveReviewThread|graphql' "$FAKE_GH_LOG"; then
  no "the driver resolved a review thread -- that is the human's call, and option A says reply only"
else
  ok "and nothing is resolved -- replying is the driver's limit"
fi

# The cheap path stays cheap: a green CI with no comments buys no extra rounds.
setup; green_pr; runloop run
extra=0
for p in debug fix reply; do
  [[ -f "$FAKE_CLAUDE_DIR/$p.counter" ]] && extra=$(( extra + $(cat "$FAKE_CLAUDE_DIR/$p.counter") - 1 ))
done
[[ "$extra" -eq 0 ]] \
  && ok "green CI and no comments cost no extra rounds" \
  || no "a clean PR still spent $extra extra round(s) after opening"

# ---------------------------------------------------------------- interruption
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0 0; fails_with implement 1 143
runloop run
[[ "$(ledger_field 'halt_reason')" == "interrupted" ]] \
  && ok "exit 143 is recorded as interrupted, not as a failure" \
  || no "exit 143 recorded halt_reason '$(ledger_field 'halt_reason')'"

# ---------------------------------------------------------------- the ledger itself
setup; measurement 6 1 0 0 0; runloop size "r"
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

# ---------------------------------------------------------------- the cost ceiling
# Review is where the money goes, and until this section existed nothing bounded a single round. Two
# measured landings both recorded `num_turns: 50` for /da-review-all while every other phase in the same
# ledger sat between 5 and 20 -- $5.64 and $6.19, against $1.30 and $1.50 for the implementations they
# were reviewing. Whether 50 is a ceiling in the CLI or a coincidence is UNCONFIRMED; what is confirmed is
# that the driver could not have told the difference, because it reads only total_cost_usd and num_turns.
#
# This build of `claude` has no --max-turns. It has --max-budget-usd, which is the better lever anyway:
# it bounds the thing being complained about, and the harness enforces it rather than the prompt.
setup; measurement 6 1 0 0 0; runloop size "r"        # 1 file, 0 layers -> tier S
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
s_budget="$(round_budget '/da-review-all')"
[[ -n "$s_budget" ]] \
  && ok "a review round carries a --max-budget-usd ceiling (tier S: \$$s_budget)" \
  || { no "the review round had no cost ceiling -- one round is unbounded"
       detail "$(grep -o '^[^ ]* [^ ]* [^ ]*' "$FAKE_CLAUDE_LOG" | head -3 | tr '\n' ' ')"; }

# Tier M, not L: L hands the turn back for the design phase and never reaches review in one `run`, so a
# tier L fixture measures nothing here. M is the lowest tier above S that runs start to finish.
setup; measurement 11 1 0 0 0; runloop size "r"        # M
printf '### 🧱 Landing plan\n| # | What lands | What gates it | One-way? |\n|---|---|---|---|\n| 1 | a | probe-gate | no |\n' \
  > "$REPO_DIR/plan.md"
git -C "$REPO_DIR" add plan.md; commit_in_repo plan
respond execplan 1 0.20 5; side_effect execplan 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run plan.md
m_budget="$(round_budget '/da-review-all')"
if [[ -n "$s_budget" && -n "$m_budget" ]] && node -e 'process.exit(Number(process.argv[1]) < Number(process.argv[2]) ? 0 : 1)' "$s_budget" "$m_budget"; then
  ok "the review ceiling is tier-scaled (S \$$s_budget < M \$$m_budget)"
else
  no "the review ceiling does not scale with tier (S '$s_budget' vs M '$m_budget')"
fi

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
t_budget="$(round_budget '/da-fix-plan')"
[[ -n "$t_budget" ]] \
  && ok "the triage round carries a ceiling too (tier S: \$$t_budget)" \
  || no "triage was unbounded -- it measured \$2.08 and \$1.90 for counting buckets on an 11-line diff"

# --- one layer at tier S skips the dispatcher entirely ---------------------------
# /da-review-all costs a cold read of its own 12 KB body plus a classification pass, to then print
# "no cross-layer impact" and hand the report straight through. When `size` already recorded exactly one
# layer and it is one of the three the toolkit has a skill for, the dispatcher is buying nothing: type
# the layer skill. This is the LAST structural cost left in the bottom tier after the brief.
setup; measurement 6 1 0 0 0 "backend"; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
if grep -q -- '/x-review-backend$' "$FAKE_CLAUDE_LOG" && ! grep -q -- '/da-review-all$' "$FAKE_CLAUDE_LOG"; then
  ok "tier S with one known layer types /x-review-backend, not the dispatcher"
else
  no "the dispatcher still ran for a single-layer tier S change"
  detail "$(grep -oE '/(da-review-all|x-review-[a-z]+)' "$FAKE_CLAUDE_LOG" | sort -u | tr '\n' ' ')"
fi

# The fallback is the part that must not be clever. A layer name the toolkit has no skill for, or more
# than one layer, or none at all, all go back to the dispatcher -- guessing which skill to type would
# review a layer with the wrong checklist and report it as covered.
setup; measurement 6 1 0 0 0 "mobile"; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
grep -q -- '/da-review-all$' "$FAKE_CLAUDE_LOG" \
  && ok "an unrecognised layer name falls back to the dispatcher" \
  || { no "an unknown layer did not fall back -- something guessed a skill name"
       detail "$(grep -oE '/(da-review-all|x-review-[a-z-]+)' "$FAKE_CLAUDE_LOG" | sort -u | tr '\n' ' ')"; }

setup; measurement 6 0 0 0 0; runloop size "r"    # docs-only: zero layers
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
grep -q -- '/da-review-all$' "$FAKE_CLAUDE_LOG" \
  && ok "a change with no layer at all still gets the dispatcher" \
  || no "a zero-layer change reached no reviewer at all"

# --- the prompt must survive the flags --------------------------------------------
# `--allowedTools` is VARIADIC (`<tools...>`). A prompt placed directly after it is consumed as one more
# tool name, and `claude` exits 1 with "Input must be provided either through stdin or as a prompt
# argument" -- before spending a token, so the ledger shows $0 and 0 turns and the phase looks like it
# declined rather than like it never ran.
#
# It only bit the rounds with NO --max-budget-usd, because that flag happened to terminate the list:
# size/review/triage/pr worked, isolate/verify/implement/debug/fix did not. The suite could not see it,
# because the stub is a bash script that takes argv as given -- variadic parsing exists only in the real
# CLI. So what is asserted is the ORDERING PROPERTY that makes the parse safe.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
bad_calls=$(node -e '
  const fs = require("fs");
  const calls = fs.readFileSync(process.argv[1], "utf8").split("\n---\n").filter(c => c.trim());
  let bad = 0;
  for (const c of calls) {
    const a = c.split("\n").filter(x => x.length);
    const i = a.indexOf("--allowedTools");
    if (i === -1) continue;
    // The prompt is the final argument. Safe only when something else stands between it and the
    // variadic list: the value, then at least one more flag.
    if (i + 2 >= a.length) { bad++; continue; }          // value is the prompt, or nothing follows
    if (!a[i + 2].startsWith("--")) bad++;               // the prompt sits directly after the value
  }
  process.stdout.write(String(bad));
' "$FAKE_CLAUDE_ARGV")
[[ "$bad_calls" == "0" ]] \
  && ok "no round leaves its prompt directly after the variadic --allowedTools" \
  || no "$bad_calls round(s) would have their prompt eaten as a tool name -- claude exits 1 before spending anything"

# --- every round may READ the repository, and may not write to it -----------------
# Measured, not assumed: `claude --print --permission-mode acceptEdits` cannot run git in this
# environment -- `git status --short` came back "requires approval", and headless there is nobody to
# approve. /da-review-all's Step 1 IS `git diff`, so the review phase never established its scope; the
# 50 turns and $6.19 were retries against a permission wall, not depth.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7; respond triage 1 0.05 2 0 0 3; respond pr 1 0.10 3
runloop run
grep -q -- '--allowedTools' "$FAKE_CLAUDE_LOG" \
  && ok "rounds are granted tools explicitly, so git is not denied headless" \
  || no "no --allowedTools was passed -- the review still cannot read the diff"
grep -q 'git diff' "$FAKE_CLAUDE_LOG" \
  && ok "and the grant includes git diff, which is what Step 1 needs" \
  || no "the grant does not include git diff"
# A command-rewriting PreToolUse hook runs BEFORE the permission match, so on a machine whose hook turns
# `git status` into `rtk git status` the bare pattern matches nothing -- and an unmatched pattern is
# indistinguishable from no grant at all. Measured: Bash(git status:*) denied, Bash(rtk git status:*) ran.
# Both forms ship, because the toolkit also has to work where no such hook exists.
grep -q 'rtk git diff' "$FAKE_CLAUDE_LOG" \
  && ok "and the rewritten form too, so a command-rewriting hook does not silently void the grant" \
  || no "only the bare form is granted -- on a machine with a rewriting hook that is a no-op"
# The grant is read-only BY ENUMERATION. `Bash(git:*)` would hand an unattended round `git push`,
# `git reset --hard` and `git branch -D` in order to let it run `git diff`.
if grep -qE 'Bash\(git:\*\)|git push|git reset|git branch -D|git clean' "$FAKE_CLAUDE_LOG"; then
  no "the tool grant reaches beyond read-only git"
  detail "$(grep -oE 'Bash\([^)]*\)' "$FAKE_CLAUDE_LOG" | sort -u | tr '\n' ' ')"
else
  ok "the grant names read-only git subcommands only -- no push, reset, branch -D or clean"
fi

# --- the rounds that never reach post_round ---------------------------------------
# Truncation detection lives in post_round, and four claude_round calls do not go through it: size,
# worktree, pr and verify. Two of those four verify their own effect afterwards -- the worktree phase
# reads `git worktree list`, the verify phase reads the gate -- so a cut-off round there surfaces as the
# observable failure it caused. The other two are blind, and each is blind in its own way.
setup
measurement 6 1 0 0 0
runloop size "r"
[[ -n "$(round_budget '/da-investigate')" ]] \
  && ok "the size round carries a ceiling (\$$(round_budget '/da-investigate'))" \
  || no "size was unbounded -- measured at \$1.53-\$1.98 a go, three times in one session"

# A cut-off size round returns no structured output, which is indistinguishable from the schema flag
# being wrong -- and that is exactly what the driver used to report. A misdiagnosis sends you to check
# the CLI when the answer is "raise the ceiling".
setup
printf '{"total_cost_usd":0.30,"num_turns":9,"subtype":"error_max_budget_usd","result":"partial"}' \
  > "$FAKE_CLAUDE_DIR/investigate.1.json"
runloop size "r"
if [[ $RC -ne 0 ]] && grep -qiE 'truncat|打ち切|ceiling|天井' <<<"$OUT"; then
  ok "a cut-off size round says it was cut off, not that the schema flag is wrong"
else
  no "a truncated size round was misdiagnosed (exit $RC)"; detail "$(head -4 <<<"$OUT" | tr '\n' ' ')"
fi
grep -qi 'json-schema' <<<"$OUT" \
  && no "and it still blamed --json-schema, which is the wrong thing to go and check" \
  || ok "and it does not send you to check the CLI flag"

# The PR phase is the one place where halting cannot undo what happened: `gh stack submit` has already
# opened the PR by the time the body is written. So a cut-off /da-pr-describe leaves a REAL PR carrying
# a half-written description, recorded `opened-pr` -- the "looks done, isn't" shape. It must be said.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
respond review 1 0.30 7
respond triage 1 0.05 2 0 0 3
truncated pr 1 error_max_budget_usd
runloop run
if grep -qiE 'partial|部分|途中|truncat|打ち切' <<<"$OUT"; then
  ok "a cut-off PR description is reported, not recorded as a finished one"
else
  no "the PR body was truncated and nothing said so"; detail "$(tail -5 <<<"$OUT" | tr '\n' ' ')"
fi
[[ "$(ledger_field outcome)" != "opened-pr" ]] \
  && ok "and the ledger distinguishes it from a clean opened-pr" \
  || no "the ledger recorded a partial-bodied PR as a plain opened-pr"
# ...and it still counts as having reached a PR. The landing's CODE went through the gate and the
# review; what was cut off is prose. Scoring it as not-reached would report the loop as failing to land
# work it did land, for a documentation defect that already has its own ledger row.
if runloop report; grep -qE 'reached PR +1' <<<"$OUT"; then
  ok "and it still counts as having reached a PR (the code landed; the prose did not finish)"
else
  no "a partial-bodied PR was scored as not having reached a PR"
  detail "$(grep -i 'reached PR' <<<"$OUT" | head -1)"
fi

# --- the review round must not be able to eat the run ----------------------------
# Read out of the source, because this is a relationship between chosen numbers rather than a behaviour:
# review + triage + findbugs can all fire on ONE landing, and the two measured runs both died on
# `budget` at triage with the PR one step away. If the review round's own ceilings sum above the run
# budget, that outcome is not a surprise -- it is arithmetic.
loop_const() { grep -E "^$1=" "$LOOP" | head -1 | sed -E "s/^$1=([0-9.]+).*/\1/"; }
s_total="$(node -e 'process.stdout.write(String(
  Number(process.argv[1]) + Number(process.argv[2]) + Number(process.argv[3])))' \
  "$(loop_const BUDGET_ROUND_REVIEW_LEAN)" "$(loop_const BUDGET_ROUND_TRIAGE_LEAN)" "$(loop_const BUDGET_ROUND_FINDBUGS_LEAN)")"
run_budget="$(loop_const BUDGET_USD)"
if node -e 'process.exit(Number(process.argv[1]) > 0 && Number(process.argv[1]) < Number(process.argv[2]) / 2 ? 0 : 1)' \
     "$s_total" "$run_budget"; then
  ok "a tier S review round is capped at \$$s_total, under half the \$$run_budget run budget"
else
  no "the tier S review ceilings sum to \$$s_total against a \$$run_budget run budget -- one landing's review can starve the run"
fi

# --- a ceiling overrun exits NON-ZERO, so `truncated` has to be checked first -----
# Measured: `claude --max-budget-usd 0.02 ...` returns **exit 1** with subtype error_max_budget_usd and
# is_error true. `post_round` checked the exit code before the truncation, so the budget case -- the exact
# case `truncated` was built for -- reported `round_failed`: "the review round exited 1. Nothing is
# claimed about what it did." True, and useless. The specific reason ("cut off at its ceiling; raise it or
# make the round cheaper") existed and was unreachable.
#
# The eighth run died this way at $2.07 against a $2.00 ceiling.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_max_budget_usd
fails_with review 1 1                       # ...and the process exits 1, as the real CLI does
runloop run
[[ "$(ledger_field halt_reason)" == "truncated" ]] \
  && ok "a ceiling overrun halts as truncated even though the process exited 1" \
  || no "the exit code masked the truncation (halt=$(ledger_field halt_reason))"
grep -qiE 'ceiling|天井' <<<"$OUT" \
  && ok "and the message names the ceiling, which is the actionable part" \
  || no "the halt message does not mention the ceiling"

# The two reasons that must still outrank it, because they are more specific about what happened.
# --- an error is not a ceiling, and must not be reported as one ------------------
# `is_error: true` with `subtype: "success"` is a real shape: the 10th run's implement round returned it
# at $1.2784895 / 24 turns. Detection is deny-by-default and that is right -- but the halt NAMED it
# "cut off at its ceiling (subtype: success)" and advised "raise that round's ceiling", and **implement
# has no ceiling**: there is no BUDGET_ROUND_IMPLEMENT. A wrong reason pointing at a knob that does not
# exist is worse than no reason, and the ledger recorded `truncated`, which is false.
setup; measurement 6 1 0 0 0; runloop size "r"
errored implement 1
runloop run
[[ "$(ledger_field halt_reason)" == "round_errored" ]] \
  && ok "an errored round is not recorded as truncated" \
  || no "an error was filed as a ceiling overrun (halt=$(ledger_field halt_reason))"
grep -qiE 'ceiling|天井' <<<"$OUT" \
  && no "the message still points at a ceiling that this phase does not have" \
  || ok "and the message does not point at a ceiling"

# ---- the round's own output has to still exist for "read the round's output" to be an instruction ----
# The 10th run's implement round errored and NOTHING said why: stdout went to a mktemp that was rm'd,
# and stderr went to /dev/null. The halt message told a human to read output that had been deleted.
# LOOP_DIR is outside the repository ($HOME/.claude/.dotagents-loop), so keeping it there cannot dirty
# the tree -- a file written inside the checkout would look like a round that edited something.
setup; measurement 6 1 0 0 0; runloop size "r"
errored implement 1 "auth error: OAuth token has expired"
runloop run
saved="$(grep -rl 'is_error' "$LOOPDIR/rounds" 2>/dev/null | head -1)"
[[ -n "$saved" ]] \
  && ok "the round's raw JSON outlives the round" \
  || no "nothing under \$LOOP_DIR/rounds holds the round's own output -- it is still being deleted"
grep -rq 'OAuth token has expired' "$LOOPDIR/rounds" 2>/dev/null \
  && ok "and its stderr, which is where a round says why it failed" \
  || no "stderr is still going to /dev/null -- the one place the reason was"
grep -q "$LOOPDIR/rounds" <<<"$OUT" \
  && ok "and the halt message says where to look" \
  || no "the message says to read the round's output without saying where it is"

# The same shape in the size round, which DOES have a ceiling -- the advice is still wrong, because
# raising a budget does not fix a round that errored.
setup; errored investigate 1   # the size round measures with /da-investigate: that is the fixture name
runloop size "r"
grep -qiE 'BUDGET_ROUND_SIZE' <<<"$OUT" \
  && no "an errored size round was told to raise its budget" \
  || ok "an errored size round is not told to raise its budget"

# Deny-by-default is preserved for ceilings this CLI does not have yet: `error_max_*` keeps the ceiling
# reading, so a future ceiling subtype is still named as one rather than demoted to a generic error.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_max_tokens
fails_with review 1 1
runloop run
[[ "$(ledger_field halt_reason)" == "truncated" ]] \
  && ok "an error_max_* subtype this build has never seen still reads as a ceiling" \
  || no "a future ceiling subtype was demoted (halt=$(ledger_field halt_reason))"

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; fails_with implement 1 143
runloop run
[[ "$(ledger_field halt_reason)" == "interrupted" ]] \
  && ok "SIGTERM still outranks truncation" \
  || no "interrupted was masked (halt=$(ledger_field halt_reason))"

# --- a round that ended at a ceiling is not a round that finished ----------------
# The failure this prevents: `claude -p` returns exit 0 with a partial `result` when it stops early, so a
# truncated review was recorded `outcome: advanced` and its half-written report was handed to triage as
# though it were a finished one. Nothing downstream could tell, and 🔎 in the report would not say so
# either -- the model does not know it was cut off.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_max_budget_usd
respond triage 1 0.05 2 0 0 3
runloop run
if [[ "$(ledger_field outcome)" != "advanced" ]] && grep -qiE 'truncat|cut off|ceiling|打ち切' <<<"$OUT"; then
  ok "a review that stopped at its ceiling halts instead of recording 'advanced'"
else
  no "a truncated review was recorded as a finished one (outcome=$(ledger_field outcome))"
  detail "$(tail -4 <<<"$OUT" | tr '\n' ' ')"
fi
[[ "$(ledger_field halt_reason)" == "truncated" ]] \
  && ok "the ledger names the halt 'truncated', so report can count it" \
  || no "halt_reason was '$(ledger_field halt_reason)', not 'truncated'"

# An unknown subtype must read as failure, not as success. New CLI versions add subtypes; a driver that
# allowlists the ones it knows and treats the rest as fine will silently start accepting truncated rounds
# the day one is added. Absence still means success -- every fixture here and some builds omit the field.
#
# Asserted on halt_reason, not on `outcome != advanced`. The first version of this check read the LAST
# ledger line, which on a run that completes is the PR phase (`opened-pr`) -- so it passed while the
# driver was doing exactly the wrong thing, and passed for the same reason in both truncation cases.
setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
truncated review 1 error_something_invented_later
respond triage 1 0.05 2 0 0 3
runloop run
# The LABEL changed when ceilings and errors were split: an invented subtype is not a ceiling, so it
# reads as `round_errored`. What must not change is that it FAILS CLOSED -- and the row read is still
# the one this comment warns about. `error_max_*` keeping the ceiling reading is asserted separately.
[[ "$(ledger_field halt_reason)" == "round_errored" ]] \
  && ok "an unrecognised subtype fails closed rather than passing as success" \
  || no "an unknown subtype passed as a successful round (halt_reason=$(ledger_field halt_reason)) -- the allowlist is inverted"

setup; measurement 6 1 0 0 0; runloop size "r"
respond implement 1 0.20 5; side_effect implement 1 'touch GREEN'
printf '{"total_cost_usd":0.30,"num_turns":7,"subtype":"success","result":"ok"}' \
  > "$FAKE_CLAUDE_DIR/review.1.json"
respond triage 1 0.05 2 0 0 3
respond pr 1 0.10 3
runloop run
if [[ "$RC" -eq 0 ]] && grep -q 'pull/7' <<<"$OUT" && [[ "$(ledger_field halt_reason)" != "truncated" ]]; then
  ok "subtype:success is not mistaken for a truncation"
else
  no "an explicitly successful round was rejected (exit $RC, halt=$(ledger_field halt_reason))"
  detail "$(tail -3 <<<"$OUT" | tr '\n' ' ')"
fi

# ------------------------------------------------- report says how much of the total is counted twice
# The rows written before `consume_round_numbers` kept a round's numbers on a second row, and the ledger
# is append-only by design (the assertion below is what keeps it that way), so those figures cannot be
# corrected -- only qualified. Detected by the symptom rather than by a date: the row does not carry the
# version of `loop.sh` that wrote it. Measured on the real ledger when this went in: $8.30 across 6 rows,
# three of them from before the change that added the newest one, which is why the caveat is phrased as
# a property of the data and not of one commit.
setup; measurement 1 0 0 0 0; runloop size "r"     # one genuine row, to borrow the repo key from
KEY="$(ledger_field repo)"
node -e '
  const fs = require("fs");
  const [file, repo] = process.argv.slice(1);
  const row = (phase, outcome, cost, turns) => JSON.stringify({
    ts: "2026-08-19T00:00:00Z", repo, branch: "b", phase, landing: "1", round: 1,
    outcome, halt_reason: null, cost_usd: cost, turns,
  });
  fs.appendFileSync(file, [
    row("review", "advanced", 1.93, 26),            // the round that actually cost the money
    row("pr", "pr-reached", 1.93, 26),              // the same numbers again, on a row with no round
    row("implement", "advanced", 0.5, 4),           // a different round: must NOT be counted as a repeat
  ].join("\n") + "\n");
' "$LOOPDIR/ledger.jsonl" "$KEY"
runloop report --json
if node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{
  try { const j = JSON.parse(s);
    process.exit(j.double_counted_rows === 1 && Math.abs(j.double_counted_usd - 1.93) < 0.001 ? 0 : 1)
  } catch { process.exit(1) }})' <<<"$OUT"; then
  ok "report counts the repeated figures and leaves the distinct round alone"
else
  no "report did not identify the double-counted row"; detail "$(head -c 200 <<<"$OUT")"
fi
runloop report
grep -q "counted twice" <<<"$OUT" \
  && ok "   ...and says so in the human output, next to the totals it qualifies" \
  || no "the human report shows overstated totals with nothing saying they are overstated"

# And a ledger with no repeats must say nothing: a caveat that is always printed is furniture.
setup; measurement 1 0 0 0 0; runloop size "r"
runloop report
grep -q "counted twice" <<<"$OUT" \
  && no "report warns about double counting on a ledger that has none" \
  || ok "and a ledger with no repeated figures gets no caveat"

# ---------------------------------------------------------------- the ledger is never trimmed
setup
node -e '
  const fs = require("fs");
  const l = [];
  for (let i = 0; i < 400; i++) l.push(JSON.stringify({ts:"t",repo:"r",branch:"b",phase:"implement"}));
  fs.writeFileSync(process.argv[1], l.join("\n") + "\n");
' "$LOOPDIR/ledger.jsonl"
measurement 6 1 0 0 0; runloop size "r"
lines="$(wc -l < "$LOOPDIR/ledger.jsonl" | tr -d ' ')"
[[ "$lines" -gt 400 ]] \
  && ok "the ledger is append-only and never trimmed ($lines lines)" \
  || no "the ledger lost lines (400 planted, $lines left) -- trace.log self-trims, this must not"

echo
if (( fail )); then
  printf '%s%d passed, %d failed%s\n' "$c_red" "$pass" "$fail" "$c_off"; exit 1
fi
printf '%s✓ %d passed%s\n' "$c_green" "$pass" "$c_off"
