# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A personal AI development toolkit. Skills, hooks, and repository profiles that work in **both Claude
Code and Cursor**, installed once globally and available in every repository.

No product repository is ever modified. Anything repository-specific lives here as a profile, and
profiles are gitignored.

日本語版: [README.ja.md](README.ja.md)

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run   # see what it would do
./scripts/setup.sh install
./scripts/setup.sh status
```

## The skills

| Skill | What it does |
|---|---|
| `/review-all` | Detects which layers a change touches, runs the matching layer reviews in parallel subagents, and surfaces the cross-layer irreversibility risks no single-layer review can see |
| `/design-review` | Reviews a plan before any code exists — one-way doors, migration order, backward compatibility, rollback, and what the plan left out entirely |
| `/investigate` | Answers a specific question about the codebase with `file:line` evidence, under a fixed exploration budget, and names what it could not confirm |
| `/verify` | Runs a repository's own verification commands and reports with evidence. Refuses to guess commands, refuses to run what the repository forbids |
| `/pr-describe` | Writes a PR title and description a reviewer can read before opening the diff |
| `/skills-audit` | Audits the installed skills for description-budget bloat, overlapping coverage, Cursor incompatibility, and disuse |

## How it is wired

```
dotagents/skills/<name>/
        ↑ symlink
~/.agents/skills/<name>          ← Cursor reads this natively
        ↑ symlink
~/.claude/skills/<name>          ← Claude Code follows the link
```

One physical copy. Editing a file here takes effect in both agents immediately, with no sync step
and nothing to drift.

Hooks are the exception: they are **copied**, not linked. A dangling hook symlink exits 127, which
Claude Code treats as non-blocking — the guardrail would open rather than close. See
[ADR 0002](docs/adr/0002-hooks-are-copied-not-symlinked.md).

## The verification gate

An agent stops when work *looks* done. Without a check it can actually run, "looks done" is the only
signal available, and the human becomes the verification loop.

`hooks/dotagents-verify-gate.sh` runs at the end of a turn and refuses to finish while a
repository's own checks are failing.

**Sentinel-gated.** It does nothing unless a skill armed it. An always-on gate that runs the test
suite at the end of every question-answering session gets disabled within a day, which is worse than
not having one.

**Commands come from a profile**, matched on the git remote, so product repositories stay
unmodified. A check marked `agent_may_run: false` is never run by the agent — some repositories
document that an agent must not run a particular command — and the gate requires the user's own
output before it will pass. With no profile, the gate stays silent rather than guessing: an invented
`npm test` in an unfamiliar repository is how a gate loses trust.

**Cursor runs the same gate, but it cannot block.** Cursor's `stop` hook has no refusal mechanism;
the best it can do is auto-submit a follow-up message so the agent keeps working, capped by Cursor's
`loop_limit`. Both hooks detect which agent called them and answer in the right dialect. Treat the
Cursor side as a strong nudge rather than a gate, and run `/verify` explicitly when it matters. The
parity table is in [ADR 0003](docs/adr/0003-cursor-compatible-subset.md).

### Profiles

Copy [`profiles/_example.json`](profiles/_example.json) to `profiles/<repo>.json` and edit. Your copy
is **gitignored** — profiles name real repositories, real environments, and sometimes an employer's
internal rules, so they stay on the machine that wrote them. Only the schema and the example are
tracked. `/verify` will walk you through writing one.

## Upstream skills

Third-party skills are not vendored here. They are installed alongside and updated with
`npx skills check` / `npx skills update`. **Install selectively** — every installed skill's
description is resident in context permanently, so taking a whole repository costs the selection
accuracy of everything else.

```bash
# methodology
npx skills add obra/superpowers -g -a claude-code -a cursor \
  -s brainstorming -s writing-plans -s executing-plans -s verification-before-completion \
  -s requesting-code-review -s receiving-code-review -s systematic-debugging \
  -s test-driven-development -s subagent-driven-development -s dispatching-parallel-agents \
  -s using-git-worktrees -s finishing-a-development-branch -s using-superpowers

# practice
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s handoff -s research -s codebase-design -s resolving-merge-conflicts \
  -s improve-codebase-architecture -s domain-modeling

# operations
npx skills add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s performance-optimization -s observability-and-instrumentation \
  -s documentation-and-adrs -s deprecation-and-migration

# security
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s security-review -s find-bugs -s skill-scanner
```

Deliberately not installed, to avoid competing for the same triggers: `mattpocock/tdd` and
`diagnosing-bugs` (superpowers covers both), `addyosmani/code-review-and-quality` and
`spec-driven-development` (covered here and by superpowers), and anything specific to a platform
this toolkit does not target.

Skills run with full agent permissions. `/skill-scanner` audits one for prompt injection and
supply-chain risk — worth running against anything new. It found a real defect in this repository's
own frontmatter, which is the sort of thing it is for.

## Status line (opt-in)

`hooks/dotagents-statusline.sh` shows context percentage, model, worktree, branch, and session cost.
Context percentage earns permanent screen space because most of the discipline here is about
spending it well — green under 50%, yellow past 67%, red past 85%.

Not wired by default; a status line is a personal choice.

```bash
claude config set --global statusLine.type command
claude config set --global statusLine.command '$HOME/.claude/hooks/dotagents-statusline.sh'
```

Every field is optional and missing ones are omitted rather than rendered as "unknown". Field names
vary across versions, and a status line reporting stale numbers is worse than a short one.

## Writing a skill

Start from [`_template/SKILL.md`](_template/SKILL.md), then run `./scripts/verify-skills.sh`.

**The one rule that matters: strip every Claude-only frontmatter field and the skill must still
behave the same.** Cursor understands `name`, `description`, `paths`, and
`disable-model-invocation`, and silently ignores the rest. A constraint encoded in `allowed-tools`
is simply absent there, with no warning. So constraints go in the body as prose, and Claude-only
frontmatter is optimisation on top. The linter enforces this.

**Never set `disable-model-invocation`.** It blocks programmatic `Skill` calls and subagent
preloading too, so any skill that dispatches to another breaks with no error.

Keep `SKILL.md` at or under 12 KB. Skill bodies stay in context until the session ends and are not
re-read; after auto-compaction only the first ~5,000 tokens of each are restored. Long material
belongs in `reference/`, loaded on demand.

## Tests

```bash
./scripts/verify-skills.sh      # skill lint
./scripts/test-verify-gate.sh   # 20 tests for the verification gate
```

The gate has real tests because it is the one component that must fail *closed*. They cover staying
silent when unarmed, blocking on failure, escalating on a repeated failure, not guessing for unknown
repositories, refusing to accept "I asked the user to run it" as a result, and — on the Cursor path —
not consuming the whole follow-up budget.

## Secrets

Nothing secret lives here, and the installer is built not to touch what it did not write.

`setup.sh` merges only the keys its templates declare, records exactly what it wrote to
`~/.claude/.dotagents-managed.json`, backs up before editing, and never reads or rewrites an
existing value it does not own — including any credentials already in your agent settings. Existing
hooks are appended to rather than replaced. `./scripts/setup.sh uninstall` takes back precisely what
was added, and the revert is verified byte-identical.

CI runs gitleaks over full history.

## License

[MIT](LICENSE)
