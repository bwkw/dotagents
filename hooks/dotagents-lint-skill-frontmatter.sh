#!/usr/bin/env bash
# preToolUse hook. Catches broken SKILL.md frontmatter before it lands.
#
# A skill with a missing `description` still appears in the menu; it just never gets chosen
# automatically, and nothing says why. A skill with `disable-model-invocation` silently stops
# being callable from other skills. Both are cheap to catch here and expensive to notice later.
#
# Runs on both agents. They disagree on the reply format:
#
#   Claude Code  {"hookSpecificOutput": {"hookEventName": "PreToolUse",
#                                        "permissionDecision": "deny"|"ask", ...}}
#   Cursor       {"permission": "deny"|"ask", "user_message": ..., "agent_message": ...}
#
# Detected by `hook_event_name`, which only Claude Code sends.

set -uo pipefail

read -r -d '' LINTER <<'NODE' || true
let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let ev;
  try { ev = JSON.parse(raw); } catch { return process.stdout.write("{}"); }

  const cursor = !("hook_event_name" in ev);

  const emit = (o) => process.stdout.write(JSON.stringify(o));
  const allow = () => emit({});
  const decide = (decision, reason) =>
    emit(cursor
      ? { permission: decision, user_message: `[dotagents] SKILL.md ${decision}`,
          agent_message: `[dotagents] ${reason}` }
      : { hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision,
                                permissionDecisionReason: `[dotagents] ${reason}` } });
  const deny = (r) => decide("deny", r);
  // Allowed, but with something said. This used to be `ask`, which waits for a human -- so any
  // unattended run that wrote a SKILL.md with a weak description stalled on a permission prompt.
  // This hook only inspects; the one that is allowed to stop a turn is the Stop gate. Anything that
  // is genuinely broken is denied below, and everything else is a warning.
  const warn = (r) => decide("allow", r);

  const input = ev.tool_input || {};

  // Tool names differ between agents and across versions, so key off the payload shape instead:
  // any field that looks like a path to a SKILL.md, and any field that looks like its content.
  const path = input.file_path ?? input.path ?? input.filePath ?? input.target_file ?? "";
  if (!/(^|\/)SKILL\.md$/.test(String(path))) return allow();

  // Write carries the whole file. Edit carries a fragment, so we can only judge it when the
  // fragment itself contains the frontmatter block.
  const content = String(
    input.content ?? input.new_string ?? input.newString ?? input.contents ??
    (Array.isArray(input.edits) ? input.edits.map((e) => e.new_string ?? "").join("\n") : ""),
  );
  if (!content.trimStart().startsWith("---")) return allow();

  const m = content.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return deny("SKILL.md starts with '---' but the frontmatter block is never closed.");

  const fm = m[1];
  const key = (k) => {
    const hit = fm.match(new RegExp(`^${k}\\s*:\\s*(.*)$`, "m"));
    return hit ? hit[1].trim() : null;
  };

  if (!key("name")) return deny("SKILL.md frontmatter is missing 'name'.");

  const desc = key("description");
  if (!desc) {
    return deny(
      "SKILL.md frontmatter is missing 'description'. Without it the skill is never selected " +
      "automatically -- it will sit in the menu looking installed and never fire.",
    );
  }

  // `disable-model-invocation` is officially the right spelling for a user-invoked workflow, and it
  // costs zero description budget. It is only wrong where something reaches this skill *by name*,
  // because it also blocks programmatic Skill calls and subagent preloading -- silently.
  if (/^disable-model-invocation\s*:\s*(true|yes|on|1)\s*$/m.test(fm)) {
    const name = key("name") ?? String(path).replace(/.*\/([^/]+)\/SKILL\.md$/, "$1");

    // Declared as data so the list has one home per file. scripts/verify-skills.sh reads these two
    // lines and asserts its own copies match, which is why the marker comments are load-bearing: the
    // cross-check that exists to catch a rename was itself hardcoded to the `da-` prefix, so the
    // x-review-* names below were unguarded while it printed a green tick.
    const DMI_GATE = ["da-verify"];                                                  // dotagents:dmi-gate
    const DMI_DISPATCH = ["x-review-backend", "x-review-frontend", "x-review-infra"]; // dotagents:dmi-dispatch

    // /da-verify is the only thing in the toolkit that runs `gate.sh arm`. Without its auto-invocation
    // the Stop gate never arms, so it passes every turn: the guardrail opens instead of closing.
    if (DMI_GATE.includes(name)) {
      return deny(
        "Never set 'disable-model-invocation' on 'verify'. It is the only thing that runs " +
        "'gate.sh arm', so disabling auto-invocation leaves the Stop gate unarmed and it passes " +
        "every turn -- the guardrail fails OPEN with nothing reported. See docs/decisions.md.",
      );
    }

    // da-review-all dispatches to these by name via a subagent.
    if (DMI_DISPATCH.includes(name)) {
      return deny(
        `'${name}' is a by-name dispatch target of da-review-all, and ` +
        "'disable-model-invocation' blocks programmatic Skill calls and subagent preloading too. " +
        "Setting it makes da-review-all report that layer as covered while reviewing nothing, with " +
        "no error. See docs/decisions.md.",
      );
    }

    // Anything else may set it. Warn about the cost, because it is easy to set on a skill you later
    // want another skill to call.
    return warn(
      `'${name}' will become user-invocable only: its description leaves Claude's context ` +
      "entirely (zero budget cost), it will never fire automatically, and no other skill or " +
      "subagent can reach it by name. Correct for side-effectful workflows you always type " +
      "yourself. Wrong if anything dispatches to it by name.",
    );
  }

  // A description with no sense of *when* to use the skill cannot be matched against a request.
  // dotagents:when-clause-tokens use (this|it|when)|when |after |before |時|する場合
  // Kept identical to the list in scripts/verify-skills.sh, which verify-skills.sh itself checks.
  // They disagreed: the linter accepted a Japanese clause and this hook did not, so a Japanese
  // description passed the lint and then met a permission prompt from the hook.
  if (!/use (this|it|when)|when |after |before |時|する場合/i.test(desc)) {
    return warn(
      "This description says what the skill does but not when to use it, so auto-invocation " +
      "will be unreliable. Add a clause naming the situations that should trigger it " +
      '("use when ..."), unless it is meant to be invoked only by name.',
    );
  }

  allow();
});
NODE

# Read through an explicit descriptor rather than bare stdin. With fd 0 closed, bash hands the lowest
# free descriptor to the next pipe it builds -- fd 0 -- and a reader then blocks on its own output
# pipe. The gate hook hung exactly that way. Here the consequence is a stalled Write rather than a gate
# that fails open, but a hook that can hang is a hook that can stop an unattended run either way.
# Probed in a subshell: `exec` with a redirection and no command applies it to the shell for good, so
# testing with `exec 3<&0 2>/dev/null` would silence this hook's own stderr from then on.
if ( exec 3<&0 ) 2>/dev/null; then exec 3<&0; else exec 3</dev/null; fi

# A hook that crashes must not block ordinary edits, so anything unexpected falls through open.
# This one only inspects; the gate that must fail closed is dotagents-verify-gate.sh.
node -e "$LINTER" <&3 2>/dev/null || true
exec 3<&-
exit 0
