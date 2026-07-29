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

## The development loop this gives you

Not a pipeline. Each step is one command, and most sessions use two or three.

Officially the loop is **Explore → Plan → Implement → Commit**, with *verify* as a property every phase
needs rather than a step, and *review* as an **escalation** for risky or unwatched work rather than a
ritual after every diff. [`docs/workflow.md`](docs/workflow.md) has the full version with sources, the
abort conditions, and the parts the good sources disagree about. The three rules worth memorising:

- **If you could describe the diff in one sentence, skip the plan.**
- **`/clear` and start a fresh session between planning and implementing.** The plan is on disk by then.
- **Two failed corrections on the same issue → discard the session** and rewrite the prompt with what
  you learned. A clean session with a better prompt beats a long one carrying failed approaches.

### Five phases, plus two side flows

Real work does not arrive as one linear loop. Pick the flow, then read only that row.
**●** is from this repository, **○** upstream, **◆** built into Claude Code.

| Flow | In order |
|---|---|
| **0. Survey the ground** — "what do people actually do about this?" | ○ `/research` — external primary sources, findings written to a file in the repo. **Options with tradeoffs come out of this**, and the file survives `/clear` |
| **1. Settle what you are building** | ○ `/grill-me` against the options → ● `/da-investigate` for what a change would touch in *this* codebase |
| **2. Write it down** | ○ `/documentation-and-adrs` for the decision, openspec or ○ `/writing-plans` for the spec → **● `/da-design-review`** on what you wrote → then `/clear` |
| **3. Implement** | ○ `/executing-plans` if there is a plan — **test-first either way** → **● `/da-verify`** |
| **4. Review critically and iterate** | **● `/da-review-all`** → a second reviewer: ◆ `/code-review` or ○ `/find-bugs` → **● `/da-fix-plan`** → fix → ● `/da-verify` → ● `/da-pr-describe` |
| *Someone else's PR* | ◆ `/review <PR>`, or ● `/da-review-all <base>` for depth → ● `/da-fix-plan` if you are collecting the comments |
| *An error* | **○ `/systematic-debugging`** — root cause before fix, and it refuses to skip → ● `/da-investigate` for the blast radius once you have a suspect. Its own Phase 4 carries the fix → ● `/da-verify` |

Four things about that table, all of which used to be implicit:

**Not everything is `da-`, on purpose.** The prefix marks what this repository *owns and may rewrite*.
Upstream skills keep their own names because editing one in place is lost on the next
`npx skills update` — a `da-` wrapper around `/grill-me` would be a second file that drifts, which is the
failure this toolkit exists to avoid. `/da` narrows the menu to what is ours; the flows deliberately reach
past it.

**Test-first is the base, not a step.** It is a standing rule in `AGENTS.md` rather than a skill you must
remember, because a default that needs invoking is not a default. `/test-driven-development` holds the
detailed process when you want it. A bugfix starts with a test that reproduces the bug, and tests written
*after* the implementation get labelled as such rather than presented as verification.

**`gate.sh arm` is gone from the implement flow, because `/da-verify` arms the gate itself** — its Step 0
does exactly that. Running `/da-verify` once, typed or auto-fired, makes the end-of-turn gate active for
the rest of the session. Reach for `arm` directly only in the case verify cannot cover: arming *before*
any verify has run, for an unattended session you want held from the first turn. `disarm` when the
repository goes back to answering questions and you do not want a suite on the way out.

**Reviewing someone else's work is a different posture.** You do not know the intent, so the first pass
reconstructs it from the description, the issue, the commits and any referenced spec, and **states it back
before producing a single finding**. A difference in approach is not a defect; pre-existing problems are
labelled and do not block. And **error investigation is not review** — pointing a review skill at a bug
returns a list of nearby imperfections instead of the cause.

### 1 — Before there is code

The expensive decisions get made here, and code review cannot undo them.

```
/grill-me          be interrogated until the requirement is actually pinned down
/da-investigate       what would this change touch, and what breaks — with file:line
/writing-plans     get a plan onto disk
/da-design-review     ← the plan, reviewed before anyone implements it
```

`/da-design-review` looks for what a later code review structurally cannot: **one-way doors** (what
becomes irreversible, and at which moment), migration order, whether every intermediate deploy state
works, and **what the plan does not mention at all** — rollback, existing data, in-flight requests,
the signal that says it worked. Absence is the hardest thing to review and the usual source of
production surprise.

`/da-investigate` answers under a fixed budget (25 files, 3 search rounds) and escalates cheapest-first:
ripgrep, then structural search, then LSP, and only then reading whole files. It reports confidence as
exactly **Confirmed / Inferred / Unconfirmed** — "probably" and "should be" collapse the distinction
that matters — and names what it did not check.

