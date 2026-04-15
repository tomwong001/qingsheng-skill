#!/usr/bin/env bash
# build-skill.sh — build qingsheng-skill.skill for Claude Cowork upload
# Usage: bash build-skill.sh
# Output: qingsheng-skill.skill (zip with SKILL.md at top level)

set -euo pipefail

VERSION=$(cat VERSION 2>/dev/null | tr -d '[:space:]')
OUT="qingsheng-skill.skill"

echo "→ Building $OUT (v$VERSION)..."

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

# Cowork requires SKILL.md at top level
cp skill/SKILL.md "$TMP/SKILL.md"
cp -r skill/references "$TMP/references"

# Include upgrade skill
cp skill/qingsheng-upgrade.md "$TMP/qingsheng-upgrade.md" 2>/dev/null || true

# Build zip
(cd "$TMP" && zip -r - .) > "$OUT"

echo "✅ $OUT ready ($(du -h "$OUT" | cut -f1))"
echo "   Upload to Claude Cowork → Customize tab"
