#!/usr/bin/env bash
# The halt reasons in `scripts/loop.sh` and the tables in `docs/loops.md` must be the same set.
#
#   scripts/verify-halt-docs.sh
#
# Written because they were NOT the same set, silently, for seven values: the driver stopped a run with
# `ci_pending` or `isolate_round_failed` and the table a human is sent to did not have the row. Nothing
# failed -- a table cannot be out of date in a way a linter notices, unless a linter looks. The landing
# that added the seven rows fixed the symptom; this file is what makes the next `halt` unable to repeat it.
#
# Three assertions, because there are three ways the two can disagree:
#
#   1. Nothing the driver can emit is missing from the tables. This is the one that was broken.
#   2. No row describes something the driver cannot emit. `review_cap` is exactly that today -- kept on
#      purpose, because old ledger rows still carry it -- so the exception is DECLARED as data rather
#      than tolerated, and the declaration is checked against reality too.
#   3. The reasons that never reach the ledger are marked as such. `halt()` writes stderr and sets HALT;
#      only `record()`'s fifth argument puts a value in the ledger's `halt_reason`. Four reasons stop a
#      run without ever being recorded, so a reader who takes the heading literally goes to the ledger
#      and finds nothing. A new one of those must say so in the table, not be discovered later.
#
# The declarations live on marker lines in `docs/loops.md` -- the pattern `AGENTS.md` invariant 7 uses:
# the list is data in one place, and this script drives its behaviour from it. Removing a marker is not
# a way to pass; a missing marker is an error.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO}" || exit 1

LOOP="scripts/loop.sh"
DOC="docs/loops.md"
fails=0
err() { printf '\033[31m✗\033[0m %s\n' "$*"; fails=$((fails + 1)); }
ok() { printf '\033[32m✓\033[0m %s\n' "$*"; }

for f in "$LOOP" "$DOC"; do
  [[ -f "$f" ]] || { err "$f is missing"; exit 1; }
done

