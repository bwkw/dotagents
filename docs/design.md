# Design

Why this toolkit has the shape it has, what it is for, and how it is meant to be used.

The ADRs in this directory cover individual mechanisms. This document covers the reasoning above
them: what problem is being solved, what was deliberately left out, and where the design is
uncertain. For the narrower question of *which* mechanism a given thing should be — skill, hook,
subagent, MCP server, always-loaded context — see [`mechanisms.md`](mechanisms.md), which records the
official guidance with sources and the two places this toolkit deviates from it.

---

## The problem

Two agents, several repositories, one person. Left alone, that produces the same three failures
regardless of how good the models get.

**Assets scatter and drift.** A prompt written for Claude Code is invisible to Cursor. The obvious
fix — copy it — means two files that agree today and disagree in a month, with nothing reporting the
divergence. Duplication is not a maintenance cost; it is a correctness cost, because you stop being
able to say which copy is authoritative.

**The human becomes the verification loop.** An agent stops when work *looks* done. Absent a check it
can run and a rule about what counts as finished, "looks done" is the only available signal — so the
person reviews everything, every time, and the leverage evaporates.

**Reviews decay into noise.** An agent asked to find problems will find some. Follow all of them and
you get defensive code, speculative abstraction, and tests for states that cannot occur. Two reports
like that and nobody reads the third.

None of these are model problems. Better models make each *worse*, because more output flows through
the same unguarded channels.

## What this is not

Worth stating, because the boundary is what keeps the toolkit small:

- **Not a replacement for upstream skill collections.** Methodology and general practice are better
  maintained by people who work on them full time. This installs from them and writes only the delta.
- **Not a per-repository framework.** It never adds a file to a product repository. That is a hard
  constraint, not a preference — see below.
- **Not a prompt library.** A prompt you paste is a prompt you forget to update. Everything here is
  either invoked by name or loaded automatically.
- **Not portable to arbitrary agents.** Two targets, Claude Code and Cursor, both first class. A
  third would change several decisions.

---

## Three layers, and why the line falls where it does

```
adopt      upstream skills, installed with npx skills, never vendored
own        this repository — only what upstream does not cover
absorb     profiles/ — per-repository facts, gitignored, never in a product repo
```

**The adopt/own line** is drawn at *specificity*. Anything a competent engineer at another company
would also want — how to write a plan, how to debug systematically, how to run TDD — belongs
upstream. It is better maintained there and improves without effort here. What stays is what encodes
a particular opinion: what counts as a finding worth reporting, what makes a review trustworthy, what
must be true before work is called done.

The test when considering a new skill: *would this be equally useful to someone with different
opinions?* If yes, it belongs upstream or nowhere.

**The own/absorb line** is drawn at *what would be embarrassing to publish*. Verification commands
name real repositories, real environments, sometimes an employer's internal rules. That is
configuration, not toolkit. It stays on the machine that wrote it, and `.gitignore` is an allowlist so
a new profile is untracked by default rather than tracked until someone remembers to exclude it.

This also makes the toolkit outlast any particular job.

## The constraint that shaped everything: product repositories stay untouched

Every alternative design starts by adding files to the repositories you work in — a `.claude/`
directory, a config file, a committed profile. That is how the tools this replaced worked, and how
they drifted.

Refusing it forces three consequences, all of which turned out to be improvements:

- **Global installation only.** One physical copy, symlinked into both agents. Editing a file here
  takes effect immediately in both, with no sync step and nothing to diverge.
- **Repository facts live in `profiles/`**, resolved by git remote at run time rather than by a file
  in the repository.
- **No coordination cost.** Nothing to get reviewed, nothing to keep in step with a team's
  conventions, nothing to remove when leaving.

The cost is real: project-scoped skills are out of reach by construction, and a repository cannot
carry its own verification config. Both are accepted. A personal toolkit that needs per-repository
installation is a per-repository change.

---

## Whose practices this is built from

Almost nothing here is original, and the parts that are should be visible as such. What was taken, and —
more usefully — **what was rejected and why**.

### The structural patterns every skill follows

Not decoration — each of these was added because its absence had already cost something:

| Pattern | What it prevents |
|---|---|
| An **immediate-stop preconditions table** at the head of every skill | A skill running against a repository it cannot actually work in, and reporting a result anyway |
| **"Always read"** split from **"read only if"**, with *"read everything just in case" explicitly forbidden* | The skill spending its budget on files irrelevant to this invocation |
| A **workflow-position table** naming each skill's own upstream and downstream | Skills that work individually and connect to nothing |
| A bold **read-only declaration** on anything that investigates or reviews | A review that edits the code it was reviewing |
| **Fact / inference / could-not-confirm** kept separate | An inference being read as a finding |
| A **frontmatter lint hook** | A broken `SKILL.md` landing and failing silently later |
| `_template/`, whose `_` prefix keeps it out of install | The template being installed as a skill |

