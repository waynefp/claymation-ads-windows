#!/usr/bin/env bash
# Assemble the final ad: trim each clip to its line's MEASURED voiceover
# duration, mux the narration, concat, loudness-normalize. Free to re-run.
#
#   assemble.sh <ad-folder> [music-bed.mp3]
#
# Timing model: clip K animates scene K into scene K+1 and carries line K's
# narration. The last line plays over a hold of the final still. Because every
# duration comes from ffprobe on the actual audio (vo/durations.json), cuts
# land exactly on the narration — no stretching, no drift, no alignment API.
set -euo pipefail

DIR="$1"; MUSIC="${2:-}"
DURATIONS="$DIR/vo/durations.json"
[ -f "$DURATIONS" ] || { echo "Missing $DURATIONS — run tts_line.sh for every line first." >&2; exit 1; }

WORK="$DIR/.assembly"; rm -rf "$WORK"; mkdir -p "$WORK"
N=$(jq 'keys | length' "$DURATIONS")
ENC=(-c:v libx264 -pix_fmt yuv420p -r 24 -c:a aac -ar 48000 -ac 2)

for K in $(seq 1 "$N"); do
  D=$(jq -r --arg s "$K" '.[$s]' "$DURATIONS")
  PAD=$(printf '%02d' "$K")
  AUDIO="$DIR/vo/line-$PAD.mp3"
  SEG="$WORK/seg-$PAD.mp4"
  if [ "$K" -lt "$N" ] || [ -f "$DIR/clips/clip-$PAD.mp4" ]; then
    # Clip K: freeze-extend far past need, then trim to the line's length —
    # one filter handles both a clip longer and shorter than its narration.
    # -map is load-bearing: omni clips ship their own AAC track, and without
    # explicit mapping ffmpeg picks it over the narration (VO silently lost).
    ffmpeg -y -v error -i "$DIR/clips/clip-$PAD.mp4" -i "$AUDIO" \
      -map 0:v:0 -map 1:a:0 \
      -vf "tpad=stop_mode=clone:stop_duration=30,trim=duration=$D,setpts=PTS-STARTPTS,scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2" \
      -af "apad,atrim=duration=$D" "${ENC[@]}" -shortest "$SEG"
  else
    # Final line, no outro clip: hold the last still for its narration.
    # A held still reads as a rendering glitch to clients — prefer generating
    # an outro clip N (see SKILL.md gate 5) so this branch is the fallback.
    STILL=$(ls "$DIR/stills"/scene-*.png | sort | tail -1)
    ffmpeg -y -v error -loop 1 -i "$STILL" -i "$AUDIO" \
      -map 0:v:0 -map 1:a:0 \
      -vf "scale=720:1280:force_original_aspect_ratio=decrease,pad=720:1280:(ow-iw)/2:(oh-ih)/2" \
      -af "apad,atrim=duration=$D" -t "$D" "${ENC[@]}" "$SEG"
  fi
done

# Segments live beside concat.txt, and the concat demuxer resolves relative
# entries against the LIST FILE's own directory — so bare basenames are correct
# on every platform. Do not reintroduce $PWD here: under Git Bash on Windows it
# expands to a POSIX path (/c/Users/...) that the native ffmpeg.exe cannot open,
# and the concat step dies with "Impossible to open".
for F in "$WORK"/seg-*.mp4; do echo "file '$(basename "$F")'"; done > "$WORK/concat.txt"
ffmpeg -y -v error -f concat -safe 0 -i "$WORK/concat.txt" -c copy "$WORK/joined.mp4"

if [ -n "$MUSIC" ]; then
  # Loop the bed under the ad, duck it beneath the narration, then normalize.
  ffmpeg -y -v error -i "$WORK/joined.mp4" -stream_loop -1 -i "$MUSIC" \
    -filter_complex "[1:a]volume=0.5[bed];[bed][0:a]sidechaincompress=threshold=0.05:ratio=8:attack=20:release=400[ducked];[0:a][ducked]amix=inputs=2:duration=first:dropout_transition=2,loudnorm=I=-14:TP=-1.5:LRA=11[a]" \
    -map 0:v -map "[a]" -c:v copy -c:a aac -ar 48000 "$DIR/final.mp4"
else
  ffmpeg -y -v error -i "$WORK/joined.mp4" -af "loudnorm=I=-14:TP=-1.5:LRA=11" \
    -c:v copy -c:a aac -ar 48000 "$DIR/final.mp4"
fi

echo "Assembled: $DIR/final.mp4 ($(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$DIR/final.mp4")s)"
