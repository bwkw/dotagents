# dotagents

Personal AI development toolkit. Skills, hooks, and repository profiles that work in **both Claude
Code and Cursor**, installed once globally. `CLAUDE.md` symlinks here, because Claude Code does not
read `AGENTS.md`.

**The human documentation is in Japanese; skill bodies and this file are in English** — they are prompts
the model reads, and English costs about a third of the tokens. There is no English README: the one that
existed was a 57-line summary of a 385-line document, and a stale translation that contradicts the source
is worse than no translation. This toolkit has one user, and they read Japanese.

Layout, installation, and the upstream skill list are in `README.md`. Why the toolkit has this shape is
in `docs/design.md`. Which mechanism a new thing should be — skill, hook, subagent, MCP, always-loaded
context — is in `docs/mechanisms.md`, with sources. What was decided, and what was decided *wrongly*, is
in `docs/decisions.md`. How to run work through the loop driver — the XS/S/M/L tiers, what stops a landing,
and how to read the ledger — is in `docs/loops.md`. `scripts/handoff.sh` prints where a session
left off, entirely from git, the ledger and `gh` — **there is no hand-written companion to it any more**,
because a copy of the repository's state is the thing that goes stale. This file holds only what you
cannot get by looking.

## Invariants

Each of these fails **silently** when broken — nothing errors, nothing logs, and the tool appears to
work. That is why they are here rather than in a document you would read once.

1. **A skill must work with `name` and `description` alone.**
   Cursor understands `name`, `description`, `paths`, `disable-model-invocation`. Everything else —
   `allowed-tools`, `context: fork`, `model`, `argument-hint` — is silently dropped. State the
   constraint in the body ("this runs in a subagent", "never modify source code") and treat
   Claude-only frontmatter as optimization on top, never the mechanism. Cursor also runs a different
   model family, so the prose is what carries. `verify-skills.sh` checks this.

2. **`disable-model-invocation` is correct for what you always type, and fatal on a dispatch target.**
   It blocks programmatic `Skill` calls and subagent preloading too, not just model auto-invocation —
   and it removes the description from context entirely, which is why it costs zero budget. Two places
   it must never appear, both enforced by `verify-skills.sh` and the lint hook:
   - **`da-verify`** — the only thing that runs `gate.sh arm`. Without auto-invocation the Stop gate never
     arms and passes every turn: the guardrail **opens**. `scripts/loop.sh` gets its gate armed by
     **typing `/da-verify`**, not by calling `gate.sh arm` — an earlier version called it directly and
     this line was reworded to "the only *skill*" to permit that. **Bending the invariant to fit the
     code is the wrong direction**, and the reword also lost the reason: arming is bundled with the
     evidence table, the delegation of checks the repository forbids the agent from running, and the
     refusal when no profile matches. A second caller gets the arming and none of that.
   - **`x-review-backend` / `x-review-frontend` / `x-review-infra`** — `da-review-all` dispatches to them by
     name, so setting it makes the dispatcher report a layer as covered while reviewing nothing.

3. **Frontmatter that a real YAML parser rejects still loads.**
   An unquoted `": "` in a description parses as a nested mapping. The skill appears in the menu with
   its description shown, and is broken. Quote the value or use an em dash.

4. **Hooks are copied, not symlinked.**
   A dangling symlink makes the hook exit 127, which Claude Code treats as non-blocking — the
   guardrail *opens* instead of closing. Copies cannot dangle. This also means editing a hook here
   has no effect until `setup.sh install` runs again.

5. **Reference files are addressed via `${CLAUDE_SKILL_DIR}`.**
   It expands to an absolute path, so a subagent resolves it whatever its cwd. A relative path
   silently fails there.

