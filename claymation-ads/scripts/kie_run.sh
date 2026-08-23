#!/usr/bin/env bash
# Kie.ai queue client with retry handling. Mirrors fal_run.sh's interface.
#
#   kie_run.sh credits
#   kie_run.sh submit <model> <input.json> <job-name> <state-dir>
#   kie_run.sh poll   <job-name> <state-dir> <out-file> [max-wait-seconds]
#   kie_run.sh run    <model> <input.json> <job-name> <state-dir> <out-file> [max-wait]
#   kie_run.sh status <job-name> <state-dir>
#
# <input.json> holds ONLY the `input` object; the model is passed separately.
#
# poll exit codes: 0 done (downloaded) · 2 still running (call again) · 1 failed
# run  exit codes: 0 done · 1 failed after retry · 3 STUCK (needs a human decision)
#
# Requires: KIE_API_KEY, curl, jq.
set -euo pipefail

API="https://api.kie.ai/api/v1"
[ -n "${KIE_API_KEY:-}" ] || { echo "KIE_API_KEY is not set. Get one at kie.ai and: export KIE_API_KEY=..." >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required but not on PATH." >&2; exit 1; }
AUTH="Authorization: Bearer $KIE_API_KEY"

# Kie allows 20 new generation requests per 10s. A 429 is NOT a failure and NOT a
# missing model — it means slow down. Back off and retry the HTTP call itself.
api() { # $1 method  $2 path  [$3 body]
  local method="$1" path="$2" body="${3:-}" try=0 resp
  while :; do
    if [ -n "$body" ]; then
      resp=$(curl -sS -X "$method" "$API$path" -H "$AUTH" -H "Content-Type: application/json" -d "$body")
    else
      resp=$(curl -sS -X "$method" "$API$path" -H "$AUTH")
    fi
    case "$resp" in
      *"frequency is too high"*)
        try=$((try + 1))
        [ "$try" -ge 6 ] && { echo "$resp"; return 0; }
        sleep $((try * 5))
        ;;
      *) echo "$resp"; return 0 ;;
    esac
  done
}

credits() { api GET "/chat/credit" | jq -r '.data'; }

# Submit one job. Writes state BEFORE returning, because Kie has no task-list
# endpoint: a lost taskId cannot be recovered and the spend is simply gone.
submit() { # $1 model  $2 input.json  $3 name  $4 state-dir  [$5 attempt]
  local model="$1" input="$2" name="$3" state="$4" attempt="${5:-1}" body resp code task
  [ -f "$input" ] || { echo "No such input file: $input" >&2; return 1; }
  mkdir -p "$state"
  # State is written to <name>.task.json specifically so it can never overwrite the
  # input payload when both live in the same directory. Guard anyway: clobbering the
  # input would silently corrupt the retry path, which is the one path that must work.
  if [ "$(cd "$(dirname "$input")" && pwd)/$(basename "$input")" = "$(cd "$state" && pwd)/$name.task.json" ]; then
    echo "Refusing to run: state file would overwrite the input payload ($input)." >&2; return 1
  fi
  body=$(jq -n --arg m "$model" --slurpfile i "$input" '{model:$m, input:$i[0]}')
  resp=$(api POST "/jobs/createTask" "$body")
  code=$(echo "$resp" | jq -r '.code // empty')
  task=$(echo "$resp" | jq -r '.data.taskId // empty')

  # A rejection (422/500) is free. A 200 with a taskId is QUEUED AND BILLABLE.
  # Never treat these as interchangeable.
  if [ -z "$task" ]; then
    echo "Rejected (no charge) [code $code]: $(echo "$resp" | jq -r '.msg // .')" >&2
    return 1
  fi

  jq -n --arg t "$task" --arg m "$model" --arg i "$input" --argjson a "$attempt" \
        --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{taskId:$t, model:$m, input:$i, attempt:$a, submitted:$ts}' > "$state/$name.task.json"
  echo "submitted $name ($task) attempt $attempt"
}

