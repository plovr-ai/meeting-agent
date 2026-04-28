# Live Caption Boundary Model Design

## Context

Deepgram streaming output exposes two different stability signals. `is_final=true` means a recognition window has stabilized enough to use, while `speech_final=true` means Deepgram believes an utterance boundary has been reached. The current live caption pipeline uses one `chunkState=frozen` concept for both UI sealing and translation finality. That makes the system fragile: if UI-friendly chunking freezes a block early, translation may treat a soft display boundary as a semantic boundary; if the app waits only for `speech_final`, the UI can show very large `User A` turns and delayed translation.

Recent meeting logs show this clearly. Deepgram can return long same-speaker final windows with `speech_final=false`, even when the text already contains complete sentences. The UI should not keep growing one large speaker row, but translation should also not permanently lose context because of a local punctuation, duration, or length heuristic.

## Goal

Separate recognition stability, UI display boundaries, and translation finality so the app can show readable live captions without damaging translation accuracy.

The design should:

- Keep original captions responsive as soon as Deepgram emits stable text.
- Prevent one speaker from visually becoming a very large turn.
- Avoid repeated `User A` labels when the same speaker is only split for readability.
- Let soft UI chunks receive draft translation quickly.
- Treat `speech_final`, speaker changes, and manual stop as semantic hard boundaries for final translation.
- Preserve or refresh draft translations without clearing already visible text.

## Non-Goals

- Do not change Deepgram API options as part of this design.
- Do not require word-level semantic parsing or LLM-based boundary detection before captions appear.
- Do not redesign the whole transcript export format.
- Do not remove existing local heuristics; instead, make their effects explicit and limited to display/draft translation.

## Boundary Model

### Recognition Segment

`TranscriptSegment` remains the provider-normalized input:

- `isFinal`: stable recognition window. `true` means the app can update live captions.
- `speechFinal`: semantic utterance signal from Deepgram. `true` is a hard boundary.
- speaker, timing, provider, and text metadata remain unchanged.

### Caption Block

A caption block is a readable UI unit. It can be sealed for display without being final for translation.

Fields to model explicitly:

- `displayState`: `draft` or `sealed`.
- `translationState`: `draft`, `pendingFinal`, or `final`.
- `boundaryReason`: `speechFinal`, `speakerChanged`, `manualStop`, `punctuation`, `maxDuration`, or `maxLength`.
- `boundaryStrength`: `hard` or `soft`.

Soft boundaries seal a display block but keep translation draftable. Hard boundaries finalize the current translation unit.

### Speaker Group

A speaker group is a consecutive run of caption blocks from the same speaker. The UI shows the speaker label once per group. Multiple caption blocks inside the same group are separated by line breaks or subtle spacing, not repeated labels.

Example:

```text
User A
My name is Sherwin Chaffee, and I work at Microsoft as a copilot principal technical specialist.
Now on this channel, we often build our own autonomous agents

But today, I'm very excited to share an agent that Microsoft has built

and that is the interpreter agent. So I just
```

When the speaker changes, a new group starts:

```text
User A
No. It works.

User B
It works very well.
```

## Boundary Semantics

| Boundary reason | Display block sealed | Translation final | New speaker label |
| --- | --- | --- | --- |
| `speechFinal` | yes | yes | no, unless next speaker differs |
| `speakerChanged` | yes | yes | yes |
| `manualStop` | yes | yes | no |
| `punctuation` | yes | no | no |
| `maxDuration` | yes | no | no |
| `maxLength` | yes | no | no |

`speechFinal` is the strongest provider signal and should always finalize the active translation unit. Local punctuation, duration, and length rules are product heuristics. They improve readability and latency, but must not become permanent semantic translation boundaries.

## Data Flow

1. Deepgram emits a result.
2. The mapper writes or updates `TranscriptSegment`.
3. `MeetingAgentViewModel` reads structured transcript segments.
4. `LiveCaptionChunker` converts final recognition segments into caption block updates.
5. `LiveCaptionStore` stores display blocks and speaker grouping state.
6. The UI renders speaker groups, not one label per caption block.
7. The translation scheduler decides draft or final translation from boundary strength.

## Translation Scheduling

Draft translation:

- Triggered by soft-sealed caption blocks and sufficiently mature draft text.
- Uses the current block plus adjacent same-speaker context from the active speaker group.
- May be refreshed as more same-speaker text arrives before a hard boundary.
- Must not clear already visible draft translation while a newer request is in flight.
- Older draft responses must not overwrite newer draft or final translations.

Final translation:

- Triggered by a hard boundary.
- Uses all soft blocks in the active translation unit as source context.
- Marks the affected blocks or group translation as final.
- Should not be overwritten by later draft responses.

This means UI can show fast draft translation for soft chunks while final translation remains aligned to semantic boundaries.

## UI Behavior

The live transcript should render a list of speaker groups. Each group contains one or more caption blocks:

- Show the speaker name once at the top of the group.
- Use paragraph spacing or line breaks between sealed blocks inside the same group.
- Keep the active draft block at the bottom of the current speaker group.
- Update draft text in place when Deepgram revises the same active segment.
- Start a new speaker group only when the speaker actually changes.

This avoids both extremes: huge unbroken `User A` turns and repeated `User A` labels for the same continuous speaker.

## Affected Components

- `Sources/MeetingAgentCore/LiveMeetingCockpit.swift`
  - Split `chunkState` semantics into display and translation state, or add compatible fields while preserving legacy decoding.
  - Preserve boundary reason and strength on caption blocks.
- `Sources/MeetingAgentCore/LiveCaptionChunker.swift`
  - Emit soft versus hard boundary metadata.
  - Keep existing local readability heuristics but mark them as soft.
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
  - Schedule draft translations for soft blocks and final translations for hard boundaries.
  - Preserve visible draft translation while newer context-aware translation is pending.
- `Sources/MeetingAgentApp/MainWindowView.swift`
  - Render speaker groups so repeated same-speaker caption blocks do not repeat the speaker label.
- `Tests/MeetingAgentCoreTests/`
  - Add coverage for soft versus hard boundaries, speaker grouping, and translation overwrite ordering.

## Compatibility

Existing persisted live caption data may only have `chunkState`. Decoding should map legacy `draft` to `displayState=draft, translationState=draft` and legacy `frozen` to `displayState=sealed`. If no boundary reason exists, use a conservative default that preserves current display behavior without marking translation final unless the stored reason is known to be hard.

## Test Plan

- Deepgram long same-speaker `speech_final=false` segment with internal punctuation seals a display block but keeps translation draft.
- Same speaker continues after a soft display boundary and the UI renders one speaker label with multiple blocks.
- `speech_final=true` seals the current display block and marks translation final.
- Speaker changed seals and finalizes the previous translation unit, then starts a new speaker group.
- Soft draft translation remains visible while a refreshed draft request is in flight.
- Final translation is not overwritten by an older draft response.
- Legacy `chunkState` decoding keeps existing transcript display behavior.
- Run `make test`.
