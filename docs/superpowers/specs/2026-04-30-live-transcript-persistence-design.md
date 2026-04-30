# Live Transcript Persistence Design

## Issue

GitHub issue #85 asks the active recording path to stop rewriting complete transcript artifacts on every live segment or caption translation update. Existing meetings and exports must still use `transcript.json` and `transcript.txt`, and stopping a recording must leave complete final artifacts on disk.

## Goals

- Keep the canonical transcript document in memory while a recording is active.
- Persist live mutations to an append-only `transcript-events.jsonl` event log.
- Write `transcript.json` and `transcript.txt` only through a buffered snapshot path during active recording.
- Force a complete snapshot flush when recording stops or the recorder closes the transcript persistence path.
- Preserve backward compatibility for existing `transcript.json` and `transcript.txt` readers.
- Let caption translation persistence update the active in-memory document without reading and rewriting the full artifact per update.

## Non-Goals

- Do not change the historical transcript artifact format.
- Do not move live caption display ownership out of `LiveCaptionPipeline`.
- Do not replace legacy static `TranscriptFileWriter` edit helpers used by post-recording manual edits.
- Do not introduce a broad actor/concurrency rewrite of the recorder.

## Selected Approach

Add a small active-recording persistence store owned by `MeetingRecorder` for the lifetime of the recording. The store wraps `TranscriptSegmentAccumulator`, accepts structured transcript mutations, appends each mutation to `transcript-events.jsonl`, and snapshots the complete `TranscriptDocument` to the legacy artifacts only when the debounce policy says a snapshot is due or when callers explicitly flush.

The existing `TranscriptFileWriter` remains the final artifact renderer and legacy helper. Active recording paths should use the new store through `RecordingTranscriptUpdateSink`, while retry/batch paths may keep using `FileBackedTranscriptUpdateSink`.

## Data Flow

1. `MeetingRecorder.startRecording` creates `RecordingTranscriptUpdateSink` with the active transcript URL.
2. Streaming transcribers call `TranscriptUpdateSink.receive(.upsert(...))`, `.replaceAll(...)`, or `.replaceWithPlainText(...)`.
3. `RecordingTranscriptUpdateSink` logs emitted updates, applies them to the active store, queues `TranscriptSegmentAccumulationResult` for the UI drain loop, and only snapshots when the store reports a due snapshot.
4. Caption translation persistence calls an active sink translation patch when available. If no active sink is available, it falls back to `TranscriptFileWriter.updateSegmentTranslation(...)`.
5. `MeetingRecorder.stopRecording` closes the active sink, forcing a final snapshot before the record is marked stopped.

## Mutation Model

Extend transcript mutations with:

- `upsert(TranscriptSegment)`
- `replaceAll([TranscriptSegment])`
- `replaceWithPlainText(String)`
- `translationPatch(segmentID:text:targetLocale:isFinal:)`

The accumulator should apply translation patches to the in-memory document and preserve current validation behavior: segment ID, text, and target locale must be non-empty, and missing segment IDs should fail for throwing store APIs.

## Event Log

The event log lives beside the transcript artifacts as `transcript-events.jsonl`. Each line is a JSON object containing an event type and associated payload. Store initialization reads the current snapshot, then replays the event log so crash/restart recovery can rebuild state from the last snapshot plus subsequent mutations.

## Snapshot Policy

Use a deterministic, testable policy:

- The store accepts a `snapshotInterval` and a `now` closure.
- Segment upserts and translation patches append events immediately.
- Snapshot writes occur when the interval has elapsed since the last snapshot.
- `replaceAll`, `replaceWithPlainText`, and close/stop force snapshots because they are boundary or failure states.
- Tests can set a long interval to prove no per-update text rewrite, then explicitly advance `now` or call flush to prove durable snapshots.

## Testing

Add unit tests for:

- segment upsert updates in-memory state and event log without rewriting `transcript.txt` before the debounce interval
- translation patch updates in-memory state and event log without a full snapshot before the debounce interval
- debounced snapshot writes complete `transcript.json` and `transcript.txt`
- close/stop flush writes complete final artifacts
- recovery replays `transcript-events.jsonl` over an existing snapshot

Existing `make test` remains the final verification command.
