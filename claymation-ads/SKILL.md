---
name: claymation-ads
description: Produce a finished AI claymation video ad end-to-end from a product image and an angle, using a FAL API key — planned script, approved character masters, chained keyframe stills, per-line voiceover, gemini-omni clip animation, optional lipsync to a chosen voice, and ffmpeg assembly into one finished MP4 (9:16 or 16:9). Use this skill whenever the user wants to create a claymation ad, an animated story ad, an AI video ad in a clay/stop-motion/Pixar-like style, turn a product photo into an animated ad, or mentions making video ads with FAL, gpt-image-2, or omni video — even if they only say "make me an animated ad for my product."
---

# Claymation Ads

Turn a product image plus an angle into a finished vertical claymation video ad. The pipeline is a chain of cheap, reviewable artifacts — each stage's output anchors the next, and the user approves at five gates before money concentrates. Everything deterministic (API calls, audio math, assembly) lives in `scripts/`; your job is planning, prompt assembly, quality judgment, and stopping at the gates.

**Read `references/prompts.md` before writing any generation prompt** — the templates there encode hard-won consistency rules. **Read `references/fal-api.md` before the first FAL call** — it has the payload shapes and model routes.

## Default stack

| Role | Model | Notes |
|---|---|---|
| Images | `openai/gpt-image-2` (`/edit` for references) | style lock, masters, keyframes |
| Video | `google/gemini-omni-flash/reference-to-video` | 720p, `duration` int 3–10, `aspect_ratio` **only** `9:16` or `16:9` |
| Voice | ElevenLabs — direct API when the user names a voice, via FAL for stock | clones resolve ONLY on the direct route |
| Lipsync | `fal-ai/sync-lipsync/v2` | only when a character speaks on camera |

Use these unless the user asks otherwise. The one rule binding them together: **the video model emits only 9:16 and 16:9, so every still must be generated at that aspect from the start.** Choose it at gate 2. Reframing later is a full re-render, costs an extra generation, and degrades any label or signage text in frame.

## Why this order works (understand this before deviating)

Character consistency in AI video comes from three mechanisms stacked, none sufficient alone:

1. **Approved masters ride every image.** A style lock (the world: material, palette, lighting, sets) and one master reference per recurring character are generated FIRST and attached as reference images to every later generation. Without this, a 10-scene ad drifts into several different protagonists.
2. **The chain.** Each scene still also references the previous scene's still, so adjacent frames agree locally.
3. **The clip contract.** Each video clip is generated from a PAIR of stills (this scene's + the next scene's) with a prompt contract that frame one is the first image unchanged and the final frame matches the second image. Clips therefore join seamlessly — clip N ends on the exact frame clip N+1 begins.

And one rule that outranks all three: **the real product photo is the only product authority.** Never generate a "master" of the product; attach the user's actual packshot to every image that shows the product. Generated product references degrade label text within two generations ("Testosterone" becomes "Testasterone" — this is the single most common failure in AI product ads).

Voiceover is generated per-line BEFORE the clips, so scene timing comes from measured audio, not estimates. This is why the final cuts land exactly on the narration with zero timing correction.

## Requirements

- `FAL_KEY` in the environment. If missing, say so up front and ask the user to `export FAL_KEY=...` (keys at fal.ai/dashboard/keys) — but keep going: gates 1 and 2 are free and need no key. The key becomes a hard requirement at gate 3, where the first paid call happens. Never ask them to paste the key into chat. If auth fails with a key that looks right, check for invisible characters (BOM `U+FEFF`) — keys copy-pasted from files carry them and the corruption is invisible in editors.
- `ffmpeg` and `jq` installed (`brew install ffmpeg jq`).
- A product image file from the user.
- Optional: `ELEVENLABS_API_KEY` if the user has their own cloned voice — FAL's ElevenLabs endpoints run on FAL's account, so a user's personal voice clone can NOT resolve through FAL. Stock voices work through FAL; clones need the direct key.

## Project folder

All state lives in one folder per ad so any session can resume mid-pipeline:

```
<ad-name>/
  brief.md          # product, angle, audience, packshot path
  plan.json         # script lines, scenes, cast, visual world
  refs/             # style-lock.png, <subject>.png masters
  stills/           # scene-01.png ... scene-NN.png
  vo/               # line-01.mp3 ... + durations.json
  clips/            # clip-01.mp4 ... (N-1 clips)
  final.mp4
```

