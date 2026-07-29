# The loop

日本語: [workflow.ja.md](workflow.ja.md)

What to type, when, and why — for the case where most of the code is written by an agent.

This uses the official vocabulary rather than one invented here, because a private vocabulary makes the
official guidance harder to apply later. Sources at the bottom, marked **official** / **opinion** /
**research**, and the places where good sources disagree are called out rather than smoothed over.

---

## The phases, and what "review" actually is

Official guidance gives two loops at different altitudes and does not reconcile them, so both are worth
knowing:

- **Mechanically**, every turn is *gather context → take action → verify results*, and the phases blend.
- **As a workflow**, it is four phases: **Explore → Plan → Implement → Commit.**

Two absences in that list are deliberate and worth internalising:

**"Verify" is not a phase.** It is a property every phase needs — the first thing the official
best-practices document discusses, before any of the four. The reason: *an agent stops when the work
looks done, and absent a check it can run, "looks done" is the only signal available — so you become the
verification loop.*

**"Review" is not a phase either.** Officially it is an *escalation*, for work you were not watching.
This repository ships a lot of review machinery, and it is still an escalation: reach for it when the
change is risky or you were not present, not as a ritual after every diff.

---

## Phase 0 — decide whether to plan at all

> **If you could describe the diff in one sentence, skip the plan.** *(official)*

Planning is most useful when the approach is uncertain, the change spans several files, or the code is
unfamiliar. For a typo, a log line, or a rename it is pure overhead. This is the cheapest decision in the
loop and the easiest to get wrong in the expensive direction.

## Phase 1 — Explore

| Type | For |
|---|---|
| `/grill-me` | You have a rough idea and want it interrogated until the requirement is pinned down |
| `/da-investigate` | "Where does X live", "what depends on this", "what would this touch" — answered with `file:line` under a fixed budget, naming what it could not confirm |

The point of this phase is to *narrow* before context fills. The named failure here is **infinite
exploration** — reading to feel thorough. `da-investigate` exists with a budget for exactly that reason,
and it fans out to `da-codebase-explorer` subagents so the reading stays in their context, not yours.

## Phase 2 — Plan, and write it to disk

| Type | For |
|---|---|
| `/writing-plans` | Turn a settled requirement into a plan on disk |
| `/da-design-review` | Review that plan before any code exists |

**Write the spec to a file.** Not because prose is magic, but because a file survives `/clear` and
survives compaction, and it becomes the criterion the reviewer is measured against later. The official
properties of a useful spec are checkable:

1. **Names the files and interfaces involved**
2. **States what is out of scope**
3. **Ends with an end-to-end verification step that proves the feature works**

> *"Time spent making the spec precise pays off more than time spent watching the implementation."*
> *(official)*

`/da-design-review` is worth its cost here and nowhere else in the loop: one-way doors, migration
ordering and rollback are decided at plan stage and are a rewrite afterwards. It runs a past-tense
**pre-mortem** — "it is six months from now and this failed, write the incident review" — because
imagining a failure as *already having happened* identifies roughly 30% more causes than asking what
could go wrong *(research)*.

### Then clear, and implement in a fresh session

> *"Once the spec is complete, start a fresh session to execute it."* *(official)*

The plan is now on disk. Carrying the planning conversation into implementation costs context and buys
nothing.

## Phase 3 — Implement

| Type | For |
|---|---|
| `/executing-plans` | Work through a written plan with review checkpoints |
| `/test-driven-development` | Any feature or bugfix, before the implementation |
| `/systematic-debugging` | A bug, a test failure, or behaviour you cannot explain — *before* proposing a fix |
| `/using-git-worktrees` | The work needs isolating from the current workspace |

## Phase 4 — Verify

| Type | For |
|---|---|
| `/da-verify` | Run *this repository's* configured checks and report with evidence |
| `/verify` (bundled) | Drive the change end-to-end as a user would, not just tests and typecheck |
| `/run` (bundled) | Start the app and look at it |

**`/da-verify` is also what arms the Stop gate, and the only thing that does.** A session where it never
ran is a session with no gate. That is why its automatic invocation matters as much as typing it, and why
it must never carry `disable-model-invocation`.

The official ladder, weakest to strongest — *each step trades setup for attention*:

| Mechanism | Strength |
|---|---|
| "run the tests after implementing" in the prompt | works today, on anything |
| a `/goal` condition re-checked every turn | gates across a session |
| **a Stop hook** that refuses to end the turn | deterministic — **but overridden after 8 consecutive blocks** |
| a verification subagent that tries to refute the result | the work is not graded by whoever did it |

