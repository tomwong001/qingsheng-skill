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

# Include all subcommand skill files (qingsheng-upgrade, 换一个, 急, etc.)
for f in skill/*.md; do
  fname=$(basename "$f")
  [[ "$fname" == "SKILL.md" ]] && continue  # already copied above
  cp "$f" "$TMP/$fname"
done

# Build zip (use Python for proper UTF-8 filename support)
python3 - "$TMP" "$OUT" <<'PYEOF'
import sys, zipfile, os, pathlib
src = pathlib.Path(sys.argv[1])
out = sys.argv[2]
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, allowZip64=True) as zf:
    for f in src.rglob('*'):
        if f.is_file():
            zf.write(f, f.relative_to(src))
PYEOF

echo "✅ $OUT ready ($(du -h "$OUT" | cut -f1))"
echo "   Upload to Claude Cowork → Customize tab"
