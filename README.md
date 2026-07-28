# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A personal AI development toolkit for **Claude Code and Cursor**. Installed once, globally, and
available in every repository. No product repository is ever modified.

日本語版: [README.ja.md](README.ja.md) · Why it is shaped this way: [docs/design.md](docs/design.md)

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run   # see what it would do
./scripts/setup.sh install
./scripts/setup.sh status
```

Requires `node` (≥18), `bash`, and `git`. macOS ships bash 3.2 and everything here runs on it.

---

## The development loop this gives you

Not a pipeline. Each step is one command, and most sessions use two or three.

### 1 — Before there is code

The expensive decisions get made here, and code review cannot undo them.

```
/grill-me          be interrogated until the requirement is actually pinned down
/investigate       what would this change touch, and what breaks — with file:line
/writing-plans     get a plan onto disk
/design-review     ← the plan, reviewed before anyone implements it
```

`/design-review` looks for what a later code review structurally cannot: **one-way doors** (what
becomes irreversible, and at which moment), migration order, whether every intermediate deploy state
works, and **what the plan does not mention at all** — rollback, existing data, in-flight requests,
the signal that says it worked. Absence is the hardest thing to review and the usual source of
production surprise.

`/investigate` answers under a fixed budget (25 files, 3 search rounds) and escalates cheapest-first:
ripgrep, then structural search, then LSP, and only then reading whole files. It reports confidence as
exactly **Confirmed / Inferred / Unconfirmed** — "probably" and "should be" collapse the distinction
that matters — and names what it did not check.

### 2 — While writing code

```bash
~/private/dotagents/scripts/gate.sh arm    # hold this repo until its checks pass
```

Then work — `/executing-plans`, `/tdd`, `/systematic-debugging` from upstream. Run `/verify` when you
want the evidence rather than the assertion.

**The gate is the point.** An agent stops when work *looks* done; absent a check it can run, that is
the only signal it has, and you become the verification loop. The gate runs your repository's own
commands at the end of a turn and refuses to finish while they are red.

```bash
scripts/gate.sh disarm                     # once everything is green
```

### 3 — After writing code

```
/review-all        layer-by-layer review in parallel subagents, plus the cross-layer risks
/pr-describe       a PR description a reviewer can read before opening the diff
```

`/review-all` classifies the change by layer, reviews each in its own subagent, then looks for what no
single-layer review can see: a contract change and its consumer shipping out of order, config read
live at startup meeting code that has not deployed, a shared default whose correctness depends on
compensating work in a **different** layer.

### 4 — Periodically

```
/skills-audit      the toolkit's own failure mode is accumulation
/skill-scanner     audit a newly installed third-party skill before trusting it
```

### Two habits worth more than any of the above

**`/clear` between unrelated tasks.** A session carrying the last task's context makes worse decisions
about this one.

**When the same check fails twice, stop patching.** Write down what you tried, clear, and restart with
that folded in. Repeated correction accumulates failed approaches and each attempt gets worse. The
gate escalates its own message on the second failure for exactly this reason.

---

## What is in here

Six skills. Everything else is installed from upstream, because methodology is better maintained by
people who work on it full time.

| Skill | What it does |
|---|---|
| `/review-all` | Layer detection, parallel per-layer review, cross-layer irreversibility |
| `/design-review` | Plan review before code exists — one-way doors, migration order, omissions |
| `/investigate` | A codebase question answered with `file:line`, under budget, gaps named |
| `/verify` | Your repository's own checks, run and reported with evidence |
| `/pr-describe` | PR title and description; publishes a visual summary where Artifacts exist |
| `/skills-audit` | Description budget, overlapping triggers, Cursor incompatibility, disuse |

The line for what belongs here: **would this be equally useful to someone with different opinions?**
If yes, it belongs upstream. What stays encodes a particular opinion — what counts as a finding worth
reporting, what makes a review trustworthy, what must be true before work is called done.

### The verification gate

`hooks/dotagents-verify-gate.sh`, on both agents.

**Sentinel-gated.** Inert until `gate.sh arm`. An always-on gate that runs the test suite at the end
of every question-answering session gets switched off within a day, which is worse than not having
one. `gate.sh arm` warns when no profile matches, because an armed gate with nothing to run reports
itself active and passes everything.

**Commands come from a profile**, matched on git remote — so product repositories stay untouched. A
check marked `agent_may_run: false` is never run by the agent (some repositories document that an
agent must not run a particular command) and the gate requires *your* output before it passes. With no
profile it stays silent rather than guessing: an invented `npm test` in an unfamiliar repository is
how a gate loses trust.

**Cursor runs it too, but cannot block.** Cursor's `stop` hook has no refusal mechanism; it
auto-submits a follow-up message instead, capped by `loop_limit`. Both hooks detect the caller and
answer in the right dialect. Treat Cursor's side as a strong nudge and run `/verify` when it matters.
[ADR 0003](docs/adr/0003-cursor-compatible-subset.md) has the parity table.

**When it seems to do nothing**, read `~/.claude/.dotagents-gate/trace.log`. Every invocation is
recorded with the reason it passed. "Nothing happened" has six legitimate causes and that file tells
them apart — it exists because guessing between them once nearly led to changing working code.

### Profiles

Copy [`profiles/dotagents.json`](profiles/dotagents.json) — this repository's own, and the one that
actually runs — or [`profiles/_example.json`](profiles/_example.json), to `profiles/<repo>.json`.

**Your copy is gitignored.** Profiles name real repositories, real environments, sometimes an
employer's internal rules; they stay on the machine that wrote them. `.gitignore` is an allowlist, so
a new profile is untracked by default rather than tracked until someone remembers. `/verify` walks you
through writing one.

### How it is wired

```
dotagents/skills/<name>/
        ↑ symlink