What counts as verification is anything returning a signal the agent can read: a test suite, an exit
code, a linter, a diff against a fixture, a screenshot. What does not count is an assertion that it
worked. **Show the output.** Reading evidence is cheaper than re-running the check yourself, and it works
for sessions you were not watching.

## Phase 5 — Review, as an escalation

| Type | For |
|---|---|
| `/da-review-all` | The tech-lead pass: classifies the change, runs the layer reviews that apply, then finds the risks that fall *between* layers |
| `/code-review` (bundled) | A second opinion, differently built |
| `/find-bugs` | A third: enumerates the attack surface first, then sweeps |
| `/simplify` (bundled) | Quality only — reuse, simplification, altitude. Explicitly not a bug hunt |
| `/requesting-code-review` | You want the *procedure* rather than a report |
| `/receiving-code-review` | Feedback arrived and you want to evaluate it rather than implement it reflexively |

**Run two reviewers, and make them different ones.** Four AI reviewers over the same 146 pull requests
caught **93.4% of findings with exactly one of the four, and none with all four** *(opinion, with data)*.
Diversity of approach beats quality of a single reviewer, which is why the bundled reviewers are kept
rather than suppressed even though this repository ships its own.

Two constraints on what to do with the output, both official:

> *A reviewer prompted to find gaps **will usually report some, even when the work is sound**, because
> that is what it was asked to do. **Chasing every finding leads to over-engineering:** extra
> abstraction layers, defensive code, and tests for cases that can't happen.*

So: **a finding outside the spec is optional, not work.** And **never block on a personal style
preference** — anything that is a preference opens with `Nit:`, so the author can tell which of eleven
comments actually matter.

The reviewers this repository ships apply a refutation pass before reporting, and for the two highest
severities a three-lens pass. That is not three independent opinions — it is one model checked three
ways, and `_shared/finding-discipline.md` explains why the distinction matters.

## Phase 6 — Commit

| Type | For |
|---|---|
| `/da-pr-describe` | A PR description a reviewer can read before opening the diff. **Type it** — it never fires on its own, because it writes to GitHub and the timing is yours |
| `/finishing-a-development-branch` | Implementation is done and the integration route needs deciding |
| `/commit`, `/pr`, `/commit-push-pr` (bundled) | The mechanical steps |

---

## The abort conditions

Success conditions are easy to remember. These are the ones that get skipped.

**Two failed corrections, then stop.** *(official)*

> *If you've corrected Claude more than twice on the same issue in one session, the context is cluttered
> with failed approaches. Run `/clear` and start fresh with a more specific prompt that incorporates what
> you learned. **A clean session with a better prompt almost always outperforms a long session with
> accumulated corrections.***

The mechanism is well supported — attention degrades as context grows, and models do not reliably
self-correct from their own feedback without external evidence *(research)*. **The number two is not
measured**; treat it as a good default rather than a finding.

**`/clear` between unrelated tasks.** The named failure is the *kitchen sink session*. But note the
official caveat: sometimes you *should* let context accumulate, because you are deep in one problem and
the history is the valuable part.

**Externalise before clearing.** `/clear` is only cheap if the state that mattered is already on disk —
invariants in `AGENTS.md`, the plan in a file, checkpoints in git. Compaction preserves your requests and
key snippets but **may drop detailed instructions from early in the conversation**, which is the reason
standing rules belong in `AGENTS.md` and not in a message you sent an hour ago.

**When the toolkit makes you a dispatcher, it has stopped paying.** *(opinion, and the sharpest thing
anyone has said about this)* If you find yourself managing which agent is doing what rather than doing
the work, the setup has become the project. There is no metric for this. Notice it anyway.

---

## Periodically

| Type | For |
|---|---|
| `/skill-doctor` | Which loaded skills are unused and costing context. **Run this before `/da-skills-audit`** — it answers what a file-level audit cannot |
| `/doctor` | The listing's real context cost and its biggest contributors |
| `/da-skills-audit` | Static: over-constraint, overlapping triggers, Cursor incompatibility, size |
| `/skill-scanner` | Security-scan a third-party skill before trusting it |
| `anthropic-skills:skill-creator` | The actual eval: with-skill versus without-skill pass rate, tokens, time |

**Growth has to be paid for by pruning.** Every installed description shares a listing budget of 1% of
the context window; on overflow, descriptions are shortened and then dropped **starting with the skills
you invoke least**, which strips the keywords the model needs to match a request. So an unused skill does
not merely sit there — it degrades the discovery of the ones you use, silently. "Too many" is not a
number, it is `/doctor` reporting the listing over budget.

---

## What is *not* settled

Stated because a workflow document that only asserts is not useful.

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
