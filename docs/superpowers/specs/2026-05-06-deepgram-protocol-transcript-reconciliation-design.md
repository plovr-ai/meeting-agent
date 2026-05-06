# Deepgram Protocol Transcript Reconciliation Design

## Goal

Make Deepgram realtime transcription handling protocol-correct: realtime captions may use mutable interim results, but persisted transcripts, summaries, exports, and persisted translations must be based on Deepgram final results and word timing rather than text-similarity cleanup.

The change must also include a repeatable performance analysis path using repository regression fixtures so we can prove the new behavior is no slower for the realtime path and better for final transcript quality.

## Current State

Deepgram streaming responses are mapped in `DeepgramStreamingResponseMapper` and then written by `DeepgramStreamingTranscriber`. The same `TranscriptSegmentAccumulator` output feeds:

- `RecordingTranscriptPersistenceStore`, which writes `transcript.txt`, `transcript.json`, and `transcript-events.jsonl`.
- `MeetingAgentViewModel.applyTranscriptAccumulationResultsToLiveCaptions`, which drives realtime caption UI and realtime caption translation.
- Summary generation, which reads all segments from `transcript.json`.
- Export and SRT generation, which read the same structured transcript.

`TranscriptSegmentAccumulator` currently contains text-based heuristics such as normalized text overlap, prefix trimming, suffix trimming, and adjacent overlap deduplication. Those heuristics can reduce duplicated artifacts, but they can also delete real repeated speech because they reason about text similarity instead of Deepgram's protocol and word timing.

## Protocol Rules

Deepgram streaming responses must be interpreted with these rules:

- `is_final == false` is a mutable interim result. It can update realtime UI, but it is not a final transcript fact.
- `is_final == true` is Deepgram's finalized text for an audio range. It can be persisted.
- Multiple `is_final == true` results may belong to one utterance. They must be accumulated.
- `speech_final == true` is an endpointing boundary. It closes the current utterance for display and segmentation, but final transcript correctness must not depend on waiting only for `speech_final`.
- Word timestamps and response `start` / `duration` are the authority for whether two results describe the same audio. Text similarity is not authority.

## Design

### 1. Preserve Raw Deepgram Protocol Semantics

`DeepgramStreamingResponseMapper` remains a mapper, not a repair layer. It should expose the response protocol accurately:

- provider ID
- `isFinal`
- `speechFinal`
- speaker
- start/end time
- timing source
- confidence
- transcript text

The mapper must not remove repeated words, trim repeated prefixes, or merge segments by text similarity.

### 2. Add Deepgram Transcript Reconciler

Introduce a small provider-specific reconciler, tentatively `DeepgramTranscriptReconciler`, owned by the Deepgram streaming transcriber path.

The reconciler accepts mapped `TranscriptSegment` values and emits two different update streams:

- `realtimeUpdates`: interim and final segments for the live caption pipeline.
- `finalTranscriptUpdates`: final-only segments for transcript persistence.

Behavior:

- Interim segment:
  - Emit only to realtime updates.
  - Replace prior interim covering the same active audio window.
  - Never persist to `transcript.json` or `transcript.txt`.

- Final segment:
  - Emit to realtime updates.
  - Emit to final transcript updates.
  - If the final segment has the same ID as an existing final segment, replace it.
  - If it has precise timing and overlaps an existing final segment from the same provider and compatible speaker, reconcile by timing:
    - If the incoming segment covers the same audio range, replace the existing segment.
    - If the incoming segment partially overlaps, keep only non-overlapping audio ranges when word timing makes that possible.
    - If word timing is not enough to split safely, prefer replacing the overlapped range over appending duplicate audio.
  - If timing does not overlap, append, even when the text is identical.
  - If precise timing is unavailable, append conservatively and do not run text deduplication.

- `speechFinal == true`:
  - Mark the latest final segment as an utterance boundary.
  - Close the current utterance buffer used for realtime display and downstream segmentation.
  - Do not discard previous final segments in the utterance.

This keeps true repetitions such as "very very important" or repeated phrases with separate timestamps intact.

### 3. Split Realtime And Final Update Semantics

The current `TranscriptSegmentUpdate.upsert` does not distinguish realtime draft updates from final transcript updates. Add an explicit update kind or separate sink method so downstream consumers know which semantic they are receiving.

Recommended shape:

- `TranscriptUpdateSink.receiveRealtime(_ update: TranscriptSegmentUpdate)`
- `TranscriptUpdateSink.receiveFinal(_ update: TranscriptSegmentUpdate)`

or equivalent enum:

- `.realtime(TranscriptSegmentUpdate)`
- `.final(TranscriptSegmentUpdate)`

Rules:

- `RecordingTranscriptPersistenceStore` accepts only final updates.
- `LiveCaptionPipeline` receives realtime updates and final updates.
- Summary, export, meeting store provider backfill, and clipboard transcript rendering read only final persisted transcript files.

