#!/usr/bin/env bash
# Ensures da-review-all always produces the standalone review artifact expected by Cursor users.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SKILL="$REPO/skills/da-review-all/SKILL.md"
REFERENCE="$REPO/skills/da-review-all/reference/canvas-review-summary.md"

require_skill() {
  local pattern="$1"
  local explanation="$2"

  if ! grep -qF "$pattern" "$SKILL"; then
    printf 'missing required da-review-all canvas instruction: %s\n' "$explanation" >&2
    exit 1
  fi
}

require_reference() {
  local pattern="$1"
  local explanation="$2"

  if ! grep -qF "$pattern" "$REFERENCE"; then
    printf 'missing required Canvas reference instruction: %s\n' "$explanation" >&2
    exit 1
  fi
}

require_skill "## Step 5. One-page Canvas review summary" "dedicated Canvas output step"
require_skill "use the \`canvas\` skill" "Canvas authoring workflow"
require_skill "must create exactly one Canvas" "mandatory single-artifact output"
require_skill "canvas-review-summary.md" "required Canvas content reference"
require_skill "must link the Canvas" "user-facing Canvas link"
require_reference "change summary" "change content in the artifact"
require_reference "review result" "review result in the artifact"

printf '✓ da-review-all requires a one-page Canvas summary\n'