On invocation, check for an existing folder and resume from the first missing artifact rather than starting over.

## The workflow

### Gate 1 — Brief

Collect: product name, what it does, the ad's angle (the one idea the ad argues), target audience, and the packshot image path. Write `brief.md`. Keep it under a page. Show it and get approval before planning.

### Gate 2 — Plan and script

Write `plan.json` (schema in `references/prompts.md`):

- **Aspect**: `9:16` (vertical — feed ads, mobile-first landing pages) or `16:9` (horizontal — desktop embeds, YouTube pre-roll). These are the ONLY two the video model emits, so this choice is a hard contract: it fixes the `image_size` of every still (`portrait_16_9` / `landscape_16_9`) and the `aspect_ratio` of every clip. Decide it here and never reframe later — a reframing pass re-renders the whole image and puts all label and signage text back at risk.
- **Script**: 8–12 narration lines. Each line ≤10 words — this is a hard constraint, because each line becomes one scene and one voiceover segment; a line that reads longer than its clip breaks assembly. Short declarative sentences are also just better ad copy.
- **Cast**: 1–3 recurring non-product subjects, each with name, kind, and appearance description. Personify boldly — an organ, a hormone, a problem can be a character. Do NOT cast the product.
- **Visual world**: material system, palette, lighting, set language, shared character construction grammar (hand style, eye design, mouth rules), negative constraints.
- **Scenes**: one per line, each with an image prompt built per the keyframe template. Group consecutive beats that share a camera setup — they can become ONE clip rather than several (see gate 5).

Present the script and cast list for approval. This is the highest-leverage review in the whole pipeline — a weak line here costs money at every later stage.

### Gate 3 — Style lock and masters (~$0.05–0.30)

1. Generate the style lock via text-to-image. CRITICAL: the style-lock prompt must never describe any character, even though the plan contains character descriptions — describing a character inside a "show no characters" prompt reliably leaks the character into the frame. Use the template exactly.
2. Generate each subject master via image edit, referencing the style lock. Masters get the shared construction grammar plus their own appearance.
3. Show the images. The user approves, or gives a revision note (append it as `Revision request: ...` and regenerate that artifact only).

Approved masters are frozen — from here on they are reference inputs, never regenerated casually. Regenerating a master after stills exist means regenerating every still that used it.

### Gate 4 — Keyframe stills (~$0.04 × N)

Generate scene stills IN ORDER (the chain requires it — scene N references scene N−1):

- Scene 1: edit call, references = [all masters, packshot if product visible].
- Scene N: edit call, references = [all masters, scene N−1 still, packshot if product visible].

Quote the total price before starting. After the run, build a contact sheet (`scripts/contact_sheet.sh`) and show it — a strip of thumbnails is how a human catches the one off-model frame in seconds. Repair individual scenes with a revision note; a repaired scene N invalidates only scenes after it if drift is visible, not automatically.

### Gate 5 — Voiceover, then clips (the expensive gate)

Default video model: **`google/gemini-omni-flash/reference-to-video`**. Schema and constraints in `references/fal-api.md` — read it before the first clip call.

1. **VO first**: one TTS call per narration line via `scripts/tts_line.sh`, which also probes each mp3's real duration into `vo/durations.json`. Cheap — no gate needed, but play one line back so the user confirms the voice before 10 more. If the user named a specific voice, verify `ELEVENLABS_VOICE_ID` is set first: without it the script silently uses a FAL stock voice instead, with no error.
2. **Decide the clip boundaries before quoting.** Omni honours timing instructions inside the prompt ("within the first 1.5 seconds… then for the remainder…"), so one clip can carry several beats. Generate one clip per *camera setup*, not one per beat. A single 9s clip covering "closes the book, then speaks to camera" beats two stitched clips on cost, on seams, and on lipsync stability. Only split when the setup genuinely changes.
3. **Quote the clips**: clip count × seconds × the per-second price. This is most of the ad's cost — state the number and get explicit approval.
4. Generate each clip with the transition contract prompt (template in `references/prompts.md`), `aspect_ratio` from gate 2, `duration` an integer 3–10. **Generate at the length you need** — never generate long and speed-ramp with `setpts`, which desynchronises lipsync exactly where speech starts.
5. **If the ad has an on-camera speaker**, Omni cannot be given your voiceover — it invents its own speech and animates the mouth to that. Strip its audio (`-an`), then bind the real VO with `fal-ai/sync-lipsync/v2`. Pad the VO's lead-in silence to the frame where the character is actually ready to speak; find that frame by inspecting the clip, not by assuming.
6. **For multi-scene ads, generate the outro clip N too** (single-reference idle animation of the final still — template in `references/prompts.md`) and include it in the quote. Without it the last narration line plays over a frozen still, which clients reliably read as a bug. assemble.sh picks it up automatically.