### 2 — While writing code

Work: `/executing-plans` for a written plan, `/systematic-debugging` for a bug — **test-first in either
case**, per `AGENTS.md`. Then `/da-verify` when you want the evidence rather than the assertion.

**The gate is the point, and `/da-verify` is what switches it on.** An agent stops when work *looks*
done; absent a check it can run, that is the only signal it has, and you become the verification loop.
`/da-verify` arms the gate as its first step, and from then on the end of every turn runs this
repository's own commands and refuses to finish while they are red.

So there is no separate arming step in the normal flow. The two cases where you touch it directly:

```bash
scripts/gate.sh arm       # hold from the FIRST turn, before any verify has run
scripts/gate.sh disarm    # back to question-answering; no suite on the way out
```

> **Do not treat this as an unattended-overnight lock.** Arming early raises the odds that a session you
> are not watching finishes green, and that is all. Three limits, none of which the gate can fix:
> **Claude Code releases a Stop hook after 8 consecutive blocks**, so a genuinely stuck run gets let
> through and finishes red. **On Cursor it cannot block at all** — it injects a follow-up message and
> stops doing even that at the third one, so the run can be walked past. And a hook that keeps refusing
> is not progress; if the same check fails twice the right move is to discard the session, which is the
> opposite of holding it open.
>
> For work that genuinely runs while you sleep, the durable parts are the ones that survive the session:
> the spec on disk, the checks in CI, and commits as recovery points. The gate is a guardrail inside one
> session, not a supervisor across many.

### 3 — After writing code

```
/da-review-all        the review entry point — every layer, plus the risks between them
/code-review          a second opinion, differently built (bundled)
/da-fix-plan          the findings, triaged into an ordered plan — decides what NOT to fix
/da-pr-describe       a PR description a reviewer can read before opening the diff
```

**One review entry, three layers of depth behind it.** `/da-review-all` classifies the change and
dispatches to `da-review-backend`, `da-review-frontend` and `da-review-infra` — full skills with their own
posture, process and perspective clusters, kept out of the `/` menu so there is one thing to type instead
of four. Naming a layer still reaches it directly: *"review the backend"* fires `da-review-backend`
without going through classification.

The dispatcher then does the part no layer can: a contract change and its consumer shipping out of order,
config read live at startup meeting code that has not deployed, a shared default whose correctness depends
on compensating work in a **different** layer, and — for agent-authored change — a boundary where both
sides were written together and agree with each other while being wrong about the outside world.

All four share one posture — *"clean" is a conclusion earned with evidence, not a default* — and one
finding discipline, so a layer review and a cross-layer review calibrate severity the same way.

**Run a second reviewer, and make it a different one.** Four AI reviewers over the same 146 pull requests
caught **93.4% of findings with exactly one of the four, and none with all four** — diversity of approach
beats quality of any single reviewer. That is why the bundled `/code-review` and Sentry's `/find-bugs` are
kept rather than suppressed even though this repository ships its own review machinery.

**Each review runs an adversarial pass** before it reports. Findings at the two highest severities go to
three `da-review-verifier` subagents with different lenses — is this reachable, is it already guarded
elsewhere, is the severity right — and two must fail to refute for the finding to survive. A verifier
that cannot substantiate a claim returns `refuted`, not `uncertain`, which is the opposite of the
default instinct and the reason the reports stay short.

