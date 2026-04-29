# Stream Live Transcript Updates Design

## Context

Issue #82 changes the live transcript architecture so active meetings no longer use persisted transcript files as the realtime handoff between transcription and UI. The current hot path has transcribers write `transcript.json` / `transcript.txt`, then `MeetingAgentViewModel.refreshLiveCaptionTurnsFromSelectedMeeting()` reloads and replays the full structured transcript. That couples live caption latency and UI responsiveness to disk IO, full JSON decode, and repeated full-document scans.

The latest `origin/main` already removed the realtime speech translation chain in #88. OpenAI realtime transcription remains supported and must be included in this transcript update architecture.

## Goals

- Route all transcription providers through one transcript update pipeline.
- Move STT segment normalization and dedupe out of `TranscriptFileWriter` into a shared in-memory component.
- Drive active live captions from memory events instead of file reloads.
- Keep transcript files as persisted artifacts for history, export, manual edits, retry output, summaries, and reopened meetings.
- Preserve existing transcript behavior: interim replacement, final replacement, Deepgram shifted-ID pruning, covered interim pruning, speaker labels, plain-text failure fallback, and translation cache preservation.

## Non-Goals

- Do not add async batched persistence in this change. Persistence remains synchronous for now.
- Do not restore or redesign realtime speech translation removed by #88.
- Do not make OpenAI realtime transcription deltas visible in the transcript document. Completed transcription items enter the pipeline as final updates.
- Do not change user-facing transcript editing or export behavior beyond routing through the shared transcript normalization logic.

## Design

### Core Types

Add a shared transcript pipeline in `MeetingAgentCore`:

- `TranscriptSegmentUpdate`: unified provider event. It represents either an `upsert(TranscriptSegment)`, a `replaceAll([TranscriptSegment])`, or a failure/plain-text replacement when needed.
- `TranscriptSegmentAccumulator`: pure in-memory reducer. Given a current `TranscriptDocument` and an update, it returns the canonical updated document. It owns the STT normalization rules currently embedded in `TranscriptFileWriter.upsert()`.
- `TranscriptUpdateSink`: a small boundary for consumers of transcript updates. The initial sink can be synchronous, but the protocol must not assume synchronous persistence forever.

`TranscriptFileWriter` remains responsible for artifact IO, reading, rendering, speaker label updates, segment text updates, translation cache updates, and plain-text fallback. Its STT upsert path should delegate to `TranscriptSegmentAccumulator` instead of holding private dedupe rules.

### Provider Flow

All providers produce transcript updates:

- Deepgram streaming emits `upsert` updates for interim and final segments.
- OpenAI realtime transcription emits `upsert` updates for completed transcription items. Delta events remain ignored by the persisted transcript and live captions in this version.
- Whisper/local/batch retry emits `replaceAll` updates after producing complete segment arrays.

Each provider still persists through a transcript sink, but persistence is no longer the synchronization mechanism for active live captions.

### Recorder And ViewModel Flow

`MeetingRecorder` becomes the active meeting update hub:

1. It starts the transcriber with a transcript update sink.
2. The sink applies updates to the active accumulator.
3. The sink synchronously persists the canonical document through `TranscriptFileWriter`.
4. The recorder exposes drained canonical updates to `MeetingAgentViewModel`.

`MeetingAgentViewModel.drainRecordingFrames()` updates active live captions from recorder transcript updates after draining audio frames. It should not call full `transcript.json` reload for the active recording hot path.

`refreshLiveCaptionTurnsFromSelectedMeeting()` remains file-backed for cold paths:

- selecting or reopening historical meetings
- transcript edits
- speaker rename
- retry transcription completion
- summary/export workflows

### Consistency And Errors

The accumulator is deterministic: the same update sequence produces the same `TranscriptDocument`.

Live UI and persisted artifacts share the same canonical transcript rules. The ViewModel must not duplicate `TranscriptFileWriter`'s former dedupe logic.

If persistence fails, live UI should not fall back to file reload. The recorder should preserve the existing failure behavior by recording a transcription failure/status or logging an error event. Plain-text failure fallback must still clear structured transcript data so stale JSON is not preferred over the current failure message.

Stop recording closes/finalizes the active sink and writer. Because this version keeps synchronous persistence, transcript artifacts should already be current by stop time.

## Testing

Add focused coverage:

- `TranscriptSegmentAccumulatorTests`
  - same-ID interim-to-final replacement
  - shifted Deepgram interim/final dedupe
  - covered interim pruning
  - adjacent final segments prune boundary-spanning interim
  - `replaceAll` replaces current state for batch providers
  - translation cache preservation only when incoming text is unchanged
- `TranscriptFileWriterTests`
  - STT upsert behavior remains unchanged through accumulator-backed implementation
  - plain-text fallback still clears structured transcript
- `MeetingRecorderTests`
  - fake transcriber updates can be drained from recorder without reading files
  - persistence writes the same canonical document exposed to live consumers
- `MeetingAgentViewModelTests`
  - active recording consumes recorder updates for captions without relying on transcript file reload
  - historical selected meetings still reconstruct captions from `transcript.json`
  - repeated interim updates do not duplicate live caption text
  - stopped artifact and live caption content match
- Provider tests
  - Deepgram streaming emits updates and persists
  - OpenAI realtime transcription completed events emit updates and persists
  - Whisper/batch retry uses `replaceAll`

Run `make test` before completion.

## Acceptance Criteria

- Active live caption updates no longer require full transcript file reload.
- Every provider's transcript output enters a unified update pipeline.
- `TranscriptFileWriter` no longer privately owns STT upsert/dedupe rules.
- Saved transcript artifacts keep current behavior for history, export, summaries, edits, and retry.
- The design permits a future debounce/batched persistence sink without changing provider or ViewModel semantics.