# --- what the driver can emit ------------------------------------------------------------------
# Comment lines are excluded: this file's own prose names half of these values, and so do loop.sh's
# comments. A grep that counts a comment is the failure mode this whole script exists to prevent.
node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n").filter((l) => !/^\s*#/.test(l));
  const src = lines.join("\n");
  const halted = new Set([...src.matchAll(/record\s+\S+[^\n]*?halted ([a-z_]+)/g)].map((m) => m[1]));
  const emitted = new Set([...src.matchAll(/^\s*halt ([a-z_]+)[\s"]/gm)].map((m) => m[1]));
  const stderrOnly = [...emitted].filter((r) => !halted.has(r)).sort();
  const all = [...new Set([...halted, ...emitted])].sort();
  process.stdout.write(JSON.stringify({ all, stderrOnly }));
' "$LOOP" > /tmp/.halt-sets.$$ || { err "could not read the halt reasons out of $LOOP"; exit 1; }

read -r ALL STDERR_ONLY < <(node -e '
  const s = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
  process.stdout.write(s.all.join(",") + " " + (s.stderrOnly.join(",") || "-"));
' "/tmp/.halt-sets.$$")
rm -f "/tmp/.halt-sets.$$"

# --- what the tables document -----------------------------------------------------------------
# Scoped to the tables that a `dotagents:halt-table` marker introduces, and NOT to every table row in
# the file. The first attempt read `^| \`name\`` across the whole document and reported six phantom
# reasons -- `size`, `unverified`, `claude` -- which are rows of other tables entirely. A check that
# cries wolf gets deleted, so the scope is declared rather than guessed. The first cell can hold more
# than one reason (`one_way` / `pr_cap` share a row), and every name in it counts: taking only the first
# reported `pr_cap` as undocumented when its row was right there.
DOCUMENTED="$(node -e '
  const fs = require("fs");
  const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
  const names = new Set();
  // `pending` exists because the marker and the table are separated by a blank line in Markdown, and
  // treating that blank line as the end of the table found zero rows while reporting every reason as
  // undocumented -- a check that fails loudly for the wrong reason is still a broken check.
  let inTable = false, pending = false;
  for (const line of lines) {
    if (line.includes("dotagents:halt-table")) { pending = true; continue; }
    if (pending) {
      if (line.trim() === "") continue;
      if (!line.startsWith("|")) { pending = false; continue; }
      pending = false; inTable = true;
    }
    if (!inTable) continue;
    if (!line.startsWith("|")) { inTable = false; continue; }
    const cell = line.slice(1).split("|")[0];
    for (const m of cell.matchAll(/`([a-z_]+)`/g)) names.add(m[1]);
  }
  process.stdout.write([...names].sort().join(","));
' "$DOC")"
[[ -n "$DOCUMENTED" ]] || err "no table in $DOC is marked with '<!-- dotagents:halt-table -->' -- with no scope declared, this check has nothing to compare against"

marker() { # <marker-name> -- the declared list, or the empty string when the line is absent
  grep -oE "<!-- dotagents:$1[^>]*-->" "$DOC" | head -1 \
    | sed -E "s/<!-- dotagents:$1 *//; s/ *-->//" | tr -s ' ' ',' | sed 's/^,//; s/,$//'
}
HISTORICAL_LINE="$(grep -c "dotagents:halt-historical" "$DOC")"
STDERR_LINE="$(grep -c "dotagents:halt-stderr-only" "$DOC")"
HISTORICAL="$(marker halt-historical)"
DECLARED_STDERR="$(marker halt-stderr-only)"

# The markers are load-bearing: with the line gone, assertions 2 and 3 would compare against nothing
# and print a green tick. `AGENTS.md` invariant 7 records the same trap being sprung for real.
(( HISTORICAL_LINE >= 1 )) || err "$DOC has no '<!-- dotagents:halt-historical ... -->' line -- without it, a row for a reason the driver can no longer emit passes unnoticed"
(( STDERR_LINE >= 1 )) || err "$DOC has no '<!-- dotagents:halt-stderr-only ... -->' line -- without it, a reason that never reaches the ledger is documented as one that does"

list_diff() { # <csv-a> <csv-b> -> members of a that are not in b
  node -e '
    const a = (process.argv[1] || "").split(",").filter((x) => x && x !== "-");
    const b = new Set((process.argv[2] || "").split(",").filter(Boolean));
    process.stdout.write(a.filter((x) => !b.has(x)).join(" "));
  ' "$1" "$2"
}

# 1. Nothing the driver can emit is undocumented.
missing="$(list_diff "$ALL" "$DOCUMENTED")"
if [[ -z "$missing" ]]; then
  ok "every halt reason the driver can emit has a row in $DOC"
else
  err "these halt reasons have no row in $DOC: $missing"
fi

# 2. No row invents a reason -- except the ones declared as kept for the ledger's old rows.
phantom="$(list_diff "$DOCUMENTED" "$ALL,$HISTORICAL")"
if [[ -z "$phantom" ]]; then
  ok "no row describes a stop the driver cannot produce (declared historical: ${HISTORICAL:-none})"
else
  err "these rows describe reasons $LOOP never emits, and are not declared historical: $phantom"
fi

# 2b. And the declaration is checked against reality: a reason that came BACK must lose the exception,
#     or the table would keep telling a reader it cannot happen while it can.
stale_historical="$(node -e '
  const declared = (process.argv[1] || "").split(",").filter(Boolean);
  const all = new Set((process.argv[2] || "").split(",").filter(Boolean));
  process.stdout.write(declared.filter((x) => all.has(x)).join(" "));
' "$HISTORICAL" "$ALL")"
if [[ -z "$stale_historical" ]]; then
  ok "the historical declaration still describes reasons that cannot happen"
else
  err "declared historical, but $LOOP emits them again: $stale_historical"
fi

# 3. The reasons that stop a run without reaching the ledger are exactly the declared ones.
if [[ "$(list_diff "$STDERR_ONLY" "$DECLARED_STDERR")" == "" \
   && "$(list_diff "$DECLARED_STDERR" "$STDERR_ONLY")" == "" ]]; then
  ok "the reasons that never reach the ledger are declared and accurate (${STDERR_ONLY//,/ })"
else
  err "the ledger-less reasons and the declaration disagree.
    $LOOP halts without recording: ${STDERR_ONLY//,/ }
    $DOC declares:                 ${DECLARED_STDERR//,/ }"
fi

echo
if (( fails )); then
  printf '\033[31m%d failed\033[0m\n' "$fails"
  exit 1
fi
printf '\033[32m✓ %s and %s agree on every halt reason\033[0m\n' "$LOOP" "$DOC"
