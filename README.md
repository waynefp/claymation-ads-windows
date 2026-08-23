# claymation-ads — Windows fixes + Gemini Omni defaults

A patched build of **[claymation-ads](https://github.com/mikefutia/claymation-ads-claude-skill)**, the Claude Skill by [Mike Futia](https://www.skool.com/scale-ai) that turns a product image and an angle into a finished claymation video ad.

All the pipeline design, prompt engineering, and consistency mechanics are Mike's work, released free to use and modify. This fork adds two Windows bug fixes and rewrites the default model stack around Gemini Omni, based on what actually broke in production.

**Start with [Mike's original](https://github.com/mikefutia/claymation-ads-claude-skill)** — it explains the five approval gates, the character-consistency mechanisms, and the cost model. This README only covers what differs.

---

## Install

```bash
git clone https://github.com/waynefp/claymation-ads-windows
cd claymation-ads-windows
bash restore.sh          # copies the skill into ~/.claude/skills/
```

`restore.sh --check` reports drift without changing anything. Restoring moves any existing install aside as `claymation-ads.replaced-<timestamp>` rather than deleting it.

### Requirements

| Need | Windows install |
|---|---|
| ffmpeg / ffprobe | `winget install Gyan.FFmpeg` |
| jq | `winget install jqlang.jq` |
| bash, curl | Git for Windows |

The scripts are bash and run under **Git Bash**, not PowerShell. Restart your shell after winget installs so the new PATH entries resolve.

Environment (never commit these):

```
FAL_KEY=...
ELEVENLABS_API_KEY=...
ELEVENLABS_VOICE_ID=...      # required if you want a specific voice
ELEVENLABS_MODEL_ID=eleven_v3
```

Keep the file LF-terminated, unquoted, no leading spaces, underscores only in names. Three separate auth failures in testing traced back to CRLF endings, a hyphen in a variable name, and a capitalised `sk_` prefix.

---

## 1. `assemble.sh` — concat list used `$PWD`

The concat list was built with `$PWD`, which under Git Bash expands to a POSIX path (`/c/Users/...`) that native `ffmpeg.exe` cannot open. Final assembly died with `Impossible to open` before writing `final.mp4`.

Fixed by writing bare basenames. The concat demuxer resolves relative entries against the list file's own directory, and the segments already live beside it, so this is correct on every platform.

**Severity:** blocked every multi-scene ad at the final step.

## 2. `contact_sheet.sh` — `ffmpeg -pattern_type glob`

Common Windows ffmpeg builds — including Gyan's, the one winget installs — ship without globbing support. The script failed outright:

```
Pattern type 'glob' was selected but globbing is not supported by this libavformat build
exit 127
```

Rewritten to glob in the shell and stage sequentially-numbered copies, feeding ffmpeg's `%03d` image2 pattern instead, which every build supports. Staging happens inside the ad folder rather than `mktemp -d`, because mktemp returns a `/tmp/...` POSIX path — the same class of bug as #1.

**Severity:** gate 4's review step could never run on Windows.

**Behaviour change:** the sheet now matches `scene-NN.png` specifically rather than `scene-*.png`. That is the skill's documented naming convention, but oddly-named stills are excluded rather than silently misordered.

## 3. Two documented pipelines: volume (Kie) and movement (FAL)

The upstream skill assumes one path: multi-scene, FAL-only, five approval gates. This fork
documents a second, much cheaper path for single-character talking pieces, and makes the
provider choice explicit per step rather than per platform.

**Volume mode — ~$0.33 per finished video.** One still (Kie `gpt-image-2-image-to-image` at
2K, $0.05) plus one call to `kling/ai-avatar-standard` ($0.04/s), which animates the face
*and* embeds your chosen ElevenLabs voice — no separate lipsync pass. Then lead-in, captions,
loudness locally. Right for recurring content where someone simply talks to camera.

**Movement mode — ~$1.90.** Needed only when a discrete action must happen. Directed motion
plus a chosen voice is **only** possible on FAL: Omni takes prompt direction but no audio;
Kie's avatar models take audio but animate only the face; and Kie's promptable video model
(Seedance 2.5) rejects reference audio and frame anchors together. Nothing on Kie closes
that gap at any price.

Stills come from Kie in **both** modes — cheaper than FAL ($0.05 vs ~$0.08) and far higher
resolution (2048×1152 vs 1088×608). FAL accepts Kie's hosted URLs as reference inputs.

New reference: **`references/kie-api.md`** — verified model IDs and prices, the four
operational traps (no cancel endpoint, no task-list endpoint, inconsistent charge timing,
a 20-req/10s rate limit that masquerades as "model not found"), and measured queue times.

Two still-design rules now in `prompts.md`, both learned the expensive way:
**settled hands** (an audio-driven model given an object mid-manipulation will fumble it)
and **face large and near-frontal** (lipsync quality scales with face pixels).

Plus a four-clause avatar prompt recipe. The restraint clause — explicitly forbidding
over-articulation — is what stops the delivery reading as a puppet, and the body/ambient
clause is what stops it reading as a frozen mannequin. Ambient motion (steam, firelight)
belongs in the still; the video model animates what is already there far more reliably
than it invents something new.

## 4. Gemini Omni as the default FAL video model

Documentation-only; no script behaviour changed. `SKILL.md`, `references/fal-api.md`, and `references/prompts.md` now default to `gpt-image-2` for images and `google/gemini-omni-flash/reference-to-video` for video.

**Omni's actual schema**, which the original documented differently:

| Field | Was documented | Actually |
|---|---|---|
| `duration` | string `"4"` | **integer, min 3, max 10** |
| `aspect_ratio` | `"9:16"` | **only** `16:9` or `9:16` |
| `resolution` | `"720p"` | field does not exist — always 720p |

`duration: 2` is rejected with `Input should be greater than or equal to 3`.

**The aspect contract.** Because Omni emits only those two ratios, every still must be generated at `portrait_16_9` or `landscape_16_9` from the start. Choosing at gate 2 avoids a later reframing pass — a full re-render that degrades label and signage text.

**One clip, several beats.** Omni honours timing instructions inside the prompt ("within the first 1.5 seconds… then for the remainder…"), so a single generation can carry an action *and* a hold. The original's one-clip-per-beat structure is a workaround for models with hard end-frame parameters, which interpolate the change evenly and cannot place a beat early. Fewer clips means no join seams. A new **multi-beat clip** template is in `references/prompts.md`.

**Never speed-ramp dialogue.** Generating a beat long and compressing it with `setpts` produces unnaturally fast motion that desynchronises lipsync exactly where speech begins.

**Choosing a voice.** Omni has no audio input — it synthesises its own speech and animates the mouth to that. Shipping a chosen voice means stripping Omni's audio (`-an`) and binding the real VO with `fal-ai/sync-lipsync/v2` (`lipsync-2` $3/min, `lipsync-2-pro` $5/min; pro is worth it on clay faces, which are off-distribution for sync models).

**`tts_line.sh` falls back silently.** It takes the direct ElevenLabs route only when both `ELEVENLABS_API_KEY` *and* `ELEVENLABS_VOICE_ID` are set. With the key alone it quietly uses a FAL stock voice — a user who asked for a specific voice gets a different one, with no error. Cloned voices resolve **only** on the direct route, since FAL calls ElevenLabs on FAL's own account.

**Caption timing via forced alignment.** `POST /v1/forced-alignment` returns word-level timings against the mp3 you already generated, so captions match the take that was lipsynced. Regenerating the VO to get timings produces a different take and desynchronises the video.

---

## Applying to a newer upstream release

Don't restore this fork over a newer upstream — you'd discard Mike's changes. Apply just the diffs:

```bash
cd ~/.claude/skills/claymation-ads
patch -p1 --binary < /path/to/windows-fixes.patch
```

`--binary` matters: the upstream scripts carry CRLF line endings and patch will otherwise mangle them. `windows-fixes.patch` is a unified diff against upstream as of 2026-08-18. If it stops applying cleanly, every change is described above in enough detail to redo by hand.

## Note on line endings

Three upstream scripts (`assemble.sh`, `fal_run.sh`, `tts_line.sh`) carry CRLF terminators. Git Bash tolerates them and they run correctly, so this was left alone deliberately — changing it is unrelated to the bugs above and risks breaking a working setup.

---

Upstream: **https://github.com/mikefutia/claymation-ads-claude-skill** — please credit Mike, not this fork, for the skill itself.