6. **The gate is inert until a skill arms it**, and `gate.sh arm` is the only thing that does.
   An armed gate with no matching profile passes every turn while reporting itself active; arming
   warns about that. `~/.claude/.dotagents-gate/trace.log` records every invocation and why it
   passed — read it before believing the gate did nothing. **`verdicts.log` beside it is the durable
   one**: the trace self-trims at 200 lines, so anything recorded only there is deleted by ordinary
   operation.

   A gate stops being **armed** by exactly two events — `disarm`, and idle eviction after 12h with no
   turn ending in that repository. It stops **blocking** by a third: a recorded `VERDICT`, written
   after `max_attempts` (3) consecutive failures of the same check. **A released gate is not a green
   one.** `status`, `verdicts.log` and the next `arm` all say it gave up and that the work is
   unverified — if you find yourself reading "not armed" and nothing else, that is a clean session,
   not a reclaimed one, and the difference is the whole point of keeping `ROOT`.

   Arming a repository arms its **linked worktrees** too, matched on the shared git dir. Counters stay
   per worktree: inheriting a gate must not mean sharing an attempt count with another piece of work.
   The functions that decide both live in a `dotagents:gate-shared` block duplicated byte-for-byte in
   `scripts/gate.sh` and the hook — duplicated because invariant 4 forbids a hook depending on a path
   that can go missing, and `verify-skills.sh` asserts the copies match.

7. **Two prefixes, and the split is what keeps the menu honest.**
   **`da-*` is what you type.** **`x-*` is internal** — dispatch targets and subagents, never typed.
   The split exists because `user-invocable: false` is Claude-only and Cursor puts subagents in its
   command picker, so *hiding* by field does not work in both agents. Not sharing the `da` prefix does:
   `/da` returns the same eight entries in Claude Code and in Cursor.
   <!-- dotagents:skill-count mine=11 typed=8 layer=3 agents=2 upstream=15 -->

   Renaming any of them breaks **three** places, and all three fail silently: the
   `disable-model-invocation` scope in `verify-skills.sh`, the same list in the lint hook, and **template
   placeholders like `` `x-review-<layer>` `` that no name-based sweep matches.** The first two broke on
   the `da-` rename and the third broke on the `x-` rename, in the same session. `verify-skills.sh`
   cross-checks that every protected name resolves, that the two enforcers agree, and that no placeholder
   carries the wrong prefix.

   **This paragraph was false for a while, and the way it was false is the lesson.** The cross-check's
   extraction patterns were hardcoded to `da-[a-z-]+` on both sides, so it compared exactly one name —
   and then printed "both enforcers agree", naming that one name as though it were the whole set. The
   `x-review-*` protections, added *because* the `x-` rename broke a guardrail, were never compared.
   Both files now declare the list as data on a `dotagents:dmi-gate` / `dotagents:dmi-dispatch` line and
   drive their behaviour from it, so the check is prefix-agnostic. **The marker comments are
   load-bearing**: removing one removes the check, so the linter errors when either is missing.

8. **Every skill carries `metadata.source: bwkw/dotagents`.**
   Ours sit among two dozen third-party skills, and the difference decides what may be done: ours can
   be rewritten, an upstream one can only be installed or removed, because editing it in place is
   lost on the next `npx skills update`. Hooks prefix output with `[dotagents]` for the same reason.

9. **No secrets here.** `setup.sh` merges only the keys its templates declare and never reads or
   rewrites a value it did not write — the agent settings it edits contain other people's
   credentials.

10. **No agent pins a model. `model: inherit`, always.**
    A pin **silently overrides the model chosen for the session** — you pick Opus, a subagent runs on
    something else, and neither the prompt nor the transcript says so. This is the invariant most likely
    to be broken *on purpose*, because a pin genuinely is cheaper (~37% fewer tokens) and the reasoning
    for it always sounds good: "tracing is mechanical, it doesn't need the big model." It shipped once on
    exactly that argument and was reverted.

    The rule is about **whose decision it is**, not about the size of the saving. A saving the user did
    not agree to is the tool disagreeing with them quietly.

    **This one is not a Claude-only field, and getting that backwards is easy.** Invariant 1 says
    `model:` is dropped by Cursor — that is true of **skill** frontmatter. On a **subagent** Cursor reads
    `name`, `description`, `model`, `readonly`, `is_background`, and `inherit` is its documented default
    too. So a pin overrides the user in *both* agents. The reflex "it's Claude-only, so it's just an
    optimization" is the wrong reflex here, and it was written into this file once already.

    **Take cost out of how *many* subagents run — never out of what they run on.** That sentence used to
    point at the fan-out budget in `skills/_shared/review-process.md`; **the review now runs zero
    subagents**, so the money came out of the count all the way down, and none of it out of the model.
    The rule is unchanged and now has one fewer place to be broken. `verify-skills.sh` errors on any
    `model:` that is not `inherit`.

