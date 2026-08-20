#!/usr/bin/env bash
# Generate one narration line's audio and record its measured duration.
#
#   tts_line.sh <ad-folder> <scene-number> <payload.json> <fal-tts-model-id>
#
# Uses ELEVENLABS_API_KEY directly when set (required for the user's own voice
# clones — FAL's ElevenLabs runs on FAL's account, so clones don't resolve
# there). Otherwise goes through FAL with fal_run.sh. Appends the real audio
# duration to vo/durations.json — assembly trims every clip to these numbers,
# which is why the final cuts land exactly on the narration.
set -euo pipefail

DIR="$1"; SCENE="$2"; PAYLOAD="$3"; MODEL="${4:-}"
mkdir -p "$DIR/vo"
OUT="$DIR/vo/line-$(printf '%02d' "$SCENE").mp3"

if [ -n "${ELEVENLABS_API_KEY:-}" ] && [ -n "${ELEVENLABS_VOICE_ID:-}" ]; then
  TEXT=$(jq -r '.text' "$PAYLOAD")
  curl -sS -o "$OUT" -X POST "https://api.elevenlabs.io/v1/text-to-speech/$ELEVENLABS_VOICE_ID" \
    -H "xi-api-key: $ELEVENLABS_API_KEY" -H "Content-Type: application/json" \
    -d "{\"text\": $(jq -n --arg t "$TEXT" '$t'), \"model_id\": \"${ELEVENLABS_MODEL_ID:-eleven_v3}\"}"
else
  [ -n "$MODEL" ] || { echo "No ELEVENLABS_API_KEY set and no FAL TTS model id given." >&2; exit 1; }
  # bash-invoke so this works even when provisioning strips the executable bit
  bash "$(dirname "$0")/fal_run.sh" "$MODEL" "$PAYLOAD" "$OUT" > /dev/null
fi

DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$OUT")
DURATIONS="$DIR/vo/durations.json"
[ -f "$DURATIONS" ] || echo '{}' > "$DURATIONS"
jq --arg s "$SCENE" --argjson d "$DUR" '.[$s] = $d' "$DURATIONS" > "$DURATIONS.tmp" && mv "$DURATIONS.tmp" "$DURATIONS"
echo "line $SCENE: ${DUR}s -> $OUT"
