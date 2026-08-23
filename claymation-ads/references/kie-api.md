# Kie.ai API reference

Second provider alongside FAL. Used for the **volume pipeline** (see SKILL.md) because
`kling/ai-avatar-standard` fuses animation and lipsync into one call, and Kie's
`gpt-image-2` is cheaper and higher-resolution than FAL's.

Auth is `KIE_API_KEY` as a bearer token. Prices below are credits; **1 credit = $0.005**.
Verify per session — check `GET /api/v1/chat/credit` and the model's page at
`https://kie.ai/<model-slug>`.

## Mechanics

```
POST https://api.kie.ai/api/v1/jobs/createTask     # {model, input:{...}} -> {taskId}
GET  https://api.kie.ai/api/v1/jobs/recordInfo?taskId=<id>
GET  https://api.kie.ai/api/v1/chat/credit          # -> {data: <credits remaining>}
```

`recordInfo` returns `state`: `waiting` | `queuing` | `generating` | `success` | `fail`,
plus `failMsg` and `resultJson` (a JSON *string* containing `resultUrls[]` — parse twice).

Some model families have their own endpoints instead of the Market API:
`/api/v1/veo/generate`, `/api/v1/gpt4o-image/generate`, `/api/v1/runway/generate`.

### Four operational facts that will bite you

1. **There is NO cancel endpoint and NO task-list endpoint.** A submitted job cannot be
   stopped, and if you lose the `taskId` you cannot recover it — the spend is simply gone.
   Write every `taskId` to disk in the same tool call that submits it.
2. **A validation error and a queued job look similar.** `{"code":422|500,...}` means
   rejected and free; `{"code":200,...,"data":{"taskId":...}}` means **queued and billable**.
   When probing schemas, use a deliberately malformed value (a bad URL) so nothing can
   succeed. Probing with plausible payloads spends real money.
3. **Charging is inconsistent.** Some models deduct at start (`kling/ai-avatar-*`), others
   on completion. Failed jobs are generally not charged. Measure cost as a credit delta
   across the call, never assume.
4. **Rate limit: 20 new generation requests per 10 seconds.** Bursting past it returns
   `"Your call frequency is too high"` — which is NOT a signal that a model does not exist.
   Re-probe anything that returned 429 before concluding anything from it.

### Use `scripts/kie_run.sh`, not raw curl

The client encodes every trap on this page. Same shape as `fal_run.sh`:

```
kie_run.sh credits
kie_run.sh submit <model> <input.json> <job-name> <state-dir>
kie_run.sh poll   <job-name> <state-dir> <out-file> [max-wait]
kie_run.sh run    <model> <input.json> <job-name> <state-dir> <out-file> [max-wait]
kie_run.sh status <job-name> <state-dir>
```

`<input.json>` holds ONLY the `input` object; the model is a separate argument.
State is written to `<state-dir>/<name>.task.json` **before** the call returns.

`run` exit codes: `0` done · `1` failed after one retry · `3` stuck.

What it handles for you: 429 backoff; rejection-vs-queued discrimination (a rejection
writes no state and costs nothing); double-decoding `resultJson`; cost reported as a
credit delta; and **auto-retry on `fail` but never on stuck**.

That last asymmetry is the important one. A failed job is not charged, so retrying is
free. A stuck job is still alive server-side and some models bill at submit — resubmitting
one pays twice for the same output. On stuck it exits 3 and prints the exact `poll` command
to resume from disk, which works across sessions.

### Queue reliability

Observed completion times for one 7s avatar job, same payload shape, across one session:
**50s, 105s, 160s, 165s, 180s, 200s, 315s**, one server-side failure at 1211s
(`failCode 524, "generate task timeout"`), and one that sat 30 minutes before succeeding.

FAL was consistently 90–180s. Budget for the tail: poll with a generous ceiling, and on
`fail` **resubmit once** — retries have consistently cleared fast. A failed job is not
charged, so a retry costs nothing but time. At volume this needs real retry handling.

## Models (verified 2026-08)

| Role | Model ID | Price | Notes |
|---|---|---|---|
| Image (text→image) | `gpt-image-2-text-to-image` | 10 cr / $0.05 | `aspect_ratio` 16 values inc. 5:4, `resolution` 1K/2K/4K |
| Image (edit) | `gpt-image-2-image-to-image` | 10 cr / $0.05 | `input_urls: []` — identity-preserving edits |
| **Talking video + lipsync** | `kling/ai-avatar-standard` | **8 cr/s / $0.04/s** | 720p, image+audio+prompt, **15s max per generation** |
| Talking video + lipsync | `kling/ai-avatar-pro` | 16 cr/s / $0.08/s | 1080p; detail gain is modest — Standard is usually the right call |
| Talking video + lipsync | `infinitalk/from-audio` | 72 cr / $0.36 | Wan 2.1 base. Softer, waxier. Superseded by Avatar — cheaper AND better |
| Promptable video | `bytedance/seedance-2-5` | 28/63/114 cr/s at 480/720/1080p | See constraints below |
| Image (alt) | `google/nano-banana`, `google/nano-banana-edit` | — | Not used; `gpt-image-2` keeps parity with FAL |

**Kie's `gpt-image-2` beats FAL's**: $0.05 vs ~$0.08, and 2048×1152 at `resolution: "2K"`
vs FAL's fixed 1088×608. Generate stills here even when the video step runs on FAL —
Kie returns hosted URLs that FAL accepts as reference inputs.

### `kling/ai-avatar-standard` — the volume workhorse

```json
{ "model": "kling/ai-avatar-standard",
  "input": { "image_url": "...", "audio_url": "...", "prompt": "..." } }
```

Audio-driven: it animates the mouth to the audio you supply, and **embeds that audio in
the output** — so no separate lipsync pass. Confirm the output audio duration matches your
VO to be sure your voice survived.

**The prompt is a real lever — more than the "audio-driven" label suggests.** It cannot
choreograph a discrete action (it will not close a book on cue), but it reliably controls
*motion quality and ambient detail*: articulation restraint, finger movement, breathing,
drifting steam. See the recipe in `prompts.md`. Early failures here were caused by prompts
that asked for stillness, not by model limits.

Output is padded past the audio (7.2s video for a 6.1s VO) — trim to the VO plus a short tail.

### `bytedance/seedance-2-5` — premium promptable video

Honors in-prompt timing like Omni does (a beat placed "within the first two seconds" lands
early, not smeared), and `last_frame_url` does **not** cause the even-interpolation problem
that Kling's `tail_image_url` has. Up to 30s, up to 1080p. Two hard constraints:

- **Frame-anchored tasks require `aspect_ratio: "adaptive"`.** Any other value 422s.
- **`reference_audio_urls` and `first_frame_url`/`last_frame_url` are MUTUALLY EXCLUSIVE**
  — "only one scene can be selected". So Seedance cannot do directed motion *and* your
  chosen voice in one call.

Because Kie's lipsync models accept an image and never a video, a Seedance motion clip
**cannot be lipsynced anywhere on Kie**. Directed motion plus a chosen voice is only
possible on FAL (Omni → `sync-lipsync/v2`). That is structural, not a pricing question.

Pricing note: we sit in the "no video input" column (frames are images), the more expensive
one. At 720p Seedance is ~2.4× Omni per second. It is a premium option, not a saving.
