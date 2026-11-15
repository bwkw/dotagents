#!/usr/bin/env bash
# 評価器の故障検出と証拠保持を、本物の git・ゲート・hook を通して確かめる。
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --test "$REPO/scripts/test-verification-evidence.mjs"
