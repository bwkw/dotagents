#!/usr/bin/env bash
# Status line. Opt-in -- see README.
#
# Shows the four things that change a decision mid-session:
#   context %   when to /clear or /compact, which this toolkit is largely about
#   worktree    which checkout you are actually in, when several are open
#   branch      what the verify gate will diff against
#   cost        what the session has spent
#
# Claude Code passes a JSON blob on stdin and prints whatever comes back on stdout. Field names
# vary across versions, so every field is optional and missing ones are simply left out rather
# than rendered as "unknown" -- a status line that lies is worse than a short one.

set -uo pipefail

node -e '
let raw = "";
process.stdin.on("data", (d) => (raw += d));
process.stdin.on("end", () => {
  let s = {};
  try { s = JSON.parse(raw); } catch { return; }

  const dim = (t) => `\x1b[2m${t}\x1b[0m`;
  const parts = [];

  // Context. The one number worth interrupting yourself for.
  const pct =
    s.context_window?.used_percentage ??
    s.context?.used_percentage ??
    s.contextWindow?.usedPercentage;
  if (typeof pct === "number") {
    const p = Math.round(pct);
    // Green under half, yellow past two thirds, red past 85 -- the point where quality degrades
    // noticeably and starting fresh beats pushing on.
    const colour = p >= 85 ? 31 : p >= 67 ? 33 : 32;
    parts.push(`\x1b[${colour}mctx ${p}%\x1b[0m`);
  }

  const model = s.model?.display_name ?? s.model?.id ?? s.model;
  if (typeof model === "string" && model) parts.push(dim(model));

  // A worktree is worth showing precisely because it is easy to forget which one you are in.
  const wt = s.workspace?.git_worktree ?? s.workspace?.gitWorktree;
  if (typeof wt === "string" && wt) {
    const name = wt.replace(/\/+$/, "").split("/").pop();
    if (name) parts.push(`\x1b[35m⑂ ${name}\x1b[0m`);
  }

  const branch = s.workspace?.git_branch ?? s.workspace?.branch ?? s.git?.branch;
  if (typeof branch === "string" && branch) parts.push(dim(branch));

  const cost = s.cost?.total_cost_usd ?? s.cost?.totalCostUsd;
  if (typeof cost === "number" && cost > 0) parts.push(dim(`$${cost.toFixed(2)}`));

  const style = s.output_style?.name ?? s.outputStyle?.name;
  if (typeof style === "string" && style && style !== "default") parts.push(dim(`[${style}]`));

  if (parts.length) process.stdout.write(parts.join(dim("  ·  ")));
});
' 2>/dev/null || true
exit 0
