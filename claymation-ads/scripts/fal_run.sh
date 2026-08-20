#!/usr/bin/env bash
# FAL queue client. The queue is server-side: once submitted, a job survives
# tool-call timeouts, killed shells, and reaped background processes — so
# NEVER nohup/background this script. Submit, let the tool call end, poll in
# a later call.
#
#   fal_run.sh --upload <local-file>                      # print public URL for reference inputs
#   fal_run.sh submit <model-id> <payload.json> <job-name> <state-dir>
#   fal_run.sh poll   <job-name> <state-dir> <output-file> [max-wait-seconds]
#   fal_run.sh <model-id> <payload.json> <output-file>    # one-shot (fast jobs only, e.g. TTS)
#
# poll exit codes: 0 done (file downloaded) · 2 still running (call again) · 1 failed
# Requires: FAL_KEY, curl, jq.
set -euo pipefail

[ -n "${FAL_KEY:-}" ] || { echo "FAL_KEY is not set. Get one at fal.ai/dashboard/keys and: export FAL_KEY=..." >&2; exit 1; }
AUTH="Authorization: Key $FAL_KEY"

download_result() { # $1 response_url  $2 out
  local RESULT FILE_URL
  RESULT=$(curl -sS "$1" -H "$AUTH")
  FILE_URL=$(echo "$RESULT" | jq -r '.images[0].url // .image.url // .video.url // .audio.url // .audio_url // empty')
  [ -n "$FILE_URL" ] || { echo "No output URL in result: $RESULT" >&2; return 1; }
  curl -sS -o "$2" "$FILE_URL"
  echo "$2"
}

case "${1:-}" in
  --upload)
    FILE="$2"
    [ -f "$FILE" ] || { echo "No such file: $FILE" >&2; exit 1; }
    MIME=$(file -b --mime-type "$FILE")
    INIT=$(curl -sS -X POST "https://rest.alpha.fal.ai/storage/upload/initiate" \
      -H "$AUTH" -H "Content-Type: application/json" \
      -d "{\"file_name\": \"$(basename "$FILE")\", \"content_type\": \"$MIME\"}")
    UPLOAD_URL=$(echo "$INIT" | jq -r '.upload_url'); FILE_URL=$(echo "$INIT" | jq -r '.file_url')
    [ "$UPLOAD_URL" != "null" ] || { echo "Upload initiate failed: $INIT" >&2; exit 1; }
    curl -sS -X PUT "$UPLOAD_URL" -H "Content-Type: $MIME" --data-binary "@$FILE" > /dev/null
    echo "$FILE_URL"
    ;;

  submit)
    MODEL="$2"; PAYLOAD="$3"; NAME="$4"; STATE="$5"
    mkdir -p "$STATE"
    SUBMIT=$(curl -sS -X POST "https://queue.fal.run/$MODEL" \
      -H "$AUTH" -H "Content-Type: application/json" -d @"$PAYLOAD")
    [ "$(echo "$SUBMIT" | jq -r '.status_url')" != "null" ] || { echo "Submit failed: $SUBMIT" >&2; exit 1; }
    echo "$SUBMIT" | jq --arg m "$MODEL" '. + {model: $m}' > "$STATE/$NAME.json"
    echo "submitted $NAME ($(echo "$SUBMIT" | jq -r '.request_id')) — poll with: fal_run.sh poll $NAME $STATE <out>"
    ;;

  poll)
    NAME="$2"; STATE="$3"; OUT="$4"; MAX_WAIT="${5:-90}"
    JOB="$STATE/$NAME.json"
    [ -f "$JOB" ] || { echo "No submitted job named $NAME in $STATE." >&2; exit 1; }
    STATUS_URL=$(jq -r '.status_url' "$JOB"); RESPONSE_URL=$(jq -r '.response_url' "$JOB")
    ELAPSED=0
    while :; do
      STATE_NOW=$(curl -sS "$STATUS_URL" -H "$AUTH" | jq -r '.status')
      case "$STATE_NOW" in
        COMPLETED) download_result "$RESPONSE_URL" "$OUT"; exit 0 ;;
        FAILED|CANCELLED) echo "Job $NAME $STATE_NOW. Check the model page for schema changes." >&2; exit 1 ;;
      esac
      if [ "$ELAPSED" -ge "$MAX_WAIT" ]; then echo "$NAME still $STATE_NOW after ${ELAPSED}s — call poll again."; exit 2; fi
      sleep 5; ELAPSED=$((ELAPSED + 5))
    done
    ;;

  *)
    # One-shot: submit + poll inline. Safe only for fast jobs (TTS, uploads);
    # image and video generations belong on the submit/poll path.
    MODEL="$1"; PAYLOAD="$2"; OUT="$3"
    TMPSTATE=$(mktemp -d)
    "$0" submit "$MODEL" "$PAYLOAD" oneshot "$TMPSTATE" > /dev/null
    while :; do
      set +e; "$0" poll oneshot "$TMPSTATE" "$OUT" 60; RC=$?; set -e
      case $RC in 0) break ;; 2) continue ;; *) exit "$RC" ;; esac
    done
    ;;
esac
