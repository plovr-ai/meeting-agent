# Live Caption Chunked Translation Design

## Context

GitHub issue #36 reports that live caption translation does not balance latency, accuracy, and cost for long same-speaker speech. The current flow appends Deepgram final transcript segments into the transcript file, then `LiveCaptionStore` merges adjacent final segments from the same speaker into one growing turn. Each merge changes the turn text and marks translation pending, so the app repeatedly translates the full accumulated same-speaker text. This creates redundant translation calls, consumes unnecessary context, and makes very long speech hard to display and translate incrementally.

Deepgram streaming responses already distinguish stable transcript spans from utterance boundaries:

- `is_final=true` means Deepgram has finalized that audio span.
- `speech_final=true` means endpointing detected a pause and the current utterance can be considered complete.

`speech_final` is useful, but it cannot be the only boundary because a manager or participant may speak for a long time without a pause. The app needs local fallback boundaries so translation stays live during long monologues.

## Goal

Translate long same-speaker speech incrementally without repeatedly retranslating already completed text. The user should see draft translation updates while the current chunk is still open, and once a chunk freezes, its translation should become stable and never be invalidated by later same-speaker text.

## Non-Goals

- Do not change the audio capture pipeline.
- Do not add a new hosted translation provider.
- Do not translate Deepgram interim transcript text; only translate text derived from `is_final=true` transcript spans.
- Do not redesign the visual caption layout beyond supporting draft and frozen caption states.
- Do not modify saved historical transcript semantics beyond adding backward-compatible metadata.

## Selected Approach

Introduce a live caption chunking layer between finalized transcript segments and translation scheduling.

The chunker keeps one open chunk for the currently active speaker. Incoming `is_final=true` transcript segments are appended to that open chunk. The chunk freezes when any of these conditions is met:

- Deepgram marks the segment with `speech_final=true`.
- The speaker changes.
- The chunk reaches a maximum source-text length, initially 240 characters.
- The chunk audio span reaches a maximum duration, initially 10 seconds when timing is available.
- The chunk ends with strong sentence punctuation and has reached a minimum source-text length, initially 80 characters.

Frozen chunks are stable translation units. They receive one final translation request and are not merged with later same-speaker chunks. Open chunks are draft translation units. They may be retranslated and overwritten while they grow, using throttling so the UI updates without sending a request for every small transcript segment.

## Data Model

Add boundary metadata to `TranscriptSegment` in a backward-compatible way:

- `speechFinal: Bool`, defaulting to `false` when missing from older JSON.

Do not add response-level timing fields in the first implementation. Duration-based chunking should use the earliest `startTimeSeconds` and latest `endTimeSeconds` across the chunk's transcript segments. If those values are unavailable, skip the duration rule for that chunk.

Add draft/frozen metadata to `LiveCaptionTurn`:

- `chunkState: .draft | .frozen`, defaulting to `.frozen` for older data.
- `translationRevision: Int`, defaulting to `0`, used to prevent stale draft translation responses from overwriting newer text.
- `freezeReason: .speechFinal | .speakerChanged | .maxLength | .maxDuration | .punctuation | .manualStop`, optional and mainly useful for tests and diagnostics.

`LiveCaptionTurn.isFinal` should continue to mean the source text comes from finalized STT. `chunkState` is the new concept that determines whether translation may still be revised.

## Deepgram Handling

`URLSessionDeepgramStreamingTranscriptionClient` should include endpointing in the WebSocket query:

- `interim_results=true` remains enabled for future responsiveness, but current code still ignores non-final responses.
- `endpointing=500` should be added as the default meeting-friendly pause threshold.

`DeepgramStreamingResponse` should decode:

- `is_final`
- `speech_final`
- `channel.alternatives[].transcript`
- `channel.alternatives[].words`

`DeepgramStreamingResponseMapper` should preserve existing behavior of returning no segments for `is_final=false`. For `is_final=true`, each produced `TranscriptSegment` should carry `speechFinal=true` only on the final speaker run from that Deepgram message. This prevents a single response with multiple diarized speaker runs from incorrectly ending every run.