The full "say this / when" table is [below](#everything-installed-and-when-to-say-it), including the
built-ins worth knowing: **`/review`** takes a GitHub PR, **`/code-review`** your working diff,
**`/security-review`** is security-only, and **`/simplify`** is quality only and explicitly not a bug
hunt. `/find-bugs` and `/da-review-all` both claim "review changes", so a bare "review this" may pick
either — naming it removes the coin flip.

### 4 — Periodically

```
/skill-doctor      which loaded skills are unused and costing context  (bundled)
/doctor            the listing's real context cost, and its biggest contributors  (bundled)
/da-skills-audit   over-constraint, overlapping triggers, Cursor incompatibility, size
/skill-scanner     security-scan a newly installed third-party skill before trusting it
```

**Run `/skill-doctor` before `/da-skills-audit`.** The audit reads files, and files are a minority of the
surface — see the count below. Neither of them measures whether a skill *helps*; that is
`anthropic-skills:skill-creator`, which runs paired with-skill / without-skill benchmarks and is already
installed.

### Two habits worth more than any of the above

**`/clear` between unrelated tasks.** A session carrying the last task's context makes worse decisions
about this one.

**When the same check fails twice, stop patching.** Write down what you tried, clear, and restart with
that folded in. Repeated correction accumulates failed approaches and each attempt gets worse. The
gate escalates its own message on the second failure for exactly this reason.

---

## What is in here

**Ten skills are written here**; the other seventeen are installed from upstream, because methodology is
better maintained by people who work on it full time. Ours are the ones that encode an opinion —
what counts as a finding worth reporting, what makes a review trustworthy, what must be true before
work is called done. They are marked **●** in the table below.

Plus two subagents in `agents/`, installed globally so they exist in every repository:
**`da-review-verifier`** (adversarial, refutes by default, never took part in finding) and
**`da-codebase-explorer`** (read-only tracing, `file:line` evidence, explicit budget). The review skills
dispatch to them by name. Before they existed, five files said "prefer a purpose-built agent when the
repository defines one" — and since this toolkit never adds a file to a product repository, that branch
could never be taken. See [ADR 0005](docs/adr/0005-mechanism-taxonomy-and-pruning.md).

## Everything installed, and when to say it

**Type `/da` and you have exactly this repository's set.** Everything shipped here is prefixed `da-`
(for dotagents) — ten skills and two subagents. That solves two problems at once: at the `/` menu
there is otherwise no way to tell ours from everything else, and an unprefixed name can shadow a built-in
silently, which already happened once when a skill called `review` hid Claude Code's own `/review`.

### How big the surface actually is

**78 names are reachable, not 27.** This matters because the budget they share is 1% of the context
window, and because two earlier audits of this repository were wrong by reading the filesystem:

| Source | Names | Where |
|---|---|---|
| On disk | 27 | `~/.agents/skills/` — 10 ours, 17 upstream |
| Anthropic-managed plugin | 11 | under `~/Library/Application Support/Claude/…`, server-synced |
| **Compiled into the CLI binary** | **40** | **no files exist** — they live inside the executable |

So a count from `~/.agents/skills` is not the total. `/doctor` and `/skill-doctor` see all of it.
Six names are suppressed via `skillOverrides` — see [Suppressed](#suppressed-and-why-not-more) below.

### The table

The development loop, in order. **●** marks ours; everything else is upstream or built in.

| Say this | When | |
|---|---|---|
| **1. Before you know what to build** | | |
| `/grill-me` | You have a rough idea and want it interrogated until the requirement is actually pinned down | |
| `/brainstorming` | Exploring intent and options before any creative work | |
| `/da-investigate` | "Where does X live", "what depends on this", "what would this change touch" — answered with `file:line` under a budget | ● |
| **2. Before you write code** | | |
| `/writing-plans` | You have a spec and want a plan on disk before touching code | |
| `/da-design-review` | A plan or design doc is ready. Catches what code review cannot fix later — one-way doors, migration order, rollback | ● |
| `/executing-plans` | You have a written plan and want it executed with review checkpoints | |
| `/using-git-worktrees` | The work needs isolation from your current workspace | |
| **3. While writing code** | | |
| `/test-driven-development` | Implementing any feature or bugfix, before the implementation | |
| `/systematic-debugging` | A bug, a test failure, or behaviour you cannot explain — before proposing a fix | |
| `/da-verify` | You want evidence rather than an assertion. Runs *this repository's* configured checks, and **arms the Stop gate** | ● |
| `/verification-before-completion` | About to claim something is done, in a repository with no profile for `/da-verify` | |
| `/resolving-merge-conflicts` | A merge or rebase conflict is in progress | |
| `/verify` | Drive the change end-to-end as a user would, not just tests and typecheck (bundled) | |
| `/run` | Start the app and look at it (bundled) | |
| **4. After writing code — review is an escalation, not a ritual** | | |
| `/da-review-all` | **The review entry point.** Classifies the change, dispatches to the layers that apply, then finds what falls *between* them | ● |
| `/code-review` | **Your second reviewer.** Differently built, so it finds different things (bundled) | |
| `/find-bugs` | A third: enumerates the attack surface first, then sweeps the branch diff | |
| `/simplify` | Quality only — reuse, simplification, altitude. Explicitly *not* a bug hunt (bundled) | |
| `/security-review` | Security specifically, over the pending branch changes (bundled) | |
| `/review` | A GitHub pull request rather than your working diff (bundled) | |
| `/requesting-code-review` | You want the *procedure* — a reviewer in a fresh context that never saw your reasoning | |
| `/receiving-code-review` | Feedback arrived and you want to evaluate it rather than implement it reflexively | |
| `/da-fix-plan` | More findings than you want to act on. **Decides what not to fix**, orders the rest by irreversibility, writes the plan to disk | ● |
| `/da-pr-describe` | The PR needs a description a reviewer can read before opening the diff. **Type it — it never fires on its own** | ● |
| `/finishing-a-development-branch` | Implementation is done and you need to decide how to integrate | |
| `/handoff` | Compact this conversation so another agent can pick it up | |
| **5. Periodically** | | |
| `/skill-doctor` | Which loaded skills are unused and costing context. **Run this first** (bundled) | |
| `/doctor` | The listing's real context cost and its biggest contributors (bundled) | |
| `/da-skills-audit` | Over-constraint, overlapping triggers, Cursor incompatibility, size | ● |
| `/skill-scanner` | Before trusting a newly installed third-party skill. Security, not bloat | |
| `anthropic-skills:skill-creator` | Whether a skill *helps*: with-skill versus without-skill pass rate, tokens, time | |

**`da-review-backend` / `-frontend` / `-infra` are deliberately absent from this table** — they carry
`user-invocable: false`, so `/da-review-all` reaches them and so does naming a layer ("review the
backend"), but they are not in the `/` menu. One thing to type, three layers of depth behind it.

### Where triggers still overlap, and who wins

| Ask | Goes to | Second opinion |
|---|---|---|
| "review this" | `/da-review-all` — or `/find-bugs`; a bare phrasing may pick either | `/code-review` |
| "is this secure" | `/find-bugs` (bugs + security + quality) | `/security-review` |
| "am I done" | `/da-verify` if the repo has a profile | `/verification-before-completion` where it does not |
| "clean this up" | `/simplify` — quality only, by design | — |
| "run it every day" | bundled `/schedule` | `/loop` for a single repeating check |

### Suppressed, and why not more

Six names are set to `name-only` or `off` in `skillOverrides`, merged by `setup.sh` and reverted exactly
by `uninstall`: `verification-before-completion` and `claude-api` (both auto-fire on triggers this
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

### Where the upstream sixteen come from

Chosen from collections that are widely used and actively maintained, and **installed selectively** —
never a whole repository, because every description shares one budget. Only what a flow above actually
reaches.

| Source | Installed from it | Why this collection |
|---|---|---|
| **[obra/superpowers](https://github.com/obra/superpowers)** — 10 | `brainstorming` · `writing-plans` · `executing-plans` · `test-driven-development` · `systematic-debugging` · `verification-before-completion` · `requesting-code-review` · `receiving-code-review` · `using-git-worktrees` · `finishing-a-development-branch` | The methodology backbone: plan → implement → verify, plus the debugging discipline. Multi-harness, `AGENTS.md` and tests of its own. This is where the *process* comes from |
| **[mattpocock/skills](https://github.com/mattpocock/skills)** — 3 | `grill-me` · `handoff` · `resolving-merge-conflicts` | Sharp, single-purpose tools. `grill-me` is the interrogation that starts the design flow; `handoff` compacts a session for the next one. Both cost zero budget (`disable-model-invocation`) |
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
| From `~/.agents/skills` | 27, **minus the 3 layer reviews** hidden by `user-invocable: false` | **all 27** — Cursor ignores that field, so the layer reviews appear in its menu |
| Built-in | ~40 compiled into the CLI | **19 of its own**: `review`, `review-bugbot`, `review-security`, `create-skill`, `create-rule`, `create-subagent`, `loop`, `automate`, `babysit`, `split-to-prs`, `onboard`, `shell`, `sdk`, `canvas`, `statusline`, `migrate-to-skills`, `create-hook`, `update-cli-config`, `update-cursor-settings` |
| `skillOverrides` suppressions | 9 active | **0** — Cursor does not read `settings.json` |

Two consequences worth being blunt about:

**The layer reviews leak into Cursor's menu.** In Claude Code there is one review entry to type; in
Cursor there are four of ours plus `review`, `review-bugbot`, `review-security` and `find-bugs`. Typing a
layer directly in Cursor still works correctly — it is the same skill — so this costs menu clarity, not
behaviour, which is the line [ADR 0003](docs/adr/0003-cursor-compatible-subset.md) draws. It is
nonetheless the largest remaining divergence, and it is **not fixed**.

**The 9 suppressions do not apply there, and mostly do not need to.** Six of the nine target skills that
do not exist in Cursor at all — bundled and Anthropic-plugin ones — so there is nothing to suppress.
`verification-before-completion` is the one that does exist in Cursor and stays un-suppressed there, so
its trigger still competes with `/da-verify` on that side.

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
  -s brainstorming -s writing-plans -s executing-plans -s verification-before-completion \
  -s requesting-code-review -s receiving-code-review -s systematic-debugging \
  -s test-driven-development -s using-git-worktrees -s finishing-a-development-branch

# practice — mattpocock/skills
npx skills add mattpocock/skills -g -a claude-code -a cursor \
  -s grill-me -s handoff -s resolving-merge-conflicts -s research

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
from 6,905 to 3,559 characters. Every by-name reference was checked first — the reason `brainstorming`
and `using-git-worktrees` stayed is that other kept skills dispatch to them.

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
