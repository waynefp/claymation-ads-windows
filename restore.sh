#!/usr/bin/env bash
# Restore the Windows-patched claymation-ads skill over the installed copy.
#
#   bash restore.sh            # restore patched files into ~/.claude/skills
#   bash restore.sh --check    # report drift only, change nothing
#
# Run this after re-installing claymation-ads from upstream, which overwrites
# ~/.claude/skills/claymation-ads and wipes the Windows fixes.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/claymation-ads"
DST="${CLAUDE_SKILLS_DIR:-$HOME/.claude/skills}/claymation-ads"

[ -d "$SRC" ] || { echo "Backup source missing: $SRC" >&2; exit 1; }

if [ "${1:-}" = "--check" ]; then
  [ -d "$DST" ] || { echo "Not installed at $DST"; exit 1; }
  if diff -r --strip-trailing-cr -q "$SRC" "$DST" >/dev/null 2>&1; then
    echo "In sync — installed skill matches this backup."
  else
    echo "DRIFT — installed skill differs from this backup:"
    diff -r --strip-trailing-cr -q "$SRC" "$DST" || true
    echo
    echo "Run 'bash restore.sh' to restore the patched version."
  fi
  exit 0
fi

mkdir -p "$(dirname "$DST")"
if [ -d "$DST" ]; then
  STAMP=$(date +%Y%m%d-%H%M%S)
  mv "$DST" "$DST.replaced-$STAMP"
  echo "Existing install moved aside: $DST.replaced-$STAMP"
fi
cp -r "$SRC" "$DST"
echo "Restored patched skill to $DST"
