---
name: skills-audit
description: Audit installed skills for bloat and breakage. Use before adding a skill, when skills stop firing automatically, or for periodic clean-up. Checks description budget, overlapping coverage, Cursor incompatibility, oversized bodies, and disuse.
argument-hint: "[path] (default: ~/.agents/skills)"
allowed-tools: Bash, Read, Grep, Glob
metadata:
  source: bwkw/dotagents
---

# /skills-audit — keep the toolkit from rotting

Skills degrade in a specific way: they accumulate. Every installed skill's `description` is resident
in context at all times, so the more there are, the less of each one survives — and the model picks
by matching a request against exactly those descriptions. A toolkit that grows without pruning stops
selecting correctly, and nothing announces it.

**This skill never modifies anything.** It reports, and proposes. Removals are yours to approve.

**This is not `/doctor`, and it is not an eval.** Three different things:

| | Reads | Can see |
|---|---|---|
| `/doctor` | usage logs and settings | which skills were *never invoked*, slow hooks, CLAUDE.md duplication. **Run it too** — this skill cannot see usage. |
| this skill | the files | over-constraint, budget, overlapping triggers, Cursor incompatibility |
| an eval | with-skill versus without-skill runs | whether a skill actually *helps* |

Nothing here measures whether a skill works. Say so when reporting, rather than letting a clean audit
read as a clean bill of health.

## Preconditions

| Condition | If unmet |
|---|---|
| `~/.agents/skills` exists, or a path was given | Stop and report it |
| The dotagents checkout is locatable (`~/.claude/.dotagents-managed.json` → `repo`) | Continue, but skip the checks that need `verify-skills.sh` and say so |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| about to add a skill, or a quarterly clean-up | `/skills-audit` | consolidate, rewrite descriptions, or uninstall |

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

## Step 3. Usage, from telemetry

Static analysis cannot tell you what is never used. Telemetry can.

Requires `OTEL_LOG_TOOL_DETAILS=1` in `~/.claude/settings.json` (dotagents sets this). Events are
`skill_activated`, carrying `skill.name` and `invocation_trigger`.

Emit the queries for the user to run — do not attempt to query the backend yourself:

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
