---
name: da-skills-audit
description: Audit the whole set of installed skills for bloat and breakage. Use before adding a skill, when skills stop firing automatically, or for periodic clean-up. Not a security scan.
argument-hint: "[path] (default: ~/.agents/skills)"
allowed-tools: Bash, Read, Grep, Glob
metadata:
  source: bwkw/dotagents
---

# /da-skills-audit — keep the toolkit from rotting

Skills degrade in a specific way: they accumulate. Every installed skill's `description` is resident
in context at all times, so the more there are, the less of each one survives — and the model picks
by matching a request against exactly those descriptions. A toolkit that grows without pruning stops
selecting correctly, and nothing announces it.

**This skill never modifies anything.** It reports, and proposes. Removals are yours to approve.

**This skill reads files. It does not measure usage, and it is not an eval.** Four tools, and you want
more than one:

| Tool | Reads | Answers |
|---|---|---|
| **`/skill-doctor`** | the loaded set, with usage | **which loaded skills are unused and costing context.** Run this *first* — it answers what this skill cannot. |
| **`/doctor`** | settings and the listing | the listing's real context cost and its biggest contributors; slow hooks; duplicated instructions |
| this skill | the files on disk | over-constraint, overlapping triggers, Cursor incompatibility, oversized bodies, the `AGENTS.md` invariants |
| **`anthropic-skills:skill-creator`** | with-skill versus without-skill runs | **whether a skill actually helps.** Aggregates pass rate, time and tokens into `benchmark.json`; measures trigger accuracy with should-fire / should-not-fire prompts. |

Open the report by naming which of the four were run. **A clean file-level audit says nothing about
whether the skills help** — that needs the last row, and it is already installed.

Two things to know before trusting any result:

- **The listing is far larger than this repository.** Around 40 skills are compiled into the Claude Code
  binary and never appear on disk; an Anthropic-managed plugin adds roughly 11 more. A filesystem audit
  therefore sees a fraction of what the model sees — the exact mistake this table exists to prevent.
  `/skill-doctor` and `/doctor` see the whole set; **do not present a count from disk as the total.**
- **A skill benchmarked in the session that wrote it will look better than it is.** Leftover context
  masks gaps in the written instructions. Benchmark from a fresh session.

## Preconditions

| Condition | If unmet |
|---|---|
| `~/.agents/skills` exists, or a path was given | Stop and report it |
| The dotagents checkout is locatable (`~/.claude/.dotagents-managed.json` → `repo`) | Continue, but skip the checks that need `verify-skills.sh` and say so |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| about to add a skill, or a quarterly clean-up | `/da-skills-audit` | consolidate, rewrite descriptions, or uninstall |

## Files to read

### Always read

| File | Why |
|---|---|
| every `SKILL.md` frontmatter under the audit path | names, descriptions, sizes, frontmatter keys |

### Read only if

| File | Trigger condition |
|---|---|
| a skill's body | Only when the static checks flag it and you need to judge overlap |

> Do not read every skill body. That is the exact failure this skill is meant to detect, and doing it
> here would cost more context than the audit saves.

---

## Step 0. Separate ours from theirs

```bash
grep -l 'source: bwkw/dotagents' ~/.agents/skills/*/SKILL.md
```

Everything else was installed from a third party. The distinction changes what you may propose:

- **Ours** — anything is on the table. Rewrite the description, split the body, delete it.
- **Theirs** — the only levers are install or uninstall. Do not propose editing an upstream skill;
  the edit is lost on the next `npx skills update`, and silently. If an upstream skill is the
  problem, say so and propose removing it or raising it upstream.

State the counts before going further. A budget report that does not say which half is yours cannot
be acted on.

## Step 1. Static checks

Run the linter over the audit path — it already implements the mechanical checks:

```bash
"$(node -e 'console.log(require(process.env.HOME+"/.claude/.dotagents-managed.json").repo)')/scripts/verify-skills.sh" ~/.agents/skills
```

It reports: missing `name` or `description`; `name` disagreeing with the directory; oversized
`SKILL.md`; `disable-model-invocation`; `allowed-tools` or `context:` unsupported by the body;
relative reference paths; and the total description budget.

Interpreting the results:

