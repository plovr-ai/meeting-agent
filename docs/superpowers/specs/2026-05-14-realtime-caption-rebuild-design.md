# Realtime Caption Rebuild Design

## Goal

Replace the current realtime transcript and caption architecture with a provider-agnostic caption domain that uses model-provided speaker evidence, displays speaker-separated realtime captions, supports draft correction without duplicate incremental lines, and makes `transcript.json` the only transcript source of truth.

Historical meeting compatibility is intentionally out of scope. Existing meeting data may be deleted. Meeting post-processing assets such as summaries, progress files, diagnostics, knowledge packages, and markdown analysis outputs should remain supported as derived assets.

## Chosen Architecture

Use the Provider Events -> Caption Reducer -> Transcript Store architecture.

```text
Audio
  -> Provider Adapter
  -> SpeechRecognitionEvent
  -> CaptionReducer
  -> MeetingTranscriptStore
  -> UI / Summary / Export / Meeting Progress / Knowledge Assets
```

Provider adapters are thin. They translate provider-native responses into a common event protocol and preserve model evidence such as speaker IDs, word timing, confidence, language, punctuation, and `speech_final`. They do not decide how the product groups speakers, replaces drafts, or segments readable turns.

The `CaptionReducer` is the product source of truth during recording. It owns draft replacement, final promotion, speaker turn separation, readable boundary decisions, and transcript snapshots.

`MeetingTranscriptStore` persists only the reducer's canonical document. It does not persist provider interim hypotheses as transcript facts.

## Event Protocol

The realtime path should use a provider-neutral event type:

```swift
enum SpeechRecognitionEvent {
    case hypothesis(SpeechUtterancePayload)
    case final(SpeechUtterancePayload)
    case providerStatus(ProviderStatus)
}
```

The shared payload should include:

```swift
struct SpeechUtterancePayload {
    let providerID: String
    let providerUtteranceID: String?
    let fallbackKey: SpeechUtteranceKey
    let speaker: TranscriptSpeaker?
    let startTimeSeconds: Double?
    let endTimeSeconds: Double?
    let text: String
    let language: String?
    let confidence: Double?
    let boundary: SpeechBoundary
}
```

`SpeechBoundary` should represent evidence, not product decisions:

```swift
struct SpeechBoundary {
    let speechFinal: Bool
    let punctuationFinal: Bool
    let pauseDurationSeconds: Double?
}
```

Provider identity rules:

- Prefer stable provider utterance IDs when available.
- If a provider's IDs or start times drift during streaming, the reducer may match a new event to an active hypothesis using provider ID, speaker, timing overlap or closeness, and text revision similarity.
- Provider adapters must not invent speaker separation. If the model provides no speaker, use an unknown speaker identity.

## Caption Domain Model

The canonical document should model meeting captions directly, not translation-era transcript segments.

```swift
struct CaptionDocument {
    var version: Int
    var provider: TranscriptProviderInfo?
    var speakers: [CaptionSpeaker]
    var turns: [CaptionTurn]
}

struct CaptionTurn {
    let id: String
    var speakerID: String?
    var speakerLabel: String?
    var text: String
    var startTimeSeconds: Double?
    var endTimeSeconds: Double?
    var isFinal: Bool
    var boundaryReason: CaptionBoundaryReason?
    var source: CaptionTurnSource
}
```

`TranscriptSpeaker` can remain as the base speaker identity type if it continues to fit the codebase, but the new persisted format should be turn-based and speaker-based, not `TranscriptSegment` based.

`CaptionTurnSource` should preserve enough audit information to debug provider behavior:

- provider ID
- provider utterance IDs included in the turn
- confidence, if available
- language, if available

It must not reintroduce translation-era `sourceSegmentIDs` as a projection invariant.

## Reducer Behavior

### Hypothesis Updates

When a hypothesis arrives:

- Match an existing active hypothesis by provider utterance ID when possible.
- Otherwise match by fallback key: same provider, compatible speaker, overlapping or close time range, and text revision relationship.
- Replace the existing visible draft text in place.
- Do not append `A`, `AB`, and `ABC` as separate visible lines.
- If no active hypothesis matches, create a new draft turn.

Allowed visible behavior:

```text
我
我们
我们确认
```

as one changing line, not three accumulated lines.

### Final Promotion

When a final event arrives:

- If it matches an active hypothesis, promote that draft turn to final.
- Replace text and timing with final provider values.
- Remove the active hypothesis.
- Do not append a second turn for the same utterance.
- If no active hypothesis matches, create a final turn.

Final promotion must be idempotent. Receiving the same final evidence twice must not duplicate the turn or duplicate source references.

### Speaker Separation

Different model-provided speakers naturally create different turns and different UI groups.

Rules:

- Speaker change is always a boundary.
- Consecutive turns from the same speaker may remain in the same visual speaker group.
- If the provider only emits one speaker, the app must not fabricate two speakers.
- Speaker label edits update the speaker table and all rendered turns that reference that speaker.

### Readable Segmentation

Readable segmentation must only use these boundaries:

- speaker change
- provider `speechFinal`
- sentence-ending punctuation
- explicit pause duration above a configured threshold

