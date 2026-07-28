# Writing a repository profile

A profile tells `/verify` and the Stop gate how to check *this* repository. It lives in the dotagents
repo, not in the product repo — that is what keeps product repositories unmodified.

File: `<dotagents>/profiles/<repo-name>.json`. Schema: `_schema.json`. Start from `_example.json`.

**Profiles are gitignored.** They name real repositories, real environments, and sometimes an
employer's internal rules, so they stay on the machine that wrote them. Only the schema and the
example are tracked.

## Procedure

**Do not guess.** Read the repository and derive each command from what is actually there:

1. `package.json` scripts (or `Makefile`, `justfile`, `mise.toml`, `Cargo.toml`, …).
2. The CI workflow. It shows which checks actually gate a merge — the best available definition of
   "done" for this repository.
3. Pre-commit hooks (`lefthook.yml`, `.pre-commit-config.yaml`) — what already runs locally.
4. **`CLAUDE.md`, `AGENTS.md`, and any `.claude/skills/` in the repository.** This is where a
   repository states its own rules about what an agent may run. Honour them; a profile that ignores
   them breaks the repository's rules on the repository's behalf.

Then propose the profile to the user and confirm the commands before saving.

## Field decisions

**`gate`** — true when failing it must block completion. Match CI: if the pipeline fails on it, it
gates. Advisory or conditional checks are `gate: false`.

**`agent_may_run`** — false in three situations:

- **The repository forbids it.** Some repositories document that an agent must not run a particular
  command — a typecheck needing more heap than the session has, a script with side effects. That
  rule is the repository's to make, and a profile that overrides it is a bug.
- **It spends credentials the session should not** — anything needing a cloud profile, a production
  database, a paid API.
- **It is slow enough that running it unattended is antisocial.**

Always pair it with `delegate_reason`. An unexplained request to run something by hand reads as
arbitrary and gets ignored.

**`scope: "changed"`** — when the command takes file arguments and the repository discourages full
runs. `{files}` is substituted with the changed files; with nothing changed the check is skipped
rather than widened.

**`forbidden`** — substrings that must never be executed here. Derive them from the scripts: every
deploy, every destroy, anything touching a live environment, and anything the repository's own docs
prohibit. Cheap to over-populate, expensive to under-populate.

**`cwd`** — relative to the repository root, for monorepos where the real project is a subdirectory.

## Two details worth copying

**Pin test runners to their non-interactive form.** Many repositories define `test` as a bare
watch-mode runner (`vitest`, `jest --watch`). An agent that runs it hangs until killed. Write
`vitest run`, `jest --ci`, `pytest -x` — whatever exits on its own.

**Put the wrong-but-plausible invocations in `forbidden`.** If the repository standardises on one
package manager, the others belong there. `npx tsc` in a repository that requires `pnpm typecheck`
appears to work and checks the wrong thing.

## After writing one

```bash
node -e 'JSON.parse(require("fs").readFileSync("profiles/<name>.json"))'   # valid JSON
```

Then run every `agent_may_run: true` check by hand once and confirm each exits 0 on a clean tree.
A profile whose commands fail on a clean checkout blocks every turn, and the fastest way out of that
is to disable the gate — which is how a verification gate quietly dies.