### Official Anthropic guidance

The loop vocabulary, the verification ladder, the context-management rules, and the taxonomy of
mechanisms are all official rather than invented. [`mechanisms.md`](mechanisms.md) and the Sources
section below carry the sources per claim. Two official lines shaped more of this than anything else:

> *Put guardrails in hooks. An instruction like "never edit `.env`" in CLAUDE.md or a skill is a request,
> not a guarantee.*

> *A reviewer prompted to find gaps will usually report some, even when the work is sound… Chasing every
> finding leads to over-engineering.*

The first is why the verification gate is a hook and not a rule. The second is why the reporting
discipline is aggressive and why `/da-fix-plan` exists to subtract.

### Practitioners, and where they disagree with the docs

Named because their disagreements are more useful than their agreements, and because a toolkit that only
cites official guidance will inherit its blind spots:

- **Birgitta Böckeler / Thoughtworks** — the *guides versus sensors* framing, and the argument that this
  field has over-invested in instructions given up front and under-invested in tools that observe what was
  actually produced. That is the case for the gate, the linter and the tests over more prose. Also hers:
  reviewing code occasionally **to check your instrumentation has not drifted** rather than to catch bugs.
- **Simon Willison** — verification over reading: *"if the code has never been executed it's pure luck if
  it actually works"*, and **fix the process that generates the code rather than hand-fixing the code**.
- **Addy Osmani** — *stop reviewing everything to the same depth*, and the measurement that four reviewers
  over 146 pull requests caught **93.4% of findings with exactly one of the four**. That single number is
  why the bundled reviewers are kept rather than suppressed.
- **Armin Ronacher** — the *outer harness loop* framing (this toolkit **is** the outer loop), and *Agent
  Psychosis* as the warning: a toolkit that becomes the project.
- **Kent Beck** — *"multi-agent is a feature; outcome-orientation is the thing the feature is supposed to
  deliver"*, and the failure signal: **the day the setup makes you a dispatcher, it has stopped paying.**

### What was investigated and rejected

Rejections belong in the record as much as adoptions, because otherwise they get re-proposed:

| Considered | Outcome |
|---|---|
| **Milvus × Ollama vector index + `claude-context` MCP** for cross-repository search | **Rejected** — indexes per absolute path, so a symlink virtual monorepo double-indexes and goes stale; requires a resident docker stack; and Claude Code itself moved from RAG to agentic search citing staleness. [ADR 0007](adr/0007-cross-repository-search-stays-agentic.md) |
| **`codegraph`** | **Unevaluated, honestly.** Not rejected. ADR 0007 sets the bar it has to clear. |
| Plugin/marketplace packaging | Deferred — namespacing breaks by-name dispatch. ADR 0001, revisited in 0003 |
| `disableBundledSkills` | Rejected — too blunt, and version-dependent. ADR 0006 |
| Migrating existing product-repository assets | Out of scope by design. This is a personal toolkit, not a migration |

## Where constraint earns its keep, and where it does not

Current guidance for this generation of models is to constrain less and let judgement work — Claude
Code removed most of its own system prompt with no measurable loss. That is the right default, and
most of this toolkit follows it: skills are thin guides, detail loads on demand, and the layer bodies
are read only by the subagent that needs them.

Two places deliberately go the other way, and the reasoning should be legible so they can be revisited:

**Reporting discipline is constrained on purpose.** The failure mode is specific: an agent asked to
find gaps produces plausible findings, and the ones that are merely plausible are indistinguishable
from the ones that matter until someone spends the effort to tell them apart. Numeric confidence with
a discard threshold, and a written definition of what counts as a false positive, exist because this
is not a judgement call the model gets to make freshly each time — it is an opinion about how much
noise is acceptable, and opinions are exactly what a skill should encode. The threshold is aggressive
on purpose: a missed finding costs one bug, while a noisy report costs the habit.

**Verification is constrained mechanically.** Not because the model would decide badly, but because
"I ran the tests" is a claim, and a claim is not evidence. A hook that runs the command is not a
guardrail against poor judgement; it removes the need to trust a report at all.

Everywhere else, constraint should be suspected. Fixed budgets, mandatory section structures, and
exact output skeletons are load-bearing only where they prevent a specific, named failure. Where they
are merely tidy, they cost judgement and should go. `/doctor` exists to find these; this repository
is not exempt.

## The two boundaries that produce silent failure