Do not split by character count or word count.

If a same-speaker utterance becomes long without pause, punctuation, or speech final, it remains one turn and grows. UI text wrapping may make it readable visually, but data-level segmentation must not create artificial turns.

Punctuation boundary support should include common Chinese and English sentence-ending punctuation:

- Chinese: `。`, `！`, `？`
- English: `.`, `!`, `?`

Soft visual wrapping is a UI concern. It must not create additional transcript turns or affect summary/export/progress analysis.

## Persistence

`transcript.json` is the only transcript source of truth.

Do not generate or persist `transcript.txt` as an internal meeting asset.

Meeting directory assets:

- Keep `audio.wav` as raw evidence.
- Keep `performance-events.jsonl` as diagnostics and telemetry.
- Keep `transcript.json` as the only transcript file, using the new v2 document.
- Keep post-meeting derived assets such as `summary.json`, `summary.md`, `meeting-progress.json`, `diagnostics.json`, knowledge packages, and markdown analysis outputs.
- Do not keep a second transcript representation alongside `transcript.json`.

Human-readable transcript text should be rendered on demand from `transcript.json` for UI display or explicit export. Exported transcript files are user-requested output, not internal meeting state.

## Downstream Consumers

All downstream consumers should move to `CaptionDocument`:

- UI renders `CaptionDocument.turns`, grouped by consecutive speaker blocks.
- Summary reads final turns from `transcript.json`.
- Export reads final turns from `transcript.json`.
- SRT/VTT generation reads final turns with timing.
- Meeting progress analyzes final or recently-finalized turns.
- Speaker editing updates the document speaker table.
- Derived markdown and knowledge assets are regenerated from the canonical document.

No internal path should read `transcript.txt`.

## Old Architecture Removal

The following should be removed from the realtime transcript and caption main path:

- `LiveCaptionPipeline`
- `RealtimeCaptionSession`
- `CaptionTurnAssembler`
- `LiveCaptionChunker`
- realtime usage of `TranscriptSegmentAccumulator`
- translation-era caption projection invariants
- historical transcript replay/backfill as a maintained requirement

The following may be retained if they remain useful after refactoring:

- `TranscriptSpeaker` as a speaker identity value.
- `PerformanceEventLogger`, after making writes serial and JSONL-safe.
- Meeting post-processing providers, after changing their inputs to `CaptionDocument`.

## Diagnostics

Diagnostics should make provider behavior and reducer behavior inspectable without polluting the transcript.

Recommended events:

- provider event received
- hypothesis matched existing draft
- hypothesis created new draft
- final promoted draft
- final created turn
- speaker boundary created
- pause boundary created
- punctuation boundary created
- speech final boundary created
- duplicate final ignored

`performance-events.jsonl` must be valid JSONL. Concurrent writes must not interleave partial lines.

## Testing Strategy

Reducer tests:

- `A -> AB -> AC` updates one visible draft.
- final promotes draft without duplicate turn.
- duplicate final is idempotent.
- different speakers create separate turns.
- same speaker without pause, punctuation, or speech final stays in one turn.
- same speaker with pause creates a new turn.
- same speaker with sentence-ending punctuation creates a boundary.
- same speaker with `speechFinal` creates a boundary.
- long CJK text without pause, punctuation, or speech final does not split by character count.

Adapter tests:

- Deepgram speaker IDs map to speaker identities.
- Deepgram `speech_final` maps to `SpeechBoundary.speechFinal`.
- Deepgram punctuation maps to `SpeechBoundary.punctuationFinal`.
- Deepgram interim responses produce hypothesis events.
- Deepgram final responses produce final events.
- Provider ID or timing drift can still update one active hypothesis through reducer fallback matching.

Persistence tests:

- `transcript.json` v2 encodes and decodes.
- Meeting recording does not create `transcript.txt`.
- Speaker label edits update the speaker table and rendered turns.
- Summary/export/progress read the new document.

Integration tests:

- A recording with provider speaker 0 and speaker 1 shows separate UI speaker groups.
- A recording with only speaker 0 does not invent another speaker.
- Realtime draft corrections replace a line instead of accumulating incremental lines.
- Meeting post-processing assets still generate from the new transcript document.
- `performance-events.jsonl` remains valid JSONL after concurrent recording activity.

## Acceptance Criteria

1. Realtime captions use model-provided speaker information when available.
2. Different speakers appear naturally separated in the UI.
3. Same-speaker text only segments on speaker change, pause, punctuation, or `speechFinal`.
4. Same-speaker text never segments by character count or word count.
5. Interim text correction replaces the visible draft instead of accumulating `A`, `AB`, `ABC` lines.
6. Final text promotes the matching draft and does not duplicate the turn.
7. Providers are decoupled from product caption logic through `SpeechRecognitionEvent`.
8. `transcript.json` is the only internal transcript file.
9. `transcript.txt` is not generated as a meeting asset.
10. Existing meeting post-processing assets such as summaries, progress, diagnostics, knowledge packages, and markdown outputs remain supported as derived assets.
11. `performance-events.jsonl` remains valid JSONL.
