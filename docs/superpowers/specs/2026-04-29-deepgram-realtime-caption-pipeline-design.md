# Deepgram Realtime Caption Pipeline Design

## Context

The realtime caption architecture is moving toward a provider-neutral pipeline, but the first implementation pass should optimize and align the primary production path:

```text
Deepgram streaming STT -> canonical transcript -> stable live captions -> hosted text translation
```

Whisper and OpenAI Realtime remain supported provider families, but this design does not tune their behavior. They must keep fitting the same provider boundary so future work can improve them without changing caption assembly, translation scheduling, or UI state.

The current code already has many of the right pieces:

- `DeepgramStreamingSpeechTranscriptionProvider` streams interim and final `TranscriptSegment` values.
- `TranscriptSegmentAccumulator` normalizes transcript updates into a canonical `TranscriptDocument`.
- `LiveCaptionChunker` groups final transcript segments into caption turns.
- `LiveCaptionStore` stores visible caption turns.
- `MeetingAgentViewModel` currently owns most caption assembly and translation scheduling.

The main design problem is that realtime caption behavior is spread across the ViewModel, store, chunker, and translation queue state. The next architecture should make the Deepgram path explicit and testable without changing the user-facing product in one risky step.

## Goals

- Make Deepgram streaming the first-class realtime caption chain.
- Keep all STT providers behind the same `TranscriptSegmentUpdate` boundary.
- Route active captions from in-memory transcript updates, not transcript file reloads.
- Turn Deepgram interim and final segments into stable caption turns without duplicate or jumping text.
- Separate caption assembly from translation scheduling.
- Preserve canonical transcript behavior for export, summary, retry, edits, and history.
- Keep Whisper and OpenAI Realtime as provider adapters that can be tuned later without changing downstream pipeline code.

## Non-Goals

- Do not tune local Whisper latency or chunking in this pass.
- Do not make OpenAI Realtime delta events visible.
- Do not add realtime speech translation.
- Do not introduce model-specific UI behavior.
- Do not replace the existing hosted text translation provider.
- Do not change summary, export, or transcript editing behavior except where they consume the shared canonical transcript.

## Architecture

The target runtime chain is:

```text
AudioFrame
  -> DeepgramStreamingSpeechTranscriptionProvider
  -> TranscriptSegmentUpdate
  -> TranscriptSegmentAccumulator
  -> LiveCaptionPipeline
  -> CaptionTurnAssembler
  -> CaptionTranslationScheduler
  -> LiveCaptionStore
  -> MeetingAgentViewModel
  -> SwiftUI
```

The model boundary is:

```text
Provider-specific audio/STT behavior
  -> TranscriptSegmentUpdate
Provider-specific translation behavior
  -> translated caption text
```

No downstream caption assembly, translation scheduling, or UI code should branch on Deepgram-specific response JSON. Downstream code may read generic segment metadata such as `sourceProvider`, `speaker`, `confidence`, `timingSource`, `startTimeSeconds`, and `endTimeSeconds`.

## Core Types

### TranscriptSegmentUpdate

This remains the provider-to-core event:

```swift
public enum TranscriptSegmentUpdate {
    case upsert(TranscriptSegment)
    case replaceAll([TranscriptSegment])
    case replaceWithPlainText(String)
}
```

Deepgram streaming should emit `upsert` for interim and final segments. Batch retry paths may emit `replaceAll`.

### TranscriptSegmentAccumulator

The accumulator is the single owner of canonical transcript normalization:

- same-ID interim updates
- interim-to-final replacement
- Deepgram shifted-ID dedupe
- covered interim pruning
- adjacent final/interim overlap handling
- translation cache preservation when text is unchanged
- plain-text failure replacement

The accumulator does not know about visible caption turns or translation scheduling.

### LiveCaptionPipeline

Add a core pipeline object that owns the caption hot path:

