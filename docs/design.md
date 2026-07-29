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

**After writing code**, `/da-review-backend`, `/da-review-frontend`, and `/da-review-infra` each review one
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
judgement rather than evidence: `da-verify` against `verification-before-completion`, `da-review-backend`
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
