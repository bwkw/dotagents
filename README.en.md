# dotagents

A personal AI development toolkit that works from **any** repository, in **both Claude Code and
Cursor**, without putting a single file inside the repository being worked on.

> **The documentation is in Japanese** — [README.md](README.md) is the real entry point. This page is a
> summary so a visitor can tell what this is. **Skill bodies are all in English**, because they are
> prompts the model reads and English costs roughly a third of the tokens.

## What it is

Ten skills of my own plus eleven installed selectively from well-regarded upstream collections, two
global subagents, two hooks, and an installer. Everything lands in `~/.agents/skills/`, which Cursor
reads natively and Claude Code reaches by symlink.

**Type `/da` and you get seven things** — the same seven in both agents:

| Skill | For |
|---|---|
| `/da-investigate` | Trace a question through a codebase with a stated budget and `file:line` evidence |
| `/da-design-review` | Review a plan before any code exists — one-way doors, migration order, rollback |
| `/da-review-all` | Review a change across every layer it touches, then find the risks that fall *between* them |
| `/da-fix-plan` | Turn a review report into an ordered plan whose primary job is deciding what **not** to fix |
| `/da-verify` | Run this repository's own checks and report with evidence, never a claim |
| `/da-pr-describe` | Write the PR description |
| `/da-skills-audit` | Keep the toolkit from accumulating skills that crowd out the ones that work |

Three layer reviews (`x-review-backend` / `-frontend` / `-infra`) and two subagents carry an `x-`
prefix instead: they are dispatch targets, never typed. The prefix split exists because neither agent
offers a field that hides them in both.

## The constraints that shaped it

- **Nothing is written into a product repository.** Distribution is global or it does not happen.
- **Behaviour lives in the skill body, not the frontmatter.** Cursor silently ignores every field
  outside `name` / `description` / `paths` / `disable-model-invocation` / `metadata`, so a skill must
  behave identically with the Claude-only fields stripped.
- **Guardrails go in hooks.** An instruction in a skill is a request, not a guarantee.
- **Hooks are copied, never symlinked.** A broken symlink makes a hook exit 127, which Claude Code
  treats as non-blocking — the guardrail opens rather than closes.

## Install

```bash
git clone https://github.com/bwkw/dotagents ~/private/dotagents && ~/private/dotagents/scripts/setup.sh install
```

`setup.sh status` · `doctor` · `uninstall` · `--revert`. Settings are merged key by key and reverted
exactly.

## Reading order

[README.md](README.md) (use cases) → [docs/design.md](docs/design.md) (why this shape, with sources
and what is uncertain) → [docs/mechanisms.md](docs/mechanisms.md) (which mechanism to use) →
[docs/decisions.md](docs/decisions.md) (what was decided, and what was decided wrongly).

MIT. Nothing here is specific to any employer.