```swift
public struct LiveCaptionPipelineSnapshot: Equatable {
    public var turns: [LiveCaptionTurn]
    public var captionHealth: LivePipelineHealth
    public var translationHealth: LivePipelineHealth
}

public final class LiveCaptionPipeline {
    public func apply(_ result: TranscriptSegmentAccumulationResult) async -> LiveCaptionPipelineSnapshot
    public func replay(_ document: TranscriptDocument) async -> LiveCaptionPipelineSnapshot
    public func flush(reason: LiveCaptionFreezeReason) async -> LiveCaptionPipelineSnapshot
    public func reset(sourceLocale: String, targetLocale: String)
}
```

Responsibilities:

- Accept canonical transcript accumulation results.
- Apply changed segments to the caption assembler.
- Update visible caption turns in the store.
- Schedule draft and final caption translations.
- Return a snapshot for the ViewModel to publish.

The ViewModel should no longer own caption chunking details, draft/final translation queues, or translation de-duplication maps.

### CaptionTurnAssembler

Evolve `LiveCaptionChunker` into a caption assembler that handles Deepgram interim and final behavior:

```swift
public enum CaptionTurnEvent: Equatable {
    case draftUpdated(LiveCaptionTurn)
    case sealed(LiveCaptionTurn)
    case removed(turnID: String)
}

public struct CaptionTurnAssembler {
    public mutating func apply(_ segment: TranscriptSegment) -> [CaptionTurnEvent]
    public mutating func removeSegments(notIn segmentIDs: Set<String>) -> [CaptionTurnEvent]
    public mutating func flush(reason: LiveCaptionFreezeReason) -> [CaptionTurnEvent]
}
```

Rules:

- Interim segments update the current draft turn.
- Final segments replace or merge the corresponding draft text.
- `speechFinal` produces a hard boundary.
- Speaker changes produce a hard boundary.
- Manual stop produces a hard boundary.
- Punctuation, max duration, and max length produce soft boundaries.
- Soft boundaries may keep receiving related final text if the same speaker continues.
- Hard boundaries close a turn and make it eligible for final translation.
- Removed interim segments remove or update only draft display state.

The assembler must be deterministic: replaying a transcript document should produce the same stable turns as receiving the same segments incrementally after accumulator normalization.

### LiveCaptionStore

Reduce `LiveCaptionStore` to visible state storage:

- upsert turn
- remove turn
- attach draft translation
- attach final translation
- mark translation complete without text for same-language captions
- mark translation failed
- reset locales

It should not decide complex merge behavior. That belongs to `CaptionTurnAssembler`.

### CaptionTranslationScheduler

Move the translation queue out of `MeetingAgentViewModel`.

Responsibilities:

- Skip provider calls for same-language captions.
- Schedule draft translations for draft or soft-sealed turns.
- Schedule final translations for hard-sealed turns.
- Prioritize final translations over draft translations.
- Cancel superseded draft translations.
- Avoid repeated draft calls unless text changed meaningfully or enough time passed.
- Limit concurrency.
- Report translation health.
- Log performance events.

Default policy:

```text
max concurrent translations: 2
max concurrent draft translations: 1
minimum draft character delta: 80
minimum draft interval: 2 seconds
final translation eligibility: hard-sealed turns only
draft translation eligibility: draft or soft-sealed turns
```

Final translations should overwrite draft translations and mark the turn translation as final.

## Deepgram-Specific Alignment

Deepgram provider code remains the only layer that understands Deepgram WebSocket responses.

The provider should continue to request:

- `encoding=linear16`
- `sample_rate` from the capture stream
- `channels` from the capture stream
- `smart_format=true`
- `punctuate=true`
- `diarize=true`
- `interim_results=true`
- `endpointing=500`

The mapper should continue translating Deepgram responses into generic `TranscriptSegment` values:

- `isFinal` from Deepgram `is_final`
- `speechFinal` from Deepgram `speech_final`
- speaker runs as `TranscriptSpeaker(identifier: "deepgram-speaker-N")`
- word timing as `startTimeSeconds` and `endTimeSeconds`
- confidence from the selected alternative
- detected language when available
- provider ID as `deepgram-transcribe`