~/.agents/skills/<name>          ← Cursor reads this directly
        ↑ symlink
~/.claude/skills/<name>          ← Claude Code follows the link
```

One physical copy; an edit here takes effect in both agents with no sync step. Only Claude Code gets a
link — Cursor reading `~/.agents/skills/` is **observed, not assumed**
([ADR 0001](docs/adr/0001-global-install-via-agents-dir.md)).

Hooks are **copied**, not linked: a dangling hook symlink exits 127, which is treated as
non-blocking, so the guardrail would open rather than close
([ADR 0002](docs/adr/0002-hooks-are-copied-not-symlinked.md)).

---

## Upstream skills

Not vendored here. Installed alongside, updated with `npx skills check` / `npx skills update`.

**Install selectively.** Every installed description is resident in context permanently, so taking a
whole repository costs the selection accuracy of everything else.

```bash
# methodology — obra/superpowers
npx skills add obra/superpowers -g -a claude-code -a cursor \
  -s brainstorming -s writing-plans -s executing-plans -s verification-before-completion \
  -s requesting-code-review -s receiving-code-review -s systematic-debugging \
  -s test-driven-development -s subagent-driven-development -s dispatching-parallel-agents \
  -s using-git-worktrees -s finishing-a-development-branch -s using-superpowers

# practice — mattpocock/skills
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s handoff -s research -s codebase-design -s resolving-merge-conflicts \
  -s improve-codebase-architecture -s domain-modeling

# operations — addyosmani/agent-skills
npx skills add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s performance-optimization -s observability-and-instrumentation \
  -s documentation-and-adrs -s deprecation-and-migration

# security — getsentry/skills
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s security-review -s find-bugs -s skill-scanner
```

Deliberately omitted, to avoid competing for the same triggers: `mattpocock/tdd` and
`diagnosing-bugs` (superpowers covers both), `addyosmani/code-review-and-quality` and
`spec-driven-development` (covered here and upstream), and anything platform-specific.

Skills run with full agent permissions. `/skill-scanner` audits one for prompt injection and
supply-chain risk — it found a real defect in this repository's own frontmatter, which is what it is
for.

## Status line (opt-in)

Context percentage, model, worktree, branch, session cost. Context percentage earns permanent screen
space because most of the discipline here is about spending it well — green under 67%, red past 85%.

```bash
./scripts/setup.sh install --statusline
```

Missing fields are omitted rather than shown as "unknown": field names change between versions, and a
status line reporting stale numbers is worse than a short one.

## Writing a skill

Start from [`_template/SKILL.md`](_template/SKILL.md), then `./scripts/verify-skills.sh`.

The invariants are in [`AGENTS.md`](AGENTS.md) — that file is the always-loaded layer and holds the
ones that fail *silently*. The one that governs everything else: **strip every Claude-only frontmatter
field and the skill must still behave the same**, because Cursor ignores them without saying so, and
runs a different model family besides.

## Tests

```bash
./scripts/verify-skills.sh      # skill lint
./scripts/test-verify-gate.sh   # 42 tests — the gate
./scripts/test-setup.sh         # 14 tests — the installer, against a fake HOME
```

CI runs both suites on **Linux and macOS**, because breakage has gone in both directions: bash 4
constructs that pass on Linux and fail on macOS, and `mktemp -t` spellings that work on BSD and fail
on GNU coreutils.

The gate and the installer are the two things with real tests, and for opposite reasons. The gate must
fail *closed* — every fail-open bug found in it has a regression test. The installer edits files it
does not own, holding other people's credentials and other tools' hooks — its tests assert that a
secret it did not write survives, that three other tools' hooks survive, and that uninstall leaves
nothing behind.

## Secrets

Nothing secret lives here, and the installer does not touch what it did not write. `setup.sh` merges
only the keys its templates declare, records them in `~/.claude/.dotagents-managed.json`, backs up
first, and never rewrites an existing value it does not own. Existing hooks are appended to, never
replaced.

`uninstall` restores every key to its original **value** — not the file to its original **bytes**.
Settings are rewritten with a fixed layout, so a differently formatted file comes back reformatted.
`test-setup.sh` asserts the values, which is what can honestly be promised.

CI runs gitleaks over full history.

## License

[MIT](LICENSE)
