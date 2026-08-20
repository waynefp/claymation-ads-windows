# FAL API reference

All calls go through FAL's queue API with `scripts/fal_run.sh`. Auth is the `FAL_KEY` env var. **Param names below are a starting point — if a model rejects a payload, open its page at `https://fal.ai/models/<model-id>` and check the current input schema before retrying.** Verify current per-call pricing on the same pages once per session and use those numbers in every cost quote.

## Queue mechanics (handled by fal_run.sh)

```
POST https://queue.fal.run/<model-id>        # body: the JSON payload → {request_id, status_url, response_url}
GET  <status_url>                            # poll until status == COMPLETED
GET  <response_url>                          # → result JSON with file URLs to download
```

The queue is server-side — a submitted job survives tool timeouts and killed shells. `fal_run.sh submit` writes the job's URLs to `<state-dir>/<name>.json`; `fal_run.sh poll` resumes from that file in any later tool call (exit 2 means still running — just call poll again). Use submit/poll for every image and clip generation; the one-shot form is for fast jobs like TTS.

Local files (packshot, masters, stills) must be publicly reachable URLs for reference inputs. Upload them first via FAL's storage endpoint (`fal_run.sh --upload <file>` handles this and prints the URL). Upload each file once per project and cache the URL in the project folder — re-uploading identical files wastes time.

## Models

### Style lock — `openai/gpt-image-2` (text-to-image)

```json
{ "prompt": "...", "image_size": "portrait_16_9" }
```

`image_size` is an ENUM, not pixel dimensions (schema changed 2026-08: `"1024x1536"` now 422s). Valid: `square_hd`, `square`, `portrait_4_3`, `portrait_16_9`, `landscape_4_3`, `landscape_16_9`, `auto`.

**Aspect contract — generate every still at the aspect the video model can emit.** Omni emits ONLY `9:16` or `16:9`, so stills must be created at `portrait_16_9` (→ Omni `9:16`) or `landscape_16_9` (→ Omni `16:9`). Pick one at gate 2 and use it for the style lock, every master, and every keyframe.

Never generate stills at `square`, `*_4_3`, or `auto` and reframe them later: a reframing pass is a full re-render that puts every piece of label and signage text back at risk, and it is pure waste when the correct aspect was free at creation time. If a user supplies a source image at some other aspect (a 5:4 packshot, a square photo), the widen/reframe edit is unavoidable — but that is the only case where it is justified.

### Masters & keyframes — `openai/gpt-image-2/edit`

```json
{ "prompt": "...", "image_urls": ["<ref1>", "<ref2>", "..."], "image_size": "portrait_16_9" }
```

Observed pricing 2026-08: ~$0.06–0.11/image at medium quality, portrait — still verify per session.

Reference order carries authority: masters first, previous still next, packshot always LAST.

### Clips — `google/gemini-omni-flash/reference-to-video` (DEFAULT video model)

```json
{ "prompt": "...", "image_urls": ["<still-N>", "<still-N+1>"], "duration": 8, "aspect_ratio": "9:16" }
```

Verified schema (2026-08):

| Field | Type | Constraint |
|---|---|---|
| `prompt` | string | max 20000 chars; supports `<IMAGE_REF_0>`, `<IMAGE_REF_1>`… role tags |
| `duration` | **integer** | **min 3, max 10**, default 8 — NOT a string, NOT an enum |
| `aspect_ratio` | string | **only** `"16:9"` or `"9:16"`, default `16:9` |
| `image_urls` | array | 1–10 URLs |

There is no `resolution` field and no end-frame field. Output is 720p (1280×720 / 720×1280) regardless. `duration: 2` is rejected with `Input should be greater than or equal to 3` — the floor is real, so a beat shorter than 3s must be generated at 3s and time-remapped in ffmpeg.

**The end frame is a PROMPT contract, and so is timing.** The last reference image is bound to the final frame by the wording in prompts.md, and Omni also honours in-prompt timing instructions ("within the first second… then for the remainder…"). This is the key difference from hard end-frame parameters on other models, which interpolate the change evenly across the whole clip and therefore cannot place a beat early.

**Consequence: prefer ONE clip covering several beats over several stitched clips.** A single generation of "closes the book in the first 1.5s, then speaks to camera for the remainder" is cheaper than two clips, has no join seam, and needs no speed-ramping. Split into multiple clips only when the scenes are genuinely different setups. Every stitch you avoid is a framing pop you avoid.

