# Which mechanism, and why

日本語: [mechanisms.ja.md](mechanisms.ja.md)

Claude Code and Cursor both offer several ways to change how the agent behaves. They are not
interchangeable, and picking the wrong one is how a rule ends up written down somewhere it is never
enforced.

This document records the official guidance, with sources, and the two places this toolkit deviates
from it. It exists because "should this be a skill or a hook" came up often enough to be worth
answering once.

Sources, all read 2026-07-28:

- [Extend Claude Code — features overview](https://code.claude.com/docs/en/features-overview)
- [Extend Claude with skills](https://code.claude.com/docs/en/skills)
- [Skill authoring best practices](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/best-practices)
- [Steering Claude Code: when to use CLAUDE.md, skills, hooks, and subagents](https://claude.com/blog/steering-claude-code-skills-hooks-rules-subagents-and-more)
- [Agent Skills — Cursor](https://cursor.com/docs/skills) · [Subagents](https://cursor.com/docs/subagents) · [Hooks](https://cursor.com/docs/hooks)

---

## The decision, in one table

The official framing is a set of **triggers** rather than a taxonomy — you pick by what just happened,
not by what category the thing feels like it belongs to.

| What happened | What to add |
|---|---|
| The agent gets a convention wrong twice | Put it in `AGENTS.md` |
| You keep typing the same prompt to start a task | A skill you invoke by name |
| You have pasted the same playbook a third time | A skill |
| You keep copying data from something the agent cannot see | An MCP server for the connection, and a skill for how to use it well |
| A side task floods the conversation with output you will not reread | A subagent |
| You want something to happen **every time, without asking** | A hook |
| A second repository needs the same setup | A plugin, then a marketplace |

The single most useful line in the official docs is the one that decides hook-versus-anything-else:

> Put guardrails in hooks. An instruction like "never edit `.env`" in CLAUDE.md or a skill is a
> request, not a guarantee.

A skill is read and interpreted. A hook runs. If a rule has to hold on a bad day, it is a hook.

## What each one costs

| Mechanism | Loads | Cost |
|---|---|---|
| `AGENTS.md` | every session | every request, always |
| Skill **description** | every session | every request, for every installed skill |
| Skill **body** | when invoked | stays in context for the rest of the session; never re-read |
| Subagent | when spawned | isolated — the reading stays in its context |
| Hook | on its event | zero, unless it returns output |
| MCP server | session start | tool names only; schemas on demand |

Two consequences that drive most of this repository's decisions:

**Every installed skill taxes every other one.** Descriptions share a listing budget of **1% of the
model's context window**. On overflow, Claude Code "drops descriptions starting with the skills you
invoke least" — so an unused skill does not merely sit there, it degrades the auto-invocation of the
ones you do use, silently. `verify-skills.sh` targets 8,000 characters, which is roughly 1% of a 200K
window; the real budget scales with the model, and `/doctor` reports the actual figure.

**And most of what shares that budget is not in this repository.** Counted on this machine:

| Source | Names | Where |
|---|---|---|
| On disk | 24 | `~/.agents/skills/` — 9 ours, 15 upstream |
| `anthropic-skills@inline` plugin | 11 | `~/Library/Application Support/Claude/local-agent-mode-sessions/skills-plugin/…` |
| **Compiled into the CLI binary** | **40** | **no files exist.** Registered as string constants inside the executable |
| **Total reachable** | **75** | ~46 listed to the model in a typical session |

Two inventories of this repository were wrong because they read the filesystem, and 40 of the 75 are not
on the filesystem. **A skill count taken from `~/.agents/skills` is not the total** — `/doctor` and
`/skill-doctor` see the whole set. See ADR 0006.

**A skill body is a recurring cost, not a one-off.** Once invoked it stays for the session and is
never re-read, so guidance meant to apply throughout must be written as standing instruction rather
than as a step. After auto-compaction only the first ~5,000 tokens of each are restored. Hence
`reference/`: detail loads on demand, and costs nothing until read.

---

## Commands are skills now

There is no commands-versus-skills decision to make. Official, verbatim:

> **Custom commands have been merged into skills.** A file at `.claude/commands/deploy.md` and a skill
> at `.claude/skills/deploy/SKILL.md` both create `/deploy` and work the same way. Your existing
> `.claude/commands/` files keep working. Skills add optional features: a directory for supporting
> files, frontmatter to control whether you or Claude invokes them, and the ability for Claude to load
> them automatically when relevant.

Commands are not deprecated — the language is "merged", "keep working", "Skills are recommended" — but
there is **no documented case where a bare `commands/*.md` is preferable**. It is a skill with fewer
options, kept for compatibility. Cursor's commands documentation page is now a 404.

So this repository has no `commands/` directory, and adding one would be a step backwards.

### The two kinds of skill

What used to be the command-versus-skill question is now one frontmatter field.

| | Model-invoked (default) | You-invoked (`disable-model-invocation: true`) |
|---|---|---|
| You type `/name` | yes | yes |
| The model picks it | yes | **no** |
| Another skill calls it by name | yes | **no** |
| Description in context | yes | **no — zero budget cost** |

Official guidance on when to set it:

> Use `disable-model-invocation: true` for skills with side effects. This saves context and ensures
> only you trigger them. … You don't want Claude deciding to deploy because your code looks ready.

So: **side effects, or you always type it anyway.** Not for reference knowledge, where automatic
invocation is the entire value.

The trap is the third row. It blocks programmatic `Skill` calls and subagent preloading, not just
automatic invocation — so setting it on something another skill dispatches to breaks that dispatch
**with no error**. Two skills here can never have it, and both the lint hook and `verify-skills.sh`
enforce it (see ADR 0005):

- **`da-verify`** — the only thing that runs `gate.sh arm`. Without automatic invocation the Stop gate
  never arms and passes every turn: the guardrail opens.
- **`da-review-backend` / `da-review-frontend` / `da-review-infra`** — `da-review-all` dispatches to them by name.

### Hiding from the menu is a different field

`user-invocable: false` keeps the skill in the model's context but takes it out of the `/` menu — the
mirror image of `disable-model-invocation`. The three layer reviews use it, so `/da-review-all` is the
only review entry you type while the layers stay reachable by dispatch and by naming a layer.

Two things this costs, both accepted:

- **Cursor ignores the field**, so the layers stay in its menu. That is a *presentation* difference, not
  a behavioural one, which is the line ADR 0003 draws — strip the Claude-only field and the skill still
  does the same thing.
- **Combined with `disable-model-invocation` it makes a skill unreachable by every route**, and on a
  skill nothing dispatches to it is reachable only by description match. `verify-skills.sh` errors on
  both cases rather than trusting the author to remember.

---

## Cursor reads a subset of all of it

Both agents are first class here, so the binding constraint is whatever Cursor understands.

| | Claude Code | Cursor |
|---|---|---|
| Skills | `~/.claude/skills/`, follows symlinks | `~/.agents/skills/` natively, plus `.cursor/`, `.claude/`, `.codex/` |
| Skill frontmatter | many fields | **`name`, `description`, `paths`, `disable-model-invocation`, `metadata` only** |
| `name` must match the directory | no | **yes** |
| Subagents | `~/.claude/agents/` | reads `.claude/agents/` too; fields are `name`, `description`, `model`, `readonly`, `is_background` |
| Hooks | `settings.json`, PascalCase events | `hooks.json`, camelCase events, **incompatible** |
| Always-loaded context | `CLAUDE.md` | `AGENTS.md` or `.cursor/rules` |
| Commands | legacy | documentation page removed |

Everything else in a Claude Code `SKILL.md` — `allowed-tools`, `argument-hint`, `context: fork`,
`model`, `when_to_use` — is simply absent in Cursor, with nothing reporting it. Hence the rule in
`AGENTS.md`: **strip every Claude-only field and the skill must still behave the same.** Constraints
go in the body as prose; frontmatter is optimisation on top. The same applies to subagents, which is
why both agent definitions here state their read-only constraint in the body as well as in `tools:`.

`${CLAUDE_SKILL_DIR}`, `$ARGUMENTS` and `!`command`` interpolation are Claude Code extensions. Where a
skill depends on one, that dependence needs to be survivable in Cursor.

---

## Where this repository deviates

Two places, both deliberate.

**`verify-skills.sh` hardcodes an 8,000-character budget** where the real one scales with the model.
The number is a reverse-engineered approximation of 1% of a 200K window, and there is a known upstream
issue about the budget being computed against a fixed baseline rather than the actual context window.
A fixed target that is occasionally too strict is more useful than no target; `/doctor` is the source
of truth.

**`skillOverrides` is used, but only on skills Cursor does not have.** The four values are `on`,
`name-only` (listed, no description), `user-invocable-only` (hidden from the model, still typable) and
`off` (hidden from both). It lives in Claude Code's `settings.json`, which Cursor does not read — so
using it on one of *our* skills would make the two agents disagree about what is active, and
`/da-skills-audit` reads files rather than settings and could not see that divergence. Bundled and
plugin skills do not exist in Cursor at all, so there is nothing to diverge from; six of those are
suppressed through `templates/claude.settings.snippet.json`, which keeps them tracked in the manifest and
reverted exactly by `uninstall`. **The rule is: never on a skill that also exists in Cursor.** ADR 0006.

## Two hazards specific to this machine

**There are two Claude Code installations, and the settings do not behave the same in both.** `claude` on
`$PATH` is a mise shim to **2.1.148**; Claude Desktop downloads and runs its own **2.1.219**. Verified
against the two binaries' own settings schemas:

| Setting | 2.1.148 | 2.1.219 |
|---|---|---|
| `skillOverrides` | yes | yes |
| `skillListingBudgetFraction` (default `0.01`) | yes | yes |
| `skillListingMaxDescChars` (default `1536`) | yes | yes |
| **`disableBundledSkills`** | **absent — silently ignored** | yes |

This is why suppression here uses per-name `skillOverrides` rather than `disableBundledSkills`: the
blunt switch would do nothing under the older binary and give no indication of it. `disableBundledSkills`
would also be wrong on the merits — it removes all ~40 bundled skills at once, including `code-review`
and `review`, which the usage log shows in real use.

**The bundled skills change with the binary.** They are compiled in, so a CLI upgrade can add, rename or
remove names with nothing in this repository noticing. An override naming a skill that no longer exists is
inert rather than an error, so a stale entry fails quietly. Re-read `/doctor` after a version change.

---

## Sources behind the review perspectives

The review skills' checklists are not invented here. Where a perspective carries a number or a named
technique, this is where it came from — recorded so a future reader can check whether it still holds
rather than trusting it.

| Claim used in a skill | Source |
|---|---|
| A model judging output rates its own family's work 10–25% higher, more so in more capable models; never use the same model as judge and candidate; ensembling reduces variance but not shared systematic bias | [Self-Preference Bias in LLM-as-a-Judge](https://arxiv.org/pdf/2410.21819), [Justice or Prejudice? Quantifying Biases in LLM-as-a-Judge](https://arxiv.org/pdf/2410.02736), [LLM-Judge Bias Mitigation (2026)](https://futureagi.com/blog/evaluating-llm-judge-bias-mitigation-2026/) |
| Verbosity bias inflates preference for longer answers by 15–30 points; position bias exists | same |
| ~20% of agent-authored samples reference packages that do not exist; slopsquatting registers the hallucinated names; yanked or CVE-bearing versions get reproduced; happy-path bias shows up as catch-all handlers and calls without timeouts | [AI Hallucinations in Production Code (2026)](https://www.devx.com/uncategorized/ai-hallucinations-production-code-risks-mitigations-2026/), [AI-Generated Code Review Standards](https://www.metacto.com/blogs/establishing-code-review-standards-for-ai-generated-code), [CSA: AI-Generated Code Vulnerability Surge](https://labs.cloudsecurityalliance.org/research/csa-research-note-ai-generated-code-vulnerability-surge-2026/) |
| Prospective hindsight — imagining the failure as already having happened — raises correct identification of causes by ~30% | Mitchell, Russo & Pennington 1989, via [Performing a Project Premortem](https://www.researchgate.net/publication/3229642_Performing_a_Project_Premortem) (Klein, HBR 2007) and [Ness Labs](https://nesslabs.com/pre-mortem-anticipate-failure-with-prospective-hindsight) |
| Core Web Vitals thresholds LCP ≤ 2.5s, INP ≤ 200ms, CLS ≤ 0.1; INP replaced FID and is the most commonly failed; cause is main-thread JavaScript during interaction | [Core Web Vitals 2026 guide](https://www.digitalapplied.com/blog/core-web-vitals-2026-inp-lcp-cls-optimization-guide), [Ultimate checklist](https://www.corewebvitals.io/core-web-vitals/ultimate-checklist) |
| WCAG 2.2 supersedes 2.1 with nine new criteria; contrast is the most common failure; Accessible Authentication (3.3.8) requires paste and autofill to work | [WCAG 2.2 checklist](https://www.levelaccess.com/blog/wcag-2-2-aa-summary-and-checklist-for-website-owners/), [What frontend developers need to fix](https://danholloran.me/posts/wcag-2-2-what-frontend-developers-need-to-fix) |
| CSP: avoid `unsafe-inline`/`unsafe-eval`, prefer nonce or hash, minimise allowlisted domains, re-review when a dependency is added | [OWASP WSTG: Test for CSP](https://owasp.org/www-project-web-security-testing-guide/latest/4-Web_Application_Security_Testing/02-Configuration_and_Deployment_Management_Testing/12-Test_for_Content_Security_Policy) |
| Terraform state holds attributes in plaintext; encrypt, version and lock the backend; restrict who can read it; scanners cover the mechanical checks | [Terraform Architecture Review Checklist (CIS-mapped)](https://archguard.io/blog/terraform-architecture-review-checklist), [IaC Security Review](https://www.propelcode.ai/blog/infrastructure-as-code-security-review-terraform-cloudformation) |
| Production-readiness dimensions, and that dependency readiness is a commonly skipped one | [Google SRE: Production Readiness Review](https://sre.google/sre-book/evolving-sre-engagement-model/), [Launch checklist](https://sre.google/sre-book/launch-checklist/), [Production readiness checklist](https://getdx.com/blog/production-readiness-checklist/) |
| Do not block on personal style preference; mark optional comments as `Nit:` | [Google: What to look for in a code review](https://google.github.io/eng-practices/review/reviewer/looking-for.html) |

Two of these changed a design decision rather than adding a checklist item, and both are worth knowing
before trusting a review:

- **The three-lens verification pass is not three independent opinions.** It is one model checked from
  three angles. That reduces the chance of one bad run and does nothing about bias shared across all
  three. The skills now say so, and route to a different model where one is available.
- **`refuted` as the default verdict is a counterweight, not pessimism.** With self-preference measured
  at 10–25%, a neutral prior over-confirms. This was originally chosen on instinct; the number is why it
  stays.