## Chunking Behavior

Create a focused `LiveCaptionChunker` type in `Sources/MeetingAgentCore/LiveCaptionChunker.swift`.

Responsibilities:

- Accept finalized `TranscriptSegment` values in transcript order.
- Maintain the current open chunk.
- Emit `LiveCaptionChunkUpdate` values:
  - `.upsertDraft(LiveCaptionTurn)` when the open chunk grows and should be shown or draft-translated.
  - `.freeze(LiveCaptionTurn)` when the current chunk becomes stable.
- Preserve source segment IDs so existing translation keys and realtime translation attachment can stay deterministic.
- Keep chunks speaker-scoped; speaker changes freeze the previous chunk before starting a new draft.

The chunker should not call translation providers and should not read or write files. It is pure state management so it can be covered with fast unit tests.

## Translation Scheduling

Split caption translation scheduling into draft and final paths:

- Draft translation:
  - Applies only to `chunkState == .draft`.
  - May translate repeatedly as the open chunk grows.
  - Runs only when a draft key changes enough to justify a refresh.
  - Initial thresholds: at least 80 new characters since the last draft translation, or at least 2 seconds since the last draft translation attempt.
  - Sends the full current draft chunk to the provider and overwrites that draft turn's `translatedText` when the response matches the latest `translationRevision`.
  - Late responses for older revisions are discarded.

- Final translation:
  - Applies only to `chunkState == .frozen`.
  - Runs once per final translation key.
  - If a draft translation already exists for the same text, keep it visible while final translation is pending.
  - Replaces the draft text when the final provider response returns.
  - Never becomes pending again because later same-speaker text creates a new chunk instead of mutating this frozen chunk.

This preserves realtime feedback for long speech while stopping historical chunks from being retranslated.

## UI Behavior

The caption list should show both draft and frozen turns in normal chronological order.

For a draft turn:

- Original text grows as more finalized STT arrives.
- Translated text updates in place when draft translation responses arrive.
- The health state may be `.pending` while a newer draft translation is in flight, but any existing translated text remains visible.

For a frozen turn:

- Original text no longer changes.
- Translation no longer changes after final translation succeeds.
- Later same-speaker speech appears as a separate draft turn below it.

No visible instructional text is required. The existing pending/live/failed visual treatment can continue to communicate status.

## Error Handling

- If Deepgram does not send `speech_final`, local length/duration/punctuation thresholds still freeze chunks.
- If timing is unavailable, duration-based freezing is skipped and length/punctuation boundaries remain active.
- If draft translation fails, keep the source text visible and allow the next draft key to retry.
- If final translation fails, mark only that frozen chunk failed; later chunks continue translating.
- If recording stops while a draft chunk is open, freeze it with `.manualStop` and schedule final translation.

## Testing

Add unit coverage for:

- Deepgram mapper decodes `speech_final` and only marks the last produced speaker run as speech-final.
- Non-final Deepgram responses still produce no transcript segments.
- Chunker freezes on `speechFinal`.
- Chunker freezes on speaker change.
- Chunker freezes on maximum length without waiting for `speech_final`.
- Chunker freezes on maximum duration when segment timing is available.
- Chunker keeps an open draft and emits upsert updates before freezing.
- Draft translation can update the same turn multiple times.
- Older draft translation responses cannot overwrite newer revisions.
- Frozen chunks are translated once and are not invalidated by later same-speaker text.
- Stopping recording freezes any open draft chunk.

Run the full required suite with `make test` before claiming the implementation is complete.

## Rollout Notes

The first implementation should keep thresholds as internal constants in the chunker, not expose settings. If meeting usage shows different needs for English and Chinese, follow-up work can tune thresholds per locale. The design intentionally keeps saved transcript segments intact; chunking affects live caption turns and translation scheduling, not raw transcript capture.
