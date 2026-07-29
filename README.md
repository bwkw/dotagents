# dotagents

[![ci](https://github.com/bwkw/dotagents/actions/workflows/ci.yml/badge.svg)](https://github.com/bwkw/dotagents/actions/workflows/ci.yml)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A personal AI development toolkit for **Claude Code and Cursor**. Installed once, globally, and
available in every repository. No product repository is ever modified.

日本語版: [README.ja.md](README.ja.md)

The loop, with sources: [docs/workflow.md](docs/workflow.md) · Why it is shaped this way, and whose
practices it is built from: [docs/design.md](docs/design.md) · Which mechanism to use:
[docs/mechanisms.md](docs/mechanisms.md) · Decisions: [docs/adr/](docs/adr/)

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents
cd ~/private/dotagents
./scripts/setup.sh install --dry-run   # see what it would do
./scripts/setup.sh install
./scripts/setup.sh status
```

Requires `node` (≥18), `bash`, and `git`. macOS ships bash 3.2 and everything here runs on it.

---

## Pick by what you are doing

Five use cases. Each is entered on its own — this is not one pipeline with branches.
**●** is from this repository, **○** upstream, **◆** built into Claude Code.

### 1. Build a feature

| Step | Type | What it is for |
|---|---|---|
| **0. Survey** | ○ `/research` | "What do people actually do about this?" External primary sources, written to a file in the repo. **The options and their tradeoffs come out of this**, and the file outlives `/clear` |
| **1. Settle it** | ○ `/grill-me` | Interrogates the option you picked until the requirement is actually pinned down |
| | ● `/da-investigate` | What a change would touch in *this* codebase — `file:line`, under a budget, naming what it could not confirm |
| **2. Write it down** | ○ `/documentation-and-adrs` | The decision, as an ADR |
| | ○ `/writing-plans` | The spec, on disk. (Or openspec, if the repository uses it) |
| | **● `/da-design-review`** | Reviews what you wrote **before code exists** — one-way doors, migration order, rollback, and a past-tense pre-mortem |
| | `/clear` | The plan is on disk. Implement in a fresh session |
| **3. Implement** | ○ `/executing-plans` | Work through the written plan with checkpoints |
| | ○ `/using-git-worktrees` | When the work needs isolating from the current workspace |
| | **● `/da-verify`** | Runs *this repository's* configured checks and reports evidence. **Also arms the gate** |
| **4. Review and iterate** | see use case 4 | |

Test-first is not a step here: it is a standing rule in `AGENTS.md`, because a default that needs
invoking is not a default. ○ `/test-driven-development` holds the detailed process when you want it.

### 2. Investigate

Two different questions, two different tools. Reaching for the wrong one is the common mistake.

| The question | Type | Notes |
|---|---|---|
| "How does the world do this?" | ○ `/research` | External sources. Writes findings to a file, and can run in a background agent |
| "Where does X live / what depends on it / what would break?" | ● `/da-investigate` | **This** codebase. 25 file reads, 3 search rounds, then it **stops and says what it did not check**. Reports Confirmed / Inferred / Unconfirmed as three distinct things, and retries a negative result with different vocabulary before asserting it |

`/da-investigate` fans out to ● `da-codebase-explorer` subagents, so the reading stays in their context
rather than yours.

### 3. Fix a bug

| Step | Type | Notes |
|---|---|---|
| **Investigate** | **○ `/systematic-debugging`** | Root cause **before** fix, and it refuses to skip ahead. This is not a review — pointing a review skill at a bug returns a list of nearby imperfections instead of the cause |
| | ● `/da-investigate` | Only once you have a suspect, for its blast radius |
| **Fix** | ○ `/systematic-debugging` | Its own Phase 4 carries the fix through |
| **Prove it** | **● `/da-verify`** | And the bugfix starts with a test that reproduces the bug, so "fixed" means something |

### 4. Review

| | Type | Notes |
|---|---|---|
| **Your own work** | **● `/da-review-all`** | The only review entry to type. Classifies the change, dispatches to the layers that apply, then finds what falls *between* them |
| | ◆ `/code-review` or ○ `/find-bugs` | **A second reviewer, deliberately a different one.** Four reviewers over the same 146 PRs caught 93.4% of findings with exactly one of the four |
| | **● `/da-fix-plan`** | The findings → an ordered plan. **Its main job is deciding what not to fix** |
| | ○ `/receiving-code-review` | When feedback arrives and you want to evaluate it rather than implement it reflexively |
| | ● `/da-pr-describe` | The PR description. **Type it** — it never fires on its own |
| **Someone else's PR** | ◆ `/review <PR>` | The GitHub view |
| | ● `/da-review-all <base>` | For depth. **Reconstructs the intent from the description, issue and commits before producing a single finding** — a difference in approach is not a defect, and pre-existing problems are labelled and do not block |
| **Narrower passes** | ◆ `/security-review` · ◆ `/simplify` | Security only; quality only and explicitly not a bug hunt |

`da-review-backend` / `-frontend` / `-infra` are full skills but **not in the `/` menu** — the dispatcher
reaches them, and so does naming a layer ("review the backend"). One thing to type, three layers of depth.

### 5. Maintain the toolkit

| Type | When |
|---|---|
| ◆ `/skill-doctor` | **First.** Which loaded skills are unused and costing context |
| ◆ `/doctor` | The listing's real context cost, and its biggest contributors |
| ● `/da-skills-audit` | Over-constraint, overlapping triggers, Cursor incompatibility, size |
| ○ `/skill-scanner` | Before trusting a newly installed third-party skill. Security, not bloat |
| ○ `anthropic-skills:skill-creator` | The only thing that measures whether a skill **helps**: with-skill vs without-skill pass rate, tokens, time |

### Three rules that matter more than any command

- **If you could describe the diff in one sentence, skip the plan.**
- **`/clear` between the plan and the implementation**, and between unrelated tasks.
- **Two failed corrections on the same issue → discard the session** and rewrite the prompt with what you
  learned. A clean session with a better prompt beats a long one carrying failed approaches.

[`docs/workflow.md`](docs/workflow.md) has the reasoning, the sources, and the places good sources
disagree.

### The gate, and when you touch it directly

`/da-verify` arms the gate as its first step, so **there is no separate arming step in any use case
above.** Once armed, the end of every turn runs this repository's checks and refuses to finish while they
are red.

```bash
scripts/gate.sh arm       # hold from the FIRST turn, before any verify has run
scripts/gate.sh disarm    # back to question-answering; no suite on the way out
```

> **Not an unattended-overnight lock.** Arming early raises the odds that a session you are not watching
> ends green, and that is all. **Claude Code releases a Stop hook after 8 consecutive blocks**, so a
> genuinely stuck run gets let through; **on Cursor it cannot block at all**, only nudge, and it stops
> nudging at the third message; and a hook that keeps refusing is not progress — two failed corrections
> means discard the session, the opposite of holding it open. What survives across sessions is the spec
> on disk, the checks in CI, and commits as recovery points.

## What is in here

**Ten skills are written here**; the other eleven are installed from upstream, because methodology is
better maintained by people who work on it full time. Ours are the ones that encode an opinion —
what counts as a finding worth reporting, what makes a review trustworthy, what must be true before
work is called done. They are marked **●** throughout.

Plus two subagents in `agents/`, installed globally so they exist in every repository:
**`da-review-verifier`** (adversarial, refutes by default, never took part in finding) and
**`da-codebase-explorer`** (read-only tracing, `file:line` evidence, explicit budget). The review skills
dispatch to them by name. Before they existed, five files said "prefer a purpose-built agent when the
repository defines one" — and since this toolkit never adds a file to a product repository, that branch
could never be taken. See [ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md).

## The whole surface, and what is suppressed

**Type `/da` and you have exactly this repository's set.** Everything shipped here is prefixed `da-`
(for dotagents) — ten skills and two subagents. That solves two problems at once: at the `/` menu
there is otherwise no way to tell ours from everything else, and an unprefixed name can shadow a built-in
silently, which already happened once when a skill called `review` hid Claude Code's own `/review`.

### How big the surface actually is

**72 names are reachable, not 21.** This matters because the budget they share is 1% of the context
window, and because two earlier audits of this repository were wrong by reading the filesystem:

| Source | Names | Where |
|---|---|---|
| On disk | 21 | `~/.agents/skills/` — 10 ours, 11 upstream |
| Anthropic-managed plugin | 11 | under `~/Library/Application Support/Claude/…`, server-synced |
| **Compiled into the CLI binary** | **40** | **no files exist** — they live inside the executable |

So a count from `~/.agents/skills` is not the total. `/doctor` and `/skill-doctor` see all of it.
Eight names are suppressed via `skillOverrides` — see [Suppressed](#suppressed-and-why-not-more) below.

### Where triggers still overlap, and who wins

| Ask | Goes to | Second opinion |
|---|---|---|
| "review this" | `/da-review-all` — or `/find-bugs`; a bare phrasing may pick either | `/code-review` |
| "is this secure" | `/find-bugs` (bugs + security + quality) | `/security-review` |
| "am I done" | `/da-verify`. Without a profile it **stops and hands you one to fill in** — there is no fallback skill any more, and no gate until you save it |
| "clean this up" | `/simplify` — quality only, by design | — |
| "run it every day" | bundled `/schedule` | `/loop` for a single repeating check |

### Suppressed, and why not more

Six names are set to `name-only` or `off` in `skillOverrides`, merged by `setup.sh` and reverted exactly
by `uninstall`: `claude-api` (auto-fires on triggers this
repository hits constantly), `anthropic-skills:schedule` (**two live skills are named `schedule`**), the
office-file set `docx`/`pptx`/`xlsx`/`pdf` (long descriptions, no dev-loop use), and `morning`/`setup-cowork`.

**The reviewers are not suppressed, on purpose.** The usage log shows bundled `code-review` at 42
invocations and `review` at 24 — they are in real use — and reviewer diversity is the single
best-supported review practice available. `disableBundledSkills` would have removed all of them at once,
and it exists only in CLI 2.1.219+, so it would silently do nothing under an older `claude` on `$PATH`.
This machine has both versions. See [ADR 0006](docs/adr/0006-one-review-entry-and-the-real-command-surface.md).

### Why these are skills, and not "commands"

There is no separate commands directory here, and that is deliberate rather than an omission.
[Official guidance](https://code.claude.com/docs/en/skills) is explicit: *"Custom commands have been
merged into skills… Skills are recommended."* There is no documented case where a bare
`commands/*.md` is preferable. Cursor's commands documentation page is now a 404.

A **slash command** was a prompt template: you typed `/name`, it expanded, that was the whole
mechanism. A **skill** is a directory — `SKILL.md` plus reference files it loads only when needed — and
it can be reached three ways: you type `/name`, the model picks it from the `description` because the
request matched, or another skill calls it by name. The first way is a strict subset of what a skill
does, so anything written as a command is a skill with two capabilities switched off.

The prompt-template case has not disappeared; it is now spelled `disable-model-invocation: true`, which
also drops the description from context entirely and so costs no budget. `/da-pr-describe` uses it — it
writes to GitHub, so the timing is yours. `/da-verify` and the three layer reviews must never use it,
because something reaches them by name; both the lint hook and the linter enforce that, with tests.
[`docs/mechanisms.md`](docs/mechanisms.md) has the full taxonomy with sources.

That matters concretely for these four. `/da-review-backend` is one skill that has to work when **you**
invoke it directly and when **`/da-review-all`** invokes it as one of several layers. As a command it
would need to be two files that drift apart, which is exactly how this repository's predecessor
decayed. The single reference set — posture, process, discipline, silent-failure patterns — is shared
by symlink, so a change to the discipline reaches every layer and the cross-layer pass at once.

Practically: **type `/` and everything is in one list.** Nothing here is invoked a second, different
way.

### Where the upstream eleven come from

Chosen from collections that are widely used and actively maintained, and **installed selectively** —
never a whole repository, because every description shares one budget. Only what a flow above actually
reaches.

| Source | Installed from it | Why this collection |
|---|---|---|
| **[obra/superpowers](https://github.com/obra/superpowers)** — 6 | `writing-plans` · `executing-plans` · `test-driven-development` · `systematic-debugging` · `receiving-code-review` · `using-git-worktrees` | The methodology backbone: plan → implement → verify, plus the debugging discipline. Multi-harness, `AGENTS.md` and tests of its own. This is where the *process* comes from |
| **[mattpocock/skills](https://github.com/mattpocock/skills)** — 2 | `grill-me` · `research` | Sharp, single-purpose tools. `grill-me` is the interrogation that turns an option into a settled requirement, and it costs zero budget (`disable-model-invocation`); `research` is the external survey the design flow starts from |
| **[getsentry/skills](https://github.com/getsentry/skills)** — 2 | `find-bugs` · `skill-scanner` | From a company whose product is finding production failures. `find-bugs` enumerates the attack surface before it sweeps — a different shape from our layered review, which is exactly why it is the second reviewer. `skill-scanner` found a real defect in this repository's own frontmatter |
| **[addyosmani/agent-skills](https://github.com/addyosmani/agent-skills)** — 1 | `documentation-and-adrs` | Just the ADR practice. The other four from this collection were removed as off-loop; this one was removed too and **reinstated**, because writing the ADR is where the design flow starts |

Bundled in Claude Code and used rather than suppressed: `/code-review`, `/review`, `/security-review`,
`/simplify`, `/verify`, `/run`, `/doctor`, `/skill-doctor`. Plus `anthropic-skills:skill-creator`, which
is the only thing here that can measure whether a skill helps.

**The selection rule, and why nothing is vendored.** Methodology is better maintained by people who work
on it full time, so it is installed alongside rather than copied in — `npx skills check` shows what
changed upstream before `npx skills update` takes it. A vendored copy would be a fork nobody maintains.
The cost of that choice is that an upstream skill **cannot be edited here**: a fix in place is lost on the
next update, so the only levers are install and remove. That is why the `da-` prefix marks ours and
upstream keeps its own names.

The line for what belongs here: **would this be equally useful to someone with different opinions?**
If yes, it belongs upstream. What stays encodes a particular opinion — what counts as a finding worth
reporting, what makes a review trustworthy, what must be true before work is called done.

### The frontmatter guard

`hooks/dotagents-lint-skill-frontmatter.sh`, on both agents. **The one hook you meet without asking for
it** — it runs on every `Write`/`Edit` and only reacts to a path ending in `SKILL.md`.

If you write a skill and the edit is **refused**, this is why:

| It refuses | Because |
|---|---|
| no `name`, or no `description` | The skill appears in the menu and never fires. Nothing else reports that. |
| frontmatter opened with `---` and never closed | Same failure, harder to spot. |
| `disable-model-invocation` on `da-verify` | It is the only thing that arms the gate, so the guardrail would open. |
| `disable-model-invocation` on a layer review | `da-review-all` would report that layer as covered while reviewing nothing. |

It **asks rather than refuses** when a description says what a skill does but not *when* to use it — that
still works when typed, it just will not fire on its own. Everything else passes. This hook only
inspects, so if it crashes it falls through open; the one that must fail closed is the gate below.

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
answer in the right dialect. Treat Cursor's side as a strong nudge and run `/da-verify` when it matters.
[ADR 0003](docs/adr/0003-cursor-compatible-subset.md) has the parity table.

**When it seems to do nothing**, read `~/.claude/.dotagents-gate/trace.log`. Every invocation is
recorded with the reason it passed. "Nothing happened" has six legitimate causes and that file tells
them apart — it exists because guessing between them once nearly led to changing working code.

### Profiles

Copy [`profiles/dotagents.json`](profiles/dotagents.json) — this repository's own, and the one that
actually runs — or [`profiles/_example.json`](profiles/_example.json), to `profiles/<repo>.json`.

**Your copy is gitignored.** Profiles name real repositories, real environments, sometimes an
employer's internal rules; they stay on the machine that wrote them. `.gitignore` is an allowlist, so
a new profile is untracked by default rather than tracked until someone remembers. `/da-verify` walks you
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

### Cursor sees a different, larger menu — and this is not fully solved

Both agents are first class, but the surfaces are **not** the same size, and the difference runs one way:

| | Claude Code | Cursor |
|---|---|---|
| From `~/.agents/skills` | 21, **minus the 3 layer reviews** hidden by `user-invocable: false` | **all 21** — Cursor ignores that field, so the layer reviews appear in its menu |
| Built-in | ~40 compiled into the CLI | **19 of its own**: `review`, `review-bugbot`, `review-security`, `create-skill`, `create-rule`, `create-subagent`, `loop`, `automate`, `babysit`, `split-to-prs`, `onboard`, `shell`, `sdk`, `canvas`, `statusline`, `migrate-to-skills`, `create-hook`, `update-cli-config`, `update-cursor-settings` |
| `skillOverrides` suppressions | 8 active | **0** — Cursor does not read `settings.json` |

Two consequences worth being blunt about:

**The layer reviews leak into Cursor's menu.** In Claude Code there is one review entry to type; in
Cursor there are four of ours plus `review`, `review-bugbot`, `review-security` and `find-bugs`. Typing a
layer directly in Cursor still works correctly — it is the same skill — so this costs menu clarity, not
behaviour, which is the line [ADR 0003](docs/adr/0003-cursor-compatible-subset.md) draws. It is
nonetheless the largest remaining divergence, and it is **not fixed**.

**The 9 suppressions do not apply there, and mostly do not need to.** Six of the eight target skills that
do not exist in Cursor at all — bundled and Anthropic-plugin ones — so there is nothing to suppress.
All eight now target skills Cursor does not have, so after the latest pruning **there is nothing left
that needed suppressing on that side.**

**What is not known:** whether Cursor's 19 can be disabled, and where. Its own settings surface was not
read, so nothing here claims to prune them. If they crowd the menu enough to matter, that is the next
thing to find out rather than something already handled.

### Every script here, and what justifies it

Script sprawl is the failure mode of a toolkit like this, so each one has to name what it prevents.
Nine files, and **two were deleted for failing this test.**

| File | Lines | Why it exists |
|---|---|---|
| `scripts/setup.sh` | 557 | The distribution mechanism. Links skills and agents, copies hooks, merges settings key-scoped, prunes what the repo no longer ships, and reverts exactly what it added. Without it nothing installs |
| `scripts/lib/merge-settings.mjs` | 271 | The safe half of that: merges only declared keys, never rewrites a value it did not write, records what it touched. It edits a file holding someone else's API key |
| `hooks/dotagents-verify-gate.sh` | 407 | The gate. The whole value proposition — an agent stops when work *looks* done |
| `hooks/dotagents-lint-skill-frontmatter.sh` | 124 | Refuses a `SKILL.md` that would install broken and never say so |
| `scripts/gate.sh` | 158 | The gate's control surface: arm, disarm, record a delegated check, report state. Called by `/da-verify`, not usually by you |
| `scripts/verify-skills.sh` | 360 | The `AGENTS.md` invariants, as checks. **Caught:** frontmatter that no YAML parser accepts, `allowed-tools` omitting a tool the body uses, references never mentioned in the body, an unreachable `user-invocable: false` |
| `scripts/test-verify-gate.sh` | 405 | 42 assertions. The gate is the one thing that must fail *closed*, and it failed open twice before these existed |
| `scripts/test-lint-hook.sh` | 175 | 33 assertions. **Caught the worst bug in this repository:** a scope check that matched the wrong variable and therefore never fired — installed, and enforcing nothing |
| `scripts/test-setup.sh` | 141 | 18 assertions against a fake `$HOME`. The installer edits files holding credentials and other tools' hooks |
| `scripts/check.sh` | 68 | One command for all of the above, so it is one thing to remember instead of four |

**Deleted, because they failed the same test:**

| Removed | Why |
|---|---|
| `hooks/dotagents-statusline.sh` + its template + `--statusline` | An opt-in that was **never opted into.** 72 lines plus an installer function, rendering a status line nothing ever asked for. It also forced an exception into the "every hook must be able to block" check, because it was the only hook that could not |
| `templates/claude.advisor.snippet.json` + `--advisor` | Same: **never enabled.** And the feature behind it is experimental and Anthropic-API-only, so the flag documented a capability most environments do not have |

The pattern in both: **an option, for a thing, that was never turned on.** That is what makes a toolkit
annoying to own — not the count of files, but files whose purpose you have to reconstruct before you can
decide whether to keep them. Anything here that cannot answer "what does it prevent" in one line should
go the same way.

## Upstream skills

Not vendored here. Installed alongside, updated with `npx skills check` / `npx skills update`.

**Install selectively.** Every installed description is resident in context permanently, so taking a
whole repository costs the selection accuracy of everything else.

```bash
# methodology — obra/superpowers
npx skills add obra/superpowers -g -a claude-code -a cursor \
  -s writing-plans -s executing-plans -s receiving-code-review \
  -s systematic-debugging -s test-driven-development -s using-git-worktrees

# practice — mattpocock/skills
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s research

# security — getsentry/skills
npx skills add getsentry/skills -g -a claude-code -a cursor \
  -s find-bugs -s skill-scanner

# decision records — addyosmani/agent-skills
npx skills add addyosmani/agent-skills -g -a claude-code -a cursor \
  -s documentation-and-adrs
```

Deliberately omitted, to avoid competing for the same triggers: `mattpocock/tdd` and
`diagnosing-bugs` (superpowers covers both), `addyosmani/code-review-and-quality` and
`spec-driven-development` (covered here and upstream), and anything platform-specific.

**Uninstalling leaves the skill live in Cursor.** `npx skills remove <name> -g -a claude-code -a cursor`
unlinks the agent directories and updates the lockfile, but leaves the real directory in
`~/.agents/skills/` — the path Cursor reads natively. Delete it too, then check the two agree:

```bash
diff <(ls -1 ~/.agents/skills) <(ls -1 ~/.claude/skills)
```

**Removed after measuring**, not on a hunch. `/da-skills-audit` compares descriptions pairwise for
shared trigger vocabulary; these two scored highest and lost:

- `getsentry/security-review` — 33% overlap with `find-bugs`, which covers bugs *and* security *and*
  quality over the same branch diff. Claude Code bundles its own `security-review`, and a personal
  skill of that name shadows it, so removing this one gives the built-in back rather than losing
  anything.
- `obra/subagent-driven-development` — 28 KB, more than twice the size limit, and invoking it parks
  all of that in context for the session.

**Eleven more removed on 2026-07-28**, taking the set from 35 skills to 24 and resident descriptions
from 6,905 to 3,559 characters. Every by-name reference was checked first.

**A third round, on 2026-07-29, took it to 21 — 10 ours and 11 upstream.** Six went because no use case
above reaches them, which is the only test that matters now that the use cases are written down:

| Removed | Why, and what it cost |
|---|---|
| `requesting-code-review` | Nothing referenced it and no use case reaches it. `/da-review-all` is how a review starts here |
| `brainstorming` | Superseded by `/research` → `/grill-me`. Its own description (*"You MUST use this before any creative work"*) also made it fire ahead of both. **Cost:** a dangling name in upstream `writing-plans`, which cannot be edited without losing the fix on the next update |
| `finishing-a-development-branch` | Integration decisions are made by hand. **Cost:** a dangling name in `executing-plans` |
| `handoff` · `resolving-merge-conflicts` | Situational, and the situations were handled without them |
| `verification-before-completion` | **This one has a real cost, taken deliberately.** It was the fallback when a repository has no profile, so `/da-verify` now *stops* there instead of degrading — and stopping is only acceptable because it was changed to hand back a filled-in profile from the repository's own manifests, and to say plainly that there is no gate until you save it. **Cost:** a dangling name in `systematic-debugging` |

Three dangling names in upstream skills, all accepted for the same reason: editing an upstream file in
place is lost on the next `npx skills update`, and a stale name costs less than keeping a skill no flow
uses. Every one of the six was checked for inbound references and recorded usage before removal.

| Removed | Why |
|---|---|
| `find-skills` | Taught `npx skills add` **without `-s`**, which this repository has an invariant against |
| `using-superpowers` | Requires skill invocation "before ANY response including clarifying questions", which contradicts `/da-investigate` and `/da-design-review` — both refuse an unstated goal |
| `observability-and-instrumentation`, `performance-optimization`, `deprecation-and-migration` | Specialist advisory, off the development loop |
| ~~`documentation-and-adrs`~~ | **Removed, then reinstated.** Cut as "specialist advisory" without knowing that writing an ADR is the first step of the design flow — this repository has seven of them. The wrong call, made from a guess about the workflow rather than the workflow itself |
| `codebase-design`, `domain-modeling`, `improve-codebase-architecture` | A mutually-referencing set; removed together so nothing dangles |
| `dispatching-parallel-agents` | The harness provides parallel agents natively |
| ~~`research`~~ | **Removed, then reinstated** — the second time this mistake was made. Cut because "the harness has WebFetch", which confuses *having the tool* with *having the practice*: surveying primary sources and writing the findings to a file that survives `/clear` is the first phase of the design flow, and a raw WebFetch call is not that |

**These removals are not backed by usage data**, and it is worth saying so: 34 of the 35 were installed
the same day, so "never invoked" meant "installed hours ago". They rest on structure — a dangling
reference, a behavioural conflict, a duplicate of a native capability — not measurement. See
[ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md).

Skills run with full agent permissions. `/skill-scanner` audits one for prompt injection and
supply-chain risk — it found a real defect in this repository's own frontmatter, which is what it is
for.


## Writing a skill

Start from [`_template/SKILL.md`](_template/SKILL.md), then `./scripts/verify-skills.sh`.

The invariants are in [`AGENTS.md`](AGENTS.md) — that file is the always-loaded layer and holds the
ones that fail *silently*. The one that governs everything else: **strip every Claude-only frontmatter
field and the skill must still behave the same**, because Cursor ignores them without saying so, and
runs a different model family besides.

## Tests

```bash
./scripts/check.sh              # everything: syntax, symlink, lint, 93 behavioural assertions
./scripts/check.sh --fast       # syntax and lint only
```

Individually, when one of them is what you are working on: `verify-skills.sh` (lint),
`test-verify-gate.sh` (42), `test-lint-hook.sh` (33), `test-setup.sh` (18).

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