| Signal | Threshold | What it means |
|---|---|---|
| Total description characters | > 8,000 | Selection accuracy is degrading. Consolidate or remove. |
| One description | > 500 chars | It is crowding out everything else. Rewrite it shorter. |
| One `SKILL.md` | > 12 KB | Invoking it parks that much in context until the session ends. |
| Skill count | > 40 | Past the point where descriptions get squeezed. |
| `disable-model-invocation: true` | any | The skill can never auto-fire **and cannot be called by another skill**. Intentional for interactive skills; fatal for anything meant to be chained. |

## Step 2. Overlapping coverage

Group skills whose descriptions share trigger vocabulary. Two skills competing for the same request
means neither reliably wins.

Look specifically for pairs across sources — upstream sets overlap with each other and with anything
written locally. Report each cluster as: the skills, the shared triggers, and which one should own
that ground.

## Step 3. Usage — ask the tools that already know

Static analysis cannot tell you what is never used. Three sources can, in order of effort:

**1. `/skill-doctor`.** Purpose-built: which loaded skills are unused and costing context. Ask the user
to run it and paste the output. This is the cheapest answer and covers the bundled and plugin skills a
filesystem audit cannot see.

**2. `~/.claude.json` → `skillUsage`.** A map of skill name to `{usageCount, lastUsedAt}`, readable
directly:

```bash
node -e 'const u=require(process.env.HOME+"/.claude.json").skillUsage||{};
  Object.entries(u).sort((a,b)=>b[1].usageCount-a[1].usageCount)
    .forEach(([k,v])=>console.log(String(v.usageCount).padStart(5), new Date(v.lastUsedAt).toISOString().slice(0,10), k))'
```

Three cautions, all of which have already caused a wrong conclusion here:

- **Absence of a key means "never invoked by name"**, not "useless". An auto-fired skill may not appear.
- **Keys carry no provenance.** A bare `review` may be the bundled skill or a project command of the
  same name, and project-scoped commands from other repositories are mixed in indistinguishably.
- **Compare against install dates.** A skill installed yesterday with no usage tells you nothing. Check
  `~/.agents/.skill-lock.json` or the directory mtime before drawing a conclusion.

**3. OpenTelemetry**, when you want the trigger breakdown rather than a total. Requires
`OTEL_LOG_TOOL_DETAILS=1` (dotagents sets this). Events are `skill_activated`, carrying `skill.name` and
`invocation_trigger`. Emit the queries for the user to run — do not query the backend yourself:

| Question | What to look at | Reading |
|---|---|---|
| Never used? | count of `skill_activated` by `skill.name`, 90 days | **0 → removal candidate** |
| Only ever explicit? | breakdown by `invocation_trigger` | auto-invocation never fires → the description is not doing its job. Rewrite before removing. |
| Fires when unwanted? | activations followed by an immediate change of direction | triggers are too broad |

> **Cursor emits none of this.** The sample is Claude Code only, so a skill used mainly from Cursor
> looks unused here. Never remove on telemetry alone — this narrows the candidates, and the user
> decides.

## Step 4. Report

```markdown
## Skills audit — N skills, M chars of descriptions

### Ours / theirs
N ours, M installed from upstream, of T total.

### Blocking
(errors from Step 1: broken frontmatter, oversized bodies, Cursor-incompatible declarations.
Errors in upstream skills are reported but are not yours to fix in place.)

### Budget
Total M chars against a target of 8,000. Worst offenders:
| Skill | Chars | Suggested cut |

### Overlapping coverage
| Cluster | Skills | Shared triggers | Suggested owner |

### Usage queries
(the queries, for the user to run)

### Proposed actions
| Skill | Ours? | Action | Why |
| … | yes / upstream | keep / rewrite description / consolidate into X / remove | … |
```

## Done when

- [ ] Every error from Step 1 is either listed as blocking or explained as acceptable
- [ ] The description budget is stated as a number against the target
- [ ] Every proposed removal has a reason that is not solely "telemetry says zero"

## Next

Apply the actions you agree with. Removing an upstream skill:
`npx skills remove <name> -g`. Removing one of your own: delete it from `dotagents/skills/` and run
`setup.sh install --prune-scripts`.
