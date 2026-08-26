# Where this repository records intent, and what checks it

Two skills need this and neither owns it: `da-spec` writes the artifact, `da-design-review` reviews it.
Both have to answer the same three questions first — **which convention, which file, and what
mechanically checks it** — so the answer lives here once.

## Resolve it from the profile, never from the tree

```bash
git remote get-url origin
```

Find the profile whose `match.remote` is a substring of that URL. The dotagents checkout is recorded in
`~/.claude/.dotagents-managed.json` under `repo`; profiles live in `<repo>/profiles/`. Read
`spec_system`.

| `kind` | The artifact for one change |
|---|---|
| `openspec` | a **directory**: `<root>/changes/<id>/` — proposal, design, tasks, plus a spec delta per capability under `changes/<id>/specs/` |
| `plans` | one Markdown file under `<root>` |
| `none` | nothing. The repository records intent nowhere — **say that, and do not create a convention** |

**No profile, or no `spec_system`: stop and ask.** Report what you observed in the tree, propose the
block, and wait.

**Observing `openspec/` is not the same as being told to use it.** A directory can survive a
half-finished migration, or a repository can keep plans in two places while one is being retired. The
failure is quiet in the worst way: the artifact lands in a real directory, well-formed, where nobody
looks for it.

**`README.md` is not where this can live.** It is not loaded at runtime, and the routing sat there as a
parenthetical for months while every invocation ignored it. That is why the fact is in the profile and
the rule is in a file a skill reads.

## Read the repository's own rules before writing or judging anything

`spec_system.rules` names the file — for openspec, `openspec/config.yaml`, which states the required
headings, the normative vocabulary, and that a modified requirement is restated whole. It usually
delegates further, to `.cursor/rules/*` or `AGENTS.md`.

**This is not optional in either direction.** Writing to a generic template produces an artifact that
fails the repository's own validator. **Reviewing against generic dimensions while the repository has
written its standard down produces findings about the wrong thing** — and a clean result that means
nothing, because the checklist it passed was not the one that applies.

## Run the validator, and paste its output

`spec_system.validate` is **argv, not a shell string** — one element per argument, and the element that
is exactly `<id>` is replaced by the change id:

```json
["pnpm", "openspec", "validate", "<id>", "--strict"]
```

**The array is the point.** A profile cannot smuggle a pipeline, a `;`, or a `$( )` past a reader, and
the change id cannot escape into the command because it is its own argument. **Refuse an argv whose
first element is `sh`, `bash` or `zsh`, or that contains `-c`** — that is a command string wearing an
array's clothes, and it puts back everything the array removed.

**The change id must match `^[a-z0-9][a-z0-9._-]*$`.** It arrives from `$ARGUMENTS` or from a directory
listing, and both are attacker-reachable in a repository you did not write. Anything else: stop and say
which id was rejected. Do not "clean it up" and continue.

**Check every element against the profile's `forbidden` list before running.** Be honest about what that
is worth: the gate hook enforces `forbidden` on the checks *it* runs, and nothing enforces it on a
command an agent types. Its own comment says why — *a rule written in a skill is a request, not a
guarantee, and guardrails belong in hooks.* **The guarantee is the `allowed-tools` allowlist**, which the
harness applies; this check is the request on top of it. **A validator the allowlist does not cover is
reported as unrunnable — never rerouted through an interpreter that happens to be allowed.**

**Run it before judging, and show the output.** A spec whose validity is machine-checkable must not be
assessed by reading alone — that is the rule `da-verify` applies to code, applied to intent. Describing
the failure instead of showing it is the same substitution the toolkit refuses everywhere else.

**Green means well-formed, and nothing more.** It does not mean the requirement is the right
requirement, that `ADDED` should not have been `MODIFIED`, that the scenarios cover the failure paths,
or that the change agrees with a sibling capability. **Say exactly that when reporting it** — a green
validator read as "the design is sound" is the same misweighting a clean review causes.

No validator configured → **say so**. "Nothing checked this" is a fact the next reader needs.

## The landing plan and the repository's task list are different orderings

Both exist, and confusing them collapses a distinction that costs money.

| | Decides | Granularity |
|---|---|---|
| **🧱 Landing plan** (`da-design-review`) | **how the work divides into separately shippable changes** | one row per landing, each with a gate you can name |
| the repository's task list (openspec `tasks.md`, or the plan's checklist) | **the order inside one** of those | one line per step |

So the mapping is: **a landing plan with N rows means N changes** — N `changes/<id>/` directories in an
openspec repository, N plan files otherwise. **Not one change with the landings as task groups**: the
whole point of a landing is that it ships on its own, and tasks inside one change do not.

**When the landing plan has one row, say so as one row with a reason.** An absent table means nobody
decided, and that is the state this distinction exists to prevent.

Do not maintain the same ordering in both places. The landing plan is upstream of the task list, and
when they disagree the landing plan is the one that was reasoned about.