Most of the mechanism here defends two seams where things break without saying so.

**Claude Code and Cursor read different subsets of the same file.** Cursor understands four
frontmatter fields and silently ignores the rest, so a constraint written in `allowed-tools` is
simply absent there, with nothing reporting it. Hence the rule: strip every Claude-only field and the
skill must still behave the same. Constraints go in the body as prose; frontmatter is optimisation on
top. The linter enforces this because prose conventions decay and machine checks do not.

**A guardrail can fail open.** A dangling hook symlink exits 127, which is treated as non-blocking —
so the broken guardrail does not stop the agent, it stops guarding. This has already happened twice
here in different disguises, which is why hooks are copied rather than linked, why the gate blocks on
its own internal error rather than passing, and why the gate is the one component with a real test
suite.

Both seams share a property that drove the whole design: **the failure is invisible from inside.**
Nothing is logged, nothing errors, and the tool appears to work. That is what the checks are for.

---

## How it is meant to be used

There is no pipeline. Each skill is invoked by name, and most sessions use one or two.

**Before writing code**, when the shape is not obvious: `/grill-me` to be interrogated until the
requirement is actually pinned down, `/da-investigate` when you need to know what a change would touch,
`/writing-plans` to get a plan on disk. Then `/da-design-review` on that plan — it catches what code
review cannot fix later, because by the time a diff exists the migration strategy and the contract
shape are already decided.

**While writing code**, the upstream skills do the work. `/da-verify` when you want the evidence rather
than the assertion — **and it is `/da-verify` that arms the gate, the only thing that does.** Once armed,
the gate will not let a turn end with checks red. A session where `/da-verify` never ran is a session with
no gate, which is why the skill's auto-invocation matters as much as typing it.

**After writing code**, `/x-review-backend`, `/x-review-frontend`, and `/x-review-infra` each review one
layer as a tech lead, and `/da-review-all` classifies the change and runs the ones that apply before
looking specifically for the cross-layer risks — a contract change and its consumer shipping out of
order, a config read live at startup meeting code that has not deployed yet. Then `/da-pr-describe`.

The layer skills are the same skills whether you invoke them or the dispatcher does; see ADR 0004 for
why they are skills rather than reference files the dispatcher hands to a subagent.

**Periodically**, `/da-skills-audit`. The toolkit's own failure mode is accumulation: every installed
description is resident in context permanently, so each new skill costs the selection accuracy of
every existing one. Growth has to be paid for by pruning.

Two habits matter more than any of the above. **`/clear` between unrelated tasks** — a session
carrying a previous task's context makes worse decisions about this one. And **when the same check
fails twice, stop patching**: write down what was tried, clear, and restart with that folded in.
Repeated correction accumulates failed approaches and each attempt gets worse. The gate escalates its
own message at the second failure for this reason.

## The largest known gap: the skills are still unmeasured — but not unmeasurable

Every claim in this repository about a skill improving anything is an opinion, and that is worth stating
plainly because the rest of the design is built on refusing exactly that kind of unbacked claim.

**An earlier version of this section said no way to measure existed. That was wrong**, and the error is
instructive: the tools were installed and invisible, in the same way the skill inventory was wrong for
the same reason. What exists today:

| Tool | Answers |
|---|---|
| **`anthropic-skills:skill-creator`** | The real eval. Paired with-skill / without-skill runs on the same prompt, aggregating pass rate, time and tokens into `benchmark.json`, plus trigger accuracy from should-fire / should-not-fire prompts. **Installed.** |
| **`/skill-doctor`** | Which loaded skills are unused and costing context. **Bundled.** |
| **`/doctor`** | The listing's actual context cost and its biggest contributors. **Bundled.** |
| `/da-skills-audit` | Static: over-constraint, overlapping triggers, Cursor incompatibility, size. Not an eval, and now says so. |

So the gap is no longer "no instrument". It is that **none of it has been run yet**, which is a smaller
and more embarrassing gap. The first things worth measuring are the calls this repository made on
judgement rather than evidence: `da-verify` against `verification-before-completion`, `x-review-backend`
against `find-bugs`, `da-review-all` against the bundled `code-review`.

One caveat that makes the results worth less than they look: a skill benchmarked in the session that
authored it will score better than it is, because leftover context masks gaps in the written
instructions. Benchmark from a fresh session or do not believe the number.

Two smaller gaps in the same family:

- **No cost observability.** OpenTelemetry is configured for skill-activation events but nothing
  tracks tokens or spend. If the advisor or parallel subagents get used more heavily, there is no way
  to tell "this is working" from "this is expensive".
