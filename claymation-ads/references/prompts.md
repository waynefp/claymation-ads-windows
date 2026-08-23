# Prompt templates

These templates are battle-tested against gpt-image-2 and omni video specifically. The bracketed slots come from `plan.json`. Keep the contract sentences verbatim — they are doing precise work, and paraphrasing them reintroduces the failure they exist to prevent.

## plan.json schema

```json
{
  "ad_name": "kebab-case-name",
  "product": { "name": "", "packshot": "path/to/image.png" },
  "angle": "the one idea this ad argues",
  "script": [
    { "scene": 1, "line": "≤10 words, reads aloud in under 4 seconds", "product_visible": false }
  ],
  "cast": [
    { "name": "", "kind": "human|animal|body_system|symptom|object", "appearance": "construction, colors, features, wardrobe" }
  ],
  "visual_world": {
    "material": "what everything is made of",
    "palette": "3-5 tones plus one accent and what the accent means",
    "lighting": "",
    "set_language": "how sets are built (tabletop dioramas, scale, depth)",
    "character_construction": "shared grammar: hand style, eye design, mouth rule, proportions",
    "negative": "what must never appear"
  },
  "scenes": [
    { "scene": 1, "action": "what happens visually, one beat", "camera": "shot type" }
  ]
}
```

## Style lock (text-to-image)

**Never include `character_construction` or any cast description in this prompt.** Describing a character inside a no-characters prompt weights the character INTO the frame — negatives don't cancel vivid description. The construction grammar belongs in the subject-master prompts, where characters are actually drawn.

```
Create one polished vertical 9:16 master visual-world reference frame for a premium handcrafted claymation advertising story.
Material system: [visual_world.material].
Palette: [visual_world.palette].
Lighting: [visual_world.lighting].
Set language: [visual_world.set_language].
Avoid: [visual_world.negative].
Create an empty visual-world plate. Demonstrate only the materials, palette, lighting, scale, and set design using neutral non-branded forms such as set surfaces, lighting fixtures, and abstract non-product geometric props. Recurring subjects are created separately and must not appear here.
Do not show any character, mascot, person, animal, creature, face, eyes, mouth, arms, limbs, product, product-shaped silhouette, bottle, box, container, package, logo, label, pill, capsule, readable text, contact sheet, collage, split screen, or multiple style alternatives.
```

## Subject master (image edit; reference = style lock)

One call per cast member. The shared grammar goes here — every character follows it, which is what makes the cast look like it came from one workshop.

```
Create one polished vertical 9:16 master reference image for a recurring animated advertising subject.
Subject name: [cast.name]. Subject kind: [cast.kind].
Shared construction language for every recurring character, which this subject must follow: [visual_world.character_construction].
Appearance and construction: [cast.appearance].
Show one isolated complete subject, clearly readable from head or top to base, against a simple uncluttered version of the set. No other character, subject, product, package, prop, or focal object may appear.
Use the supplied visual-world reference only for material, palette, lighting, and set design. Do not copy any composition visible inside it.
Return one coherent full-frame image with no duplicate character, no second pose, no turnaround sheet, no collage, no split screen, and no text.
```

## Scene keyframe (image edit)

References, in order: the masters of the cast members **on screen in this scene** (not the whole cast), then scene N−1's still (scene 1 skips this), then the packshot **last** whenever the product is visible. Order matters — the last reference reads as most authoritative for the product.

Attaching an off-screen character's master invites it into the frame even when the prompt never mentions it (production failure 2026-08: the villain's master was attached to a product-hero scene and the villain walked into shot). If a character leaks anyway, regenerate with a revision note naming the removal AND drop that character's master from the reference list for the repair.

```
[Claymation scene description: scenes[N].action, camera scenes[N].camera, in the established world.]
Recurring cast, identical in every scene: [one clause per cast member on screen — name plus its master appearance, verbatim from the plan, never paraphrased scene to scene].
The supplied character reference images define each recurring character's identity: match face, proportions, construction, and palette exactly; pose, expression, and scene-appropriate variation follow this scene's description.
[If a previous-scene still is supplied:] One supplied image is the previous scene: use it only to keep characters, materials, and lighting continuous. Do not copy its composition.
[If the product is visible:] The final supplied image is the real product photograph and is the only authority for the product: reproduce its packaging, label layout, lettering, and colors exactly as a handcrafted clay rendition — immediately recognizable, never redrawn or approximated.
No text overlays, no borders, no panels, no split frames.
```