# Poll once, up to max-wait. Never abandons a job silently.
poll() { # $1 name  $2 state-dir  $3 out-file  [$4 max-wait]
  local name="$1" state="$2" out="$3" max="${4:-600}" job task elapsed=0 resp st url
  job="$state/$name.task.json"
  [ -f "$job" ] || { echo "No submitted job named $name in $state." >&2; return 1; }
  task=$(jq -r '.taskId' "$job")
  while :; do
    resp=$(api GET "/jobs/recordInfo?taskId=$task")
    st=$(echo "$resp" | jq -r '.data.state // "unknown"')
    case "$st" in
      success)
        # resultJson is a JSON *string* containing resultUrls[] — parse twice.
        url=$(echo "$resp" | jq -r '.data.resultJson // empty' | jq -r '.resultUrls[0] // empty')
        [ -n "$url" ] || { echo "success but no result URL: $resp" >&2; return 1; }
        mkdir -p "$(dirname "$out")"
        curl -sS -o "$out" "$url"
        echo "$out"
        return 0 ;;
      fail)
        echo "$name FAILED: $(echo "$resp" | jq -r '.data.failMsg // "unknown"') (code $(echo "$resp" | jq -r '.data.failCode // "-"'))" >&2
        return 1 ;;
      waiting|queuing|generating) : ;;
      *) echo "$name unexpected state '$st': $resp" >&2; return 1 ;;
    esac
    if [ "$elapsed" -ge "$max" ]; then
      echo "$name still $st after ${elapsed}s — call poll again (job is alive server-side)."
      return 2
    fi
    sleep 15; elapsed=$((elapsed + 15))
  done
}

status() { # $1 name  $2 state-dir
  local job="$2/$1.task.json"
  [ -f "$job" ] || { echo "no state for $1" >&2; return 1; }
  api GET "/jobs/recordInfo?taskId=$(jq -r .taskId "$job")" \
    | jq -c '{state:.data.state, failCode:.data.failCode, failMsg:.data.failMsg, costTime:.data.costTime}'
}

# Submit, poll, and retry ONCE on an explicit failure.
#
# Why retry only on `fail` and never on `stuck`: a failed job is not charged, so
# resubmitting costs nothing. A stuck job is still alive server-side and some
# models bill at start — resubmitting one risks paying twice for the same output.
# Observed queue times for identical payloads ranged from 50s to 30 minutes, so
# slow is normal and is not evidence of failure. Stuck exits 3 for a human.
run() { # $1 model  $2 input.json  $3 name  $4 state-dir  $5 out  [$6 max-wait]
  local model="$1" input="$2" name="$3" state="$4" out="$5" max="${6:-600}" rc before after
  before=$(credits)
  submit "$model" "$input" "$name" "$state" 1 || return 1
  set +e; poll "$name" "$state" "$out" "$max"; rc=$?; set -e

  if [ "$rc" -eq 1 ]; then
    echo "retrying $name once (failed jobs are not charged)..." >&2
    submit "$model" "$input" "$name" "$state" 2 || return 1
    set +e; poll "$name" "$state" "$out" "$max"; rc=$?; set -e
  fi

  after=$(credits)
  awk -v b="$before" -v a="$after" -v n="$name" \
    'BEGIN{d=b-a; printf "%s cost: %.1f credits = $%.3f (balance %.1f)\n", n, d, d*0.005, a}' >&2

  case "$rc" in
    0) return 0 ;;
    2) echo "$name STUCK after ${max}s. Job is alive server-side; resume with:" >&2
       echo "  kie_run.sh poll $name $state $out" >&2
       echo "Do NOT resubmit blindly — some models bill at submit and you would pay twice." >&2
       return 3 ;;
    *) echo "$name failed twice — stopping rather than burning more attempts." >&2
       return 1 ;;
  esac
}

case "${1:-}" in
  credits) credits ;;
  submit)  submit "$2" "$3" "$4" "$5" "${6:-1}" ;;
  poll)    poll   "$2" "$3" "$4" "${5:-600}" ;;
  status)  status "$2" "$3" ;;
  run)     run    "$2" "$3" "$4" "$5" "$6" "${7:-600}" ;;
  *) sed -n '2,17p' "$0" >&2; exit 1 ;;
esac