The downstream pipeline should use `speechFinal`, speaker, timing, and text overlap as generic transcript metadata. It should not inspect Deepgram raw JSON.

## ViewModel Flow

Active recording:

```text
MeetingAgentViewModel.drainRecordingFrames()
  -> recorder.drainTranscriptUpdates()
  -> liveCaptionPipeline.apply(...)
  -> publish liveCaptionTurns and health
```

Historical or cold path:

```text
select meeting or edit transcript
  -> read transcript.json
  -> liveCaptionPipeline.replay(document)
  -> publish liveCaptionTurns and health
```

The ViewModel remains responsible for:

- selected meeting state
- recording lifecycle
- user settings
- summary/export/edit commands
- publishing `@Published` properties

The ViewModel should not manage:

- caption segment signatures
- open caption chunk state
- draft translation request maps
- final translation in-flight sets
- translation throttling policy

## Error Handling

STT provider failure:

- WAV recording continues where possible.
- Transcript sink receives plain-text failure replacement when appropriate.
- Caption health becomes `failed`.
- Translation scheduling stops for new failed/plain-text states.

Translation failure:

- Original caption remains visible.
- The affected turn is marked failed.
- Translation health becomes `degraded` if some captions are still usable, or `failed` if all pending translations fail.
- Transcript persistence, summary, and export are not blocked.

Persistence failure:

- Live captions keep using in-memory pipeline state.
- Recorder records/logs the persistence failure.
- The UI should not recover by reloading transcript files on the active hot path.

Provider metadata gaps:

- Missing speaker becomes default speaker.
- Missing timing uses `.unavailable`.
- Missing language falls back to configured source locale.
- Missing confidence remains nil.

## Migration Plan

1. Add `LiveCaptionPipeline` as a wrapper around existing caption and translation behavior.
2. Move ViewModel caption state and scheduling maps into the pipeline without behavior changes.
3. Rename or replace `LiveCaptionChunker` with `CaptionTurnAssembler`, preserving existing final-segment behavior first.
4. Extend the assembler to own interim draft behavior and removed-interim handling.
5. Reduce `LiveCaptionStore` to visible-state persistence.
6. Route historical replay through the same pipeline.
7. Delete migrated ViewModel private state and helper methods.
8. Keep Deepgram as the default hosted realtime STT path.

## Tests

Add focused tests for the Deepgram main path:

- Deepgram interim updates one draft turn without duplication.
- Deepgram final replaces the matching draft text.
- Deepgram shifted IDs do not duplicate visible captions after accumulator normalization.
- `speechFinal` seals a turn with hard boundary.
- speaker change seals the previous turn with hard boundary.
- punctuation, max duration, and max length create soft boundaries.
- soft boundary schedules draft translation only.
- hard boundary schedules final translation and cancels superseded draft translation.
- same-language captions complete without provider calls.
- translation failure preserves original caption text.
- active recording captions consume recorder updates without transcript file reload.
- historical replay produces the same turn sequence for the same canonical transcript.

Existing tests around `TranscriptSegmentAccumulator`, `DeepgramStreamingTranscriptionProvider`, `LiveCaptionStore`, and `MeetingAgentViewModel` should be updated rather than duplicated where possible.

## Acceptance Criteria

- Deepgram streaming is the explicitly aligned primary realtime caption path.
- Provider-specific behavior ends at `TranscriptSegmentUpdate`.
- Caption assembly and translation scheduling live outside `MeetingAgentViewModel`.
- Active realtime captions do not rely on transcript file reloads.
- Draft translations are throttled and replaceable.
- Final translations are only created for hard-sealed turns.
- The same canonical transcript can drive active UI, historical replay, export, and summary.
- Whisper and OpenAI Realtime can be tuned later by changing provider adapters, not caption pipeline architecture.