## How implementation is done

**Test first, always.** A failing test before the code that makes it pass — not tests written afterwards
to describe what was built. This is the default for every feature and every bugfix, not a mode to be
asked for. `/test-driven-development` has the detailed process; this line is here because the default has
to hold when nobody invokes it.

Two consequences worth stating: a bugfix starts with a test that reproduces the bug, so "fixed" has a
meaning; and **a test written after the implementation, from the implementation, tests that the code does
what it does.** If tests were added last, say so rather than presenting them as verification.

**Weight the suite toward integration level.** Exercise the units together across the seam they meet at,
through the real boundary rather than a mock of it — for a change spanning frontend and backend, the test
that counts is the one that goes through both. Unit tests still matter and a pure function still gets
one; what is being ruled out is a **suite that is green because every collaborator was stubbed**, which
is the shape that passes while the assembled system does not.

This preference also lives in the driver's implement prompts (`scripts/loop.sh`), **and that duplication
is deliberate**: the loop runs against product repositories, whose agents never read this file. A
preference recorded only here is one the unattended rounds never hear.

## Sizes that bite

`SKILL.md` at or under 12 KB. A skill's body stays in context until the session ends and is never
re-read; after auto-compaction only the first ~5,000 tokens of each are restored, so anything past
that is silently lost. Detail belongs in `reference/`, loaded on demand.

Descriptions are resident permanently, all of them, always. Every skill added costs the selection
accuracy of every existing one. `/da-skills-audit` measures it.

## Working with skills

Before acting, check whether an installed skill already covers the task — `/` lists them, and
`README.md` has a "say this / when" table. **A user instruction outranks anything a skill says.** Some
skills require a clarifying question as their first act (`da-investigate` and `da-design-review` both refuse
an unstated goal); when a skill's preconditions ask a question, ask it before doing the work.

## Adding upstream skills

**Always with `-s`.** `npx skills add <repo>` without it takes the whole repository and blows the
description budget in one command. The curated lists are in `README.md`.

**Removing leaves orphans.** `npx skills remove <name> -g -a claude-code -a cursor` unlinks the agent
directories and updates `~/.agents/.skill-lock.json`, but **leaves the real directory in
`~/.agents/skills/`**. Cursor reads that path natively, so the skill stays live there while reporting
as removed from Claude Code. Delete the store directory too, then confirm the two agree:

```bash
diff <(ls -1 ~/.agents/skills) <(ls -1 ~/.claude/skills)
```

## Writing a skill

Start from `_template/`, then `./scripts/verify-skills.sh`. Required sections, in order:

- **Preconditions** — a table of what must hold, each row saying what to do when it does not: stop,
  report which condition failed, do not continue. The linter checks this section exists.
- **Files to read** — split into "always" and "read only if". A skill that reads everything up front
  has spent the context its own work needs.
- **Read-only declaration** for anything that investigates or reviews.
- **Evidence discipline** — either in the body or delegated to a `reference/` file. Only what was
  verified directly; cite `path/file.ts:L42`; say "could not confirm" rather than guessing; keep fact
  and inference apart; attach URLs to external claims.

**Where a review lens goes.** `skills/_shared/` holds the **mechanism** — a lens that applies in every
layer and in both the find and the verify phase. It is symlinked, so a paragraph added there is a
paragraph every review skill reads. A layer's `reference/perspectives.md` holds the **instance**: the
concrete shape that mechanism takes in that stack, naming the field, file type or API. When both are
true, the mechanism goes in `_shared/` and the layer file **points at it in one line instead of
restating it** — two copies of one lens drift, and the drift is invisible because both still read
well. `verify-skills.sh` checks that the pointer resolves, so the one line cannot outlive the file it
names. Decision 30 in `docs/decisions.md` has the reasoning and the boundary of that check.