Three facts learned in production (2026-08):
- **Omni clips contain their own AAC audio track.** Any downstream mux MUST use explicit stream mapping (`-map 0:v:0 -map 1:a:0`) or ffmpeg silently prefers the clip's audio over the narration — the symptom is an ad with no VO until the final still-held segment. assemble.sh now maps explicitly; keep that if you ever hand-roll ffmpeg here. When lipsyncing, strip it outright with `-an`.
- **Never speed-ramp a clip that carries dialogue.** Generating a beat long and running `setpts=PTS/N` to compress it produces unnaturally fast motion that desynchronises lipsync at the very moment speech begins. Generate at the duration you need.
- Observed pricing: ~$0.13/second at 720p → ~$1.17 for a 9s clip. Verify per session.

#### Choosing a specific voice (Omni cannot be told one)

Omni synthesises its own speech and animates the mouth to *that*. There is **no audio input parameter** — you cannot hand it a voiceover. To ship a chosen voice:

1. Generate the clip; strip its audio (`-an`).
2. Generate the VO separately (ElevenLabs, below) and pad the lead-in silence to match when the character is ready to speak.
3. Bind them with `fal-ai/sync-lipsync/v2`:

```json
{ "video_url": "...", "audio_url": "...", "model": "lipsync-2-pro", "sync_mode": "cut_off" }
```

`model`: `lipsync-2` ($3/min) or `lipsync-2-pro` ($5/min). Pro is worth it on stylised/clay faces, which are off-distribution for sync models; quote the tier you actually intend to use. `sync_mode`: `cut_off` | `loop` | `bounce` | `silence` | `remap`.

Skipping the lipsync pass is a legitimate cheaper option — the mouth then moves to Omni's invented speech rather than the narration. Loose sync is a real claymation convention, but say so explicitly rather than shipping it silently.

### Voiceover — ElevenLabs via FAL (stock voices)

Confirmed working route (2026-08): `fal-ai/elevenlabs/tts/eleven-v3`. Payload is text + stock voice name; "Brian" is a good deep authoritative ad read. If the route 404s, probe siblings (`.../tts/multilingual-v2`, `.../tts/turbo-v2.5`) or search fal.ai.

```json
{ "text": "the narration line", "voice": "Brian" }
```

**Voice clones cannot resolve through FAL** — FAL calls ElevenLabs on FAL's own account, so a voice cloned in the user's ElevenLabs account does not exist there. If the user has `ELEVENLABS_API_KEY` and a clone, call ElevenLabs directly instead:

```
POST https://api.elevenlabs.io/v1/text-to-speech/<voice_id>
  header: xi-api-key: $ELEVENLABS_API_KEY
  body: { "text": "...", "model_id": "eleven_v3" }
```

`tts_line.sh` takes this direct route only when **both** `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID` are set. With the key but no voice id it silently falls back to FAL's stock voices — so a user who asked for a specific voice gets a different one with no error. Whenever the user names a voice, confirm `ELEVENLABS_VOICE_ID` is in the environment before generating, and resolve it to a name via `GET /v1/voices/<id>` so you can state which voice you actually used.

Listing the account's voices (`GET /v1/voices`) is free and is the right way to offer a choice. `category` tells you what you are dealing with: `premade` and `generated` work through either route; `cloned` works ONLY on this direct route.

#### Caption timing — forced alignment, not estimation

To caption a line, align against the mp3 you already generated rather than guessing or regenerating:

```
POST https://api.elevenlabs.io/v1/forced-alignment
  header: xi-api-key: $ELEVENLABS_API_KEY
  multipart: file=@line-NN.mp3, text="<the exact line>"
  → { characters: [...], words: [{text, start, end}, ...] }
```

Word-level start/end times against the *existing* take, so captions match the audio that is already lipsynced. Regenerating the VO to get timings would produce a different take and desynchronise the video. Add the lead-in pad offset to every timestamp.

## Cost quoting

Before each paid batch print: `<count> × $<per-call> = $<total>` with prices read from the model pages this session. A typical 10-scene ad is ~13 images (1 lock + 2-3 masters + 10 stills, plus repairs) and 9 clips; clips dominate the total.