### Assembly (free)

Run `scripts/assemble.sh <ad-folder>`. Per scene it trims the clip to that line's measured VO duration (freeze-holding the last frame if the VO runs past the clip), muxes the narration, concats everything, and normalizes loudness to -14 LUFS. Optional: pass a music bed file to duck it under the narration. Output: `final.mp4` at the gate-2 aspect, ready to post.

For a single-scene ad the script is overkill — trim, mux, and `loudnorm=I=-14:TP=-1.5:LRA=11` directly.

**Captions.** Landing-page and feed video autoplays muted, so a voiceover-only ad is silent mouth movement to most viewers. Offer burned-in captions on any ad whose message lives in the narration; it costs nothing but ffmpeg. Time them from ElevenLabs forced alignment against the existing mp3 (see `references/fal-api.md`), never by estimating, and offset every timestamp by the lead-in pad. Keep the `.ass` file in the ad folder so wording and position stay re-editable for free.

Show the user the final file. Offer the natural iterations: swap a line's VO take, repair one scene, re-run assembly (assembly is free — regeneration is not).

## Execution environment (read before the first generation)

Skill provisioning may strip the executable bit from `scripts/*.sh` — copy them into the project folder and `chmod +x` there (this also survives skill updates mid-project). Invoke with `bash script.sh` if in doubt; tts_line.sh's internal fal_run.sh call is already bash-wrapped for this reason.

**Send every artifact as it lands (default behavior):** immediately after each successful poll — style lock, each master, each scene still, each clip, the final — send that file to the user inline before submitting the next generation. Never batch artifacts up for a later reveal; the user watching each one pop onto the screen as it completes is part of the product (these runs are often screen-recorded for demos). The review gates still exist on top of this: the contact sheet, voice sample, and cost quotes remain the explicit stop-and-approve moments.

Each image or clip generation takes 1–3 minutes at the provider. Two rules keep that survivable in any environment:

1. **One generation per tool call, always in the foreground.** Never loop several generations inside one bash invocation — a chain of ten 2-minute jobs inside one call will hit the platform's tool timeout and die mid-batch. The chain is sequential anyway; one call per scene costs nothing and survives everything.
2. **Never background the work (`nohup`, `&`).** Sandboxed environments reap orphaned processes, and you lose the job handle when they do. You don't need a local background process — FAL's queue IS the background: the job runs server-side and survives anything that happens to your shell. When a single generation might outlive a tool call (short-timeout platforms like claude.ai chat), use the split flow:

```
scripts/fal_run.sh submit <model> payload.json scene-04 <ad>/jobs   # returns immediately
scripts/fal_run.sh poll scene-04 <ad>/jobs stills/scene-04.png      # exit 0 done · 2 still running (call again) · 1 failed
```

Job state persists in `<ad>/jobs/`, so polling resumes across tool calls and even across sessions. In Claude Code (bash timeouts up to 10 minutes), the one-shot form is fine for single generations; the submit/poll split is still the safer habit for clips.

## Cost discipline

Before every paid step, print what it costs — image count × image price, clip count × clip price — using current prices from the model pages (see `references/fal-api.md`; prices change, so verify once per session, not per call). Never fire a batch the user hasn't seen a number for. Track actual spend in the project folder as you go; report the total at the end. A typical 10-scene ad: ~13 images + 9 clips + 10 TTS lines.

## Failure handling

- FAL queue jobs can fail or hang: `scripts/fal_run.sh` times out and reports; retry once, then show the user the error rather than burning retries.
- If a generated image violates its contract (character in the style lock, garbled label, wrong character), regenerate with a revision note naming the violation — don't accept and hope the next stage fixes it. Later stages amplify, never repair.
- If a param name is rejected by a model, check the model's page at fal.ai for the current schema before retrying — `references/fal-api.md` payloads are a starting point, not gospel.