The cast clause must be **verbatim identical across every scene prompt** — paraphrasing the description per scene is how drift starts even with reference images attached.

## Transition clip (reference-to-video; references = still N, then still N+1)

```
[One sentence: the motion that carries scene N into scene N+1 — what moves, what transforms.]
Two reference images are provided in order. The first reference image is the exact first frame of this clip: the animation must begin from it, unchanged, on frame one. The animation must end exactly matching the second reference image.
Stop-motion claymation feel: deliberate poses, handcrafted motion, no camera shake. Keep character facial consistency. No character redesign. No facial feature changes. Keep every package's label design, lettering, and colors unchanged.
```

The end-frame instruction is a PROMPT contract, not a model parameter — omni has no end-image field. It holds remarkably well when stated exactly this way.

Omni also accepts inline role tags — `<IMAGE_REF_0>`, `<IMAGE_REF_1>` — which bind a reference to a named role more tightly than positional wording alone. Prefer them whenever a prompt refers to more than one reference.

## Multi-beat clip (reference-to-video; references = start still, then end still)

Because the end frame is a prompt contract rather than a parameter, Omni will also honour **when** a beat lands. That means one generation can carry an action AND a hold — no stitching, no seam, no speed-ramping. Use this instead of two clips whenever the camera setup does not change.

```
<IMAGE_REF_0> is the exact first frame of this clip: the animation must begin from it, unchanged, on frame one.
Within the first [N] seconds, [the action beat: what the character does, in one concrete sentence].
For the ENTIRE REMAINDER of the clip, from that moment to the final frame, [the hold beat: what continues — speaking to camera, idling, reacting]. [One clause naming what must NOT happen: never looks away, never re-opens the book, never stands.]
The animation must end exactly matching <IMAGE_REF_1>.
Stop-motion claymation feel: deliberate poses, handcrafted motion, locked-off camera, no camera shake, no zoom, no cut, no scene change. Keep character facial consistency. No character redesign. No facial feature changes. Keep every package's label design, lettering, and colors unchanged.
```

Make the END still depict the *hold* state, not the moment of change — if the character spends most of the clip with the book closed and talking, that is what `<IMAGE_REF_1>` should show. Binding the final frame to the hold state is what keeps the action early instead of smearing it across the whole clip.

Then find the real handoff frame by inspecting the output (sample frames every ~0.5s) and pad the voiceover's lead-in silence to match. Never assume the beat landed exactly where the prompt asked.

## Widening a supplied image to a usable aspect (image edit; reference = the user's image)

Only when the user supplies a source image at an aspect Omni cannot emit. Never as a routine step — generate stills at the right aspect instead.

```
Handcrafted claymation frame, recomposed to a [16:9 / 9:16] format. Keep [the subject] centered and at the same scale, [doing what it is doing], exactly as in the supplied image.
Extend the set naturally to [the left and right / above and below] to fill the frame: [name what plausibly continues there]. The newly revealed areas must match the existing set in material, palette, lighting, and style so the result looks like one continuous photographed miniature set.
The supplied image is the ONLY authority for this character and this set. Reproduce exactly: [appearance clauses]. Reproduce every piece of lettering exactly and correctly spelled: [quote every readable string in the frame, verbatim]. Never redraw, restyle, approximate, or misspell any lettering.
No new text, no extra signage, no watermark, no other person, no borders.
```

Quoting each readable string verbatim is the load-bearing part. Text in frame survives a widen pass far better when the prompt names it exactly than when it is referred to generically.

## Outro clip (reference-to-video; reference = final still only)

There are N−1 transition clips for N scenes, which leaves the last narration line playing over a frozen still — and a held still reads as a rendering glitch, not a choice. Generate clip N as a single-reference idle animation of the final still (+1 clip cost; assemble.sh uses it automatically when `clips/clip-NN.mp4` exists):

```
[One sentence: gentle idle motion — who settles, what flickers, what light moves. No new action, no new subjects.]
One reference image is provided. It is the exact first frame of this clip: the animation must begin from it, unchanged, on frame one.
Stop-motion claymation feel: deliberate poses, handcrafted motion, no camera shake. Keep character facial consistency. No character redesign. No facial feature changes. Keep every package's label design, lettering, and colors unchanged.
```

Caveat: with no second reference there is no end-frame contract, so small label text may drift mid-clip and stay drifted. Keep the product small in the final composition, or budget a re-roll if the label wobble is visible at feed scale.

