# 0002 — Hook scripts are copied, never symlinked

## Status

Accepted.

## Context

Skills are distributed as symlinks (ADR 0001), so the obvious move is to distribute hooks the same
way. It is wrong, and the failure mode is the dangerous direction.

If a hook symlink cannot resolve — the repository is on a branch without that file, the checkout
moved, the disk is not mounted — the shell fails to start the script and returns **exit 127**.
Claude Code treats a non-zero exit that is not 2 as non-blocking. So a broken guardrail does not
stop the agent; it *stops guarding* and lets the turn through.

A guardrail that fails open is worse than no guardrail, because you believe it is there.

The script cannot defend against this itself: exit 127 happens before any line of it runs.

## Decision

`setup.sh` copies `hooks/*.sh` into `~/.claude/hooks/` as real files. It never links them.

`setup.sh install --prune-scripts` removes copies this repository previously installed but no longer
ships, so stale hooks do not accumulate.

Guardrail hooks exit **2** to block. They never exit 1 or fall off the end silently, because only
exit 2 blocks.

## Consequences

- Editing a hook in this repository does not take effect until `setup.sh install` runs again. That is
  the cost, and it is worth paying: `doctor` reports when an installed copy differs from the source.
- Copies cannot dangle, so the fail-open path is removed rather than mitigated.

## Provenance

Observed in `gamonges/gamonges-prompt`, whose own notes record hitting exactly this: symlinked
scripts became unresolvable while the main checkout sat on a branch without them, every hook returned
127, and the guardrails opened.
