#!/usr/bin/env bash
# Tile every scene still into one contact sheet for review — a strip of
# thumbnails is how a human catches the one off-model frame in seconds.
#
#   contact_sheet.sh <ad-folder>
set -euo pipefail

DIR="$1"

# Collect scene stills in numeric order using the SHELL's glob, not ffmpeg's.
# ffmpeg -pattern_type glob is unavailable on common Windows builds ("globbing
# is not supported by this libavformat build", exit 127), which made this script
# fail outright there. Staging sequentially-numbered copies lets us feed the
# image2 demuxer a %03d pattern instead, which every build supports.
STILLS=()
for F in "$DIR"/stills/scene-[0-9][0-9].png; do
  [ -e "$F" ] && STILLS+=("$F")
done
COUNT=${#STILLS[@]}
[ "$COUNT" -gt 0 ] || { echo "No stills in $DIR/stills yet." >&2; exit 1; }

# Stage inside the ad folder, not mktemp: under Git Bash mktemp returns a POSIX
# path (/tmp/...) that native ffmpeg.exe cannot open. Paths handed to ffmpeg
# must stay in whatever form the caller used for "$DIR".
STAGE="$DIR/.contact"
rm -rf "$STAGE"; mkdir -p "$STAGE"
trap 'rm -rf "$STAGE"' EXIT
i=1
for F in "${STILLS[@]}"; do
  cp "$F" "$(printf '%s/img-%03d.png' "$STAGE" "$i")"
  i=$((i + 1))
done

COLS=$(( COUNT >= 5 ? 5 : COUNT ))
ROWS=$(( (COUNT + COLS - 1) / COLS ))
ffmpeg -y -v error -start_number 1 -i "$STAGE/img-%03d.png" \
  -filter_complex "scale=270:480,tile=${COLS}x${ROWS}:padding=8:color=white" \
  -frames:v 1 "$DIR/contact-sheet.png"
echo "$DIR/contact-sheet.png"