- **Skill supply-chain review is separate from what `/da-skills-audit` does.** That audit reads for
  over-constraint; `/skill-scanner` reads for prompt injection. Neither reviews an MCP server or a
  plugin before it is installed.

## What is uncertain

Stated plainly, because a design document that only justifies is not useful:

- **Whether Cursor double-lists skills** reachable from both `~/.agents/skills/` and
  `~/.cursor/skills/`. The upstream CLI stopped creating the latter, which suggests it is redundant;
  this still creates it, because a silent absence is worse than a duplicate menu entry. Unverified.
  See ADR 0001.
- **Whether the reporting constraints are still earning their keep** as models improve. The
  thresholds are numbers someone chose, not measurements. They should be tested against real reviews
  rather than defended.
- **Whether `profiles/` should be a schema and nothing else.** The example may narrow how people
  write profiles more than it helps them start.
- **Whether the mandatory section structure in skills is signal or ritual.** It makes skills
  scannable and gives the linter something to check; it may also be overhead that a capable model
  does not need.

### And what is not settled about the loop itself

- **There is no canonical five-phase loop.** Official is three (mechanical) or four (workflow), with
  review as an escalation. Practitioners disagree meaningfully: one framing is nested loops with a
  *harness* deciding whether a session's ending was really an ending; another rejects phases entirely in
  favour of *guides* (given up front) versus *sensors* (observing what was produced), arguing the field
  has over-invested in guides. The five-phase shape is a convenience, not a finding.
- **Where the human belongs is contested.** Official guidance puts them inside the loop — approve the
  plan, read the evidence. A strong practitioner argument says line-by-line review becomes
  counterproductive once agents outpace human reading, and proposes intervening only on threshold
  violations plus periodic deep dives *to check the instrumentation has not drifted*. That second idea is
  the good one: you read code occasionally not to catch bugs but to confirm your sensors still work.
- **Productivity numbers for agentic coding are not trustworthy.** The most careful measurement attempt
  abandoned its own design, reporting −18% (CI −38% to +9%) for experienced developers and calling its
  own data *very weak evidence*. Anyone quoting a clean figure is not reading the source.
- **Plan-to-disk has no measured effect size.** The mechanism is clear and the practice is officially
  recommended; the widely repeated "3–10× first-pass success" figure traces to a vendor blog citing
  unnamed reports. Do not repeat it.

---

## Sources

**Official (Anthropic)** — [Best practices](https://code.claude.com/docs/en/best-practices) ·
[How Claude Code works](https://code.claude.com/docs/en/how-claude-code-works) ·
[Skills](https://code.claude.com/docs/en/skills) ·
[Run agents in parallel](https://code.claude.com/docs/en/agents) ·
[Code Review](https://code.claude.com/docs/en/code-review) ·
[Effective context engineering](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents) ·
[Effective harnesses for long-running agents](https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents) ·
[When to use multi-agent systems](https://claude.com/blog/building-multi-agent-systems-when-and-how-to-use-them) ·
[Building verification loops](https://claude.com/blog/building-verification-loops-in-claude-code-with-skills)

**Opinion** — [Ronacher, The Coming Loop](https://lucumr.pocoo.org/2026/6/23/the-coming-loop/) ·
[Ronacher, Agent Psychosis](https://lucumr.pocoo.org/2026/1/18/agent-psychosis/) ·
[Böckeler, AI coding sensors](https://www.thoughtworks.com/en-de/insights/blog/generative-ai/harness-engineering-agent-feedback-exploring-ai-coding-sensors) ·
[Böckeler, human-on-the-loop](https://www.thoughtworks.com/en-de/insights/blog/generative-ai/cybernetics-and-human-on-the-loop-in-agentic-coding) ·
[Willison, Agentic Engineering Patterns](https://simonw.substack.com/p/agentic-engineering-patterns) ·
[Osmani, Agentic Code Review](https://addyosmani.com/blog/agentic-code-review/) ·
[Beck, Genie Lessons](https://newsletter.kentbeck.com/p/genie-lessons-nobody-wants-agents) ·
[Cognition, Don't Build Multi-Agents](https://cognition.com/blog/dont-build-multi-agents)

**Research** — [METR, changing the experiment design](https://metr.org/blog/2026-02-24-uplift-update/) ·
[Huang et al., LLMs Cannot Self-Correct Reasoning Yet](https://arxiv.org/abs/2310.01798) ·
[Cross-Context Review](https://arxiv.org/pdf/2603.12123) ·
[Klein, Performing a Project Premortem](https://www.researchgate.net/publication/3229642_Performing_a_Project_Premortem) ·
[Are LLM Evaluators Really Narcissists?](https://arxiv.org/pdf/2601.22548)
