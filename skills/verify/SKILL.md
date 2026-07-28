---
name: verify
description: Run this repository's own verification commands and report with evidence. Use before claiming work is done, before committing, or before opening a PR. Resolves commands from the repo's profile rather than guessing, and refuses what the repo forbids.
argument-hint: "[check-id] (default: every gating check)"
allowed-tools: Bash, Read, Grep, Glob
---

# /verify — run the checks, show the evidence

Claude stops when work *looks* done. Without a check it can actually run, "looks done" is the only
signal available, and the human ends up being the verification loop. This skill is the check.

**This skill never modifies source code.** It runs verification commands and reports what happened.

It is also the **manual path for the Stop gate**. `dotagents-verify-gate.sh` runs these same checks
at the end of a turn on both agents — but only Claude Code's Stop hook can actually refuse to
finish. **Cursor's `stop` hook cannot block**; it only auto-submits a follow-up message asking the
agent to keep going, and Cursor caps how many times that can happen. So in Cursor the gate is a
nudge, and running `/verify` explicitly is how you actually know. Do not assume parity.

## Preconditions

| Condition | If unmet |
|---|---|
| The working directory is inside a git repository with an `origin` remote | Stop and report it. The profile is resolved by remote. |
| The dotagents checkout is locatable (`~/.claude/.dotagents-managed.json` → `repo`) | Report it, and run the checks without arming the gate. Say that the gate is not active. |
| A profile matches this repository | **Stop.** Report that no profile exists, show the repository's remote, and offer to write one. **Never guess commands** — running an invented `npm test` in an unfamiliar repository is how a verification tool loses trust. |

## Position in the workflow

| Upstream | This skill | Downstream |
|---|---|---|
| implementation, or a fix | `/verify` | commit, `/pr-describe`, `/review-all` |

## Files to read

### Always read

| File | Why |
|---|---|
| the matching `profiles/*.json` | The commands, and which of them you are permitted to run |

### Read only if

| File | Trigger condition |
|---|---|
| `${CLAUDE_SKILL_DIR}/reference/profile-authoring.md` | Only when no profile matches and you are writing one |

---

## Steps

### Step 0. Arm the gate

```bash
<dotagents>/scripts/gate.sh arm
```

This is what makes the end-of-turn gate active for this repository. **Without it the gate does
nothing** — it is deliberately inert until a skill arms it, so that sessions which only answer
questions never run a test suite on the way out.

Arm it when the session is going to change code. For a read-only question, skip this step and just
report; there is nothing to hold.

The dotagents checkout is recorded in `~/.claude/.dotagents-managed.json` under `repo`.

### Step 1. Resolve the profile

```bash
git remote get-url origin
```

Find the profile in the dotagents repository whose `match.remote` is a substring of that URL. The
dotagents checkout is recorded in `~/.claude/.dotagents-managed.json` under `repo`; profiles live in
`<repo>/profiles/`.

No match → stop, per the preconditions.

### Step 2. Report what you are about to run

Before running anything, show the user the table: check id, command, whether you may run it. This is
what makes a wrong profile obvious in one glance instead of one confusing failure.

### Step 3. Run the checks you are permitted to run

For each check with `agent_may_run: true`, in profile order:

- Run it from the profile's `cwd` (relative to the repository root).
- Where `scope` is `changed`, substitute `{files}` with the changed files
  (`git diff --name-only --diff-filter=d HEAD`). **If nothing changed, skip the check** — do not run
  the whole suite as a substitute.
- Where a command matches anything in the profile's `forbidden` list, **do not run it**, and say why.
  That list exists because these repositories contain `deploy:production` and `destroy:production`.
- On failure, stop and report. Do not push on to the remaining checks — the first failure is the
  information the user needs.

### Step 4. Delegate what you are not permitted to run

For each check with `agent_may_run: false`:

- **Do not run it.** The flag exists because the repository forbids it, or because it consumes
  resources or credentials the session should not.
- Show the user the exact command and the `delegate_reason`, and ask them to run it.
- **Wait for their output.** Do not proceed, and do not report success, while a gating check is
  outstanding. "I asked the user to run typecheck" is not a result.
- When they report it, record it so the gate can see it:
  ```bash
  <dotagents>/scripts/gate.sh record <check-id>
  ```
  Do not write the file by hand. The gate finds the armed directory by the repository root stored
  inside it, and a hand-written path can land somewhere the gate never looks.

### Step 5. Report with evidence

**State the evidence, do not assert success.** A claim that something passes, without the command
and its exit code, is the thing this skill exists to prevent.

```markdown
## Verification

| Check | Command | Exit | Ran by | Output (tail) |
|---|---|---|---|---|
| lint | `pnpm run lint:fix` | 0 | agent | … |
| typecheck | `NODE_OPTIONS=… pnpm typecheck` | 0 | **user** | … |
| unit | `pnpm exec vitest run src/foo.spec.ts` | 1 | agent | 1 failed |

**Not run:** sql (scope: changed, no matching files changed)
```

Write **"not run"** for anything you did not run. Never write "should pass" or "presumably fine" —
if it was not executed, that is the finding.

### Step 6. Release the gate when everything is green

```bash
<dotagents>/scripts/gate.sh disarm
```

Leave it armed while anything is still red — that is the point. Disarm once the checks pass, or when
abandoning the work; an armed gate in a repository you are no longer changing blocks turns for no
reason, and a gate that blocks for no reason gets switched off.

`gate.sh status` shows whether this repository is armed and what has been recorded.

## Done when

- [ ] Every gating check is either green with evidence, or explicitly reported as failing or not run
- [ ] Nothing on the `forbidden` list was executed
- [ ] No `agent_may_run: false` check is recorded as passing without the user's own output
- [ ] The gate is disarmed if everything passed, still armed if anything is red

## Next

All green → commit, then `/review-all`. Anything red → fix it, then run `/verify` again.
**If the same check fails twice in a row, stop patching.** Write down what you tried and why it
failed, `/clear`, and restart with that folded into the prompt — repeated correction piles failed
approaches into the context and makes each attempt worse than the last.
