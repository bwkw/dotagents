#!/usr/bin/env bash
# Ensures da-review-all still produces the standalone one-page overview, in whichever container the
# host supports. This replaces test-da-review-all-canvas.sh: the step used to be Cursor-only and
# named Canvas, which made it a silent no-op in Claude Code — the run said "Canvas unavailable" and
# shipped no page at all. The container is now chosen per host; the six sections are not.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skills/da-review-all/SKILL.md"
REFERENCE="$REPO/skills/da-review-all/reference/overview-artifact.md"

require() {
  local file="$1" pattern="$2" explanation="$3"
  if ! grep -qF "$pattern" "$file"; then
    printf 'missing required da-review-all overview instruction: %s\n' "$explanation" >&2
    exit 1
  fi
}

# The step exists in the skill and points at the reference.
require "$SKILL" "## Step 5. The one-page overview" "dedicated overview output step"
require "$SKILL" "overview-artifact.md" "required overview content reference"
require "$SKILL" "Artifact in Claude Code, Canvas" "host-dependent container"

# Every container is named, so no host silently produces nothing.
require "$REFERENCE" "Claude Code" "Claude Code container named"
require "$REFERENCE" "Cursor" "Cursor container named"
require "$REFERENCE" "Neither available" "fallback when neither exists"

# The page is about the change, and carries the honesty rows the layer reports no longer print.
require "$REFERENCE" "何ができるようになったか" "what the change enables"
require "$REFERENCE" "既存との関係" "relationship to what already exists"
require "$REFERENCE" "決まっていないこと" "the decisions sweep lands on the page"
require "$REFERENCE" "🔎" "what was read versus assumed"
require "$REFERENCE" "🔬" "what was excluded, so the selection stays auditable"

printf '✓ da-review-all requires a one-page overview in this host'"'"'s container\n'