## Voiceover

One TTS call per script line, voice consistent across all lines. Emphasis: writing a word in CAPS in the TTS text produces audible vocal stress on eleven_v3 — use at most one or two per ad at the moment the angle lands, not per line.

## Revision requests

For any regeneration, append to the original prompt: `Revision request: [user's note].` Change nothing else — the rest of the prompt is the consistency contract, and rewriting it during repairs is how repairs introduce new drift.

---

# Volume pipeline templates (Kie / `kling/ai-avatar-standard`)

For single-scene talking pieces where the character speaks to camera and no discrete
action is required. Schema and constraints in `references/kie-api.md`.

## Still design — two rules that decide whether the video works

These are free to obey at the image stage and expensive to fix afterwards.

1. **Settled hands, holding nothing loose.** Hands resting on a closed book, wrapped around
   a mug, folded on a table, on the arms of a chair. An audio-driven model given an object
   mid-manipulation will fumble it — an open book gets closed, reopened, and raised again at
   random. Nothing to manipulate means nothing to get wrong.
2. **Face large and near-frontal.** Lipsync quality scales with how many pixels the face
   occupies. A subject sitting back and angled away syncs visibly worse than one framed
   mid-chest up and square to camera. Generate at `resolution: "2K"` for the same reason.

**Put ambient motion elements INTO the still**, then ask the video prompt to move them:
steam off a hot drink, firelight, a curtain at a window, leaves behind a porch. The video
model animates what is already in frame far more reliably than it invents something new.

## Subject still (image edit; reference = the user's character art)

```
Handcrafted claymation frame, medium close-up framed from mid-chest up so the face is large in frame.
[Setting: where they are, the light, what is around them, one sentence.]
[Ambient element that will move: steam rising from the mug / firelight in the hearth / a curtain at the window.]

The supplied image is the ONLY authority for this character. Reproduce exactly: [appearance clauses — face, glasses, hair, facial hair, skin tone, wardrobe]. Do not redesign the character. Do not change facial features. Matte plasticine clay with visible tooling, felted fabric clothing.

[Settled-hands clause: both hands wrapped around the mug resting on the table / hands folded on the closed book in his lap.]

He looks directly into the camera lens with warm steady eye contact and a kind gentle smile, mouth closed and relaxed. Handcrafted stop-motion claymation, shallow depth of field. No readable text, no lettering, no signage, no other person, no borders.
```

`mouth closed and relaxed` in the still matters — an open, mid-speech mouth in the source
frame biases the animation toward wider shapes throughout.

## Avatar clip (image + audio + prompt)

Four clauses, in this order. The restraint clause is the one that stops the delivery
reading as a puppet.

```
A handcrafted stop-motion claymation scene. [One sentence: who, where, and that they are talking to a friend across the table.]

Speech delivery is UNDERSTATED and RESTRAINED: small, subtle, natural mouth movements, softly spoken, gentle and low-key. Do NOT over-articulate. Do NOT exaggerate the jaw or stretch the mouth wide. Keep the mouth movements small and realistic, the way a calm older person speaks quietly.

Body and hands stay alive: [fingers shift and resettle against the mug, one thumb moves slowly across its surface], shoulders rise and fall softly with breathing, and they lean in a touch while speaking. [Ambient motion: gentle wisps of steam drift and curl upward from the hot coffee throughout the shot.]

Warm, kind expression with slow natural blinks and small head nods. Locked-off camera, no zoom, no camera movement.
```

Failure modes and their fixes, all prompt-level:

| Symptom | Cause | Fix |
|---|---|---|
| Mouth too exaggerated, puppet-like | asking for "clear articulate mouth movement" | the restraint clause above, verbatim |
| Body frozen, all motion in the face | a prompt that asked for stillness ("hands stay at rest") | the body-and-hands clause |
| Object fumbled, opened/closed at random | object was mid-manipulation in the still | fix the still, not the prompt |
| Sync soft or drifting | face too small or angled in the still | reframe closer and squarer |

## Lead-in — always

Avatar output starts speaking on frame one, which reads as a truncated or broken video.
Hold the first frame briefly before the voice starts:

```
ffmpeg -vf "tpad=start_duration=0.6:start_mode=clone,fps=24" \
       -af "adelay=600:all=1,loudnorm=I=-14:TP=-1.5:LRA=11"
```

0.6s is a good default. Offset every caption timestamp by the same amount.