### 4. Remove Text-Similarity Cleanup From Deepgram Final Transcript Path

The Deepgram final transcript path must not call the accumulator's text-overlap cleanup functions. These functions should either be removed or restricted away from Deepgram final persistence:

- `normalizedTextsOverlap`
- `deduplicatedAdjacentOverlaps`
- `trimmedCoveredInterimPrefixes`
- `trimmedInterimPrefixesCoveredByPreviousFinals`
- `trimmedInterimSuffixesCoveredByFollowingFinals`
- `trimmedFinalPrefixesCoveredByPreviousSegments`
- token prefix/suffix overlap helpers used only for text deduplication

If non-Deepgram providers still need a defensive accumulator, that behavior must be provider-specific and must not affect Deepgram final transcript persistence.

### 5. Translation Impact

Translation remains two-track:

- Realtime caption translation consumes live caption turns, including interim text, and publishes UI overlay only.
- Persisted transcript translation patches only final persisted segments.

Draft translations may be carried forward visually in the realtime UI when a final segment replaces an interim segment, but draft translation must not patch a final transcript segment unless the final segment is explicitly matched by provider ID, compatible speaker, and overlapping timing.

When recording stops:

- Cancel realtime translation work that has not attached to the live UI.
- Allow future offline final transcript translation to run as a separate task if needed.
- Do not let realtime translation backlog delay final transcript flush or summary generation.

### 6. Summary And Export Impact

Summary generation must run after final transcript flushing. It should read only `transcript.json` final segments.

Export and SRT generation continue reading `transcript.json`, but they benefit from:

- fewer duplicate transcript artifacts
- more accurate cue timing
- no accidental deletion of true repeated speech

Historical meetings are not migrated as part of this change. Old meetings remain readable with existing stored files.

## Performance Requirements

The implementation must include a repeatable before/after performance analysis.

Fixtures:

- `Tests/MeetingAgentCoreTests/Fixtures/latest-source-caption-regression.wav`
- `Tests/MeetingAgentCoreTests/Fixtures/latest-meeting-deepgram-x.log`

Required metrics:

- time to first realtime caption
- realtime caption update count
- time to first final transcript segment
- time to final transcript completion after audio input completes
- number of persisted final segments
- number of persisted interim segments, expected to be zero for Deepgram
- duplicate audio-range count, expected to be zero for overlapping final ranges
- true repeated text preservation count for non-overlapping timestamps
- `transcript_segment_written` and `transcript_segment_persisted` event counts
- post-stop translation event count, to verify translation does not block transcript finalization

Acceptance criteria:

- Realtime time-to-first-caption is not worse than the current baseline by more than 100 ms on fixture replay.
- Final transcript completion is not worse than the current baseline by more than 250 ms on fixture replay.
- Persisted Deepgram interim segment count is zero.
- Overlapping final audio ranges do not produce duplicated persisted text.
- Non-overlapping repeated text is preserved.
- Summary input contains only final segments.
- Realtime caption translation remains active for interim captions but does not write interim translation into final transcript.

## Test Plan

Add focused unit tests before implementation:

- Deepgram mapper preserves `is_final`, `speech_final`, speaker, and timing.
- Reconciler emits interim segments only to realtime updates.
- Reconciler persists multiple `is_final == true, speech_final == false` segments in order.
- Reconciler marks utterance boundary when `speech_final == true`.
- Reconciler replaces overlapping final results by timing without text similarity.
- Reconciler preserves identical text when timestamps do not overlap.
- Reconciler appends conservatively when timing is unavailable.
- Recording persistence rejects or ignores Deepgram interim updates.
- Summary input excludes interim segments.
- Realtime caption pipeline still receives interim captions.
- Realtime caption translation does not patch final transcript from draft-only translation.

Add regression/performance tests:

- Replay `latest-meeting-deepgram-x.log` through mapper and reconciler and assert protocol-level transcript invariants.
- Use `latest-source-caption-regression.wav` as fixed audio input for a scripted before/after performance report where network-dependent provider calls are mocked or replayed.

## Rollout Plan

1. Add protocol-focused tests around Deepgram stream reconciliation.
2. Introduce the Deepgram reconciler without changing UI behavior.
3. Split realtime and final update delivery.
4. Route final-only updates to transcript persistence.
5. Route realtime updates to live captions and realtime translation.
6. Remove Deepgram final transcript dependence on text-similarity cleanup.
7. Add fixture-based performance reporting.
8. Run `make test` and compare performance report with the baseline.

## Non-Goals

- Do not tune Deepgram `endpointing` in this change.
- Do not use LLM cleanup for transcript deduplication.
- Do not migrate historical meeting transcripts.
- Do not remove realtime interim captions.
- Do not make translation block realtime captions or final transcript flushing.
