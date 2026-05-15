# Remove Legacy Transcript Writer Design

## Context

Issue #152 asks us to remove or strictly isolate the old transcript writer architecture. New and active meeting flows persist user-visible captions through `CaptionDocument`, `MeetingTranscriptStore`, and `RecordingTranscriptPersistenceStore`, but some providers still create `TranscriptFileWriter` when no sink is supplied, and retry paths still create `provider-transcript.legacy`.

## Success Criteria

- Realtime providers do not silently create `TranscriptFileWriter` fallback output when no caption-compatible sink is supplied.
- Retry transcription no longer creates `provider-transcript.legacy`.
- System Speech, Whisper, Deepgram, and OpenAI realtime paths expose output through `TranscriptUpdateSink` or structured return values that can be saved as `CaptionDocument`.
- `FileBackedTranscriptUpdateSink` is removed from active source or quarantined outside production provider paths.
- Tests assert caption-document output boundaries and architecture guards cover the legacy keywords named in the issue.

## Approaches Considered

1. Delete `TranscriptFileWriter` entirely.
   This is the cleanest long-term shape, but it is too large for one issue because legacy migration tests and transcript document helpers still use it as a bridge.

2. Keep `TranscriptDocument` as an internal intermediate model, but remove production writer fallbacks.
   Providers must either receive an explicit sink or return a structured document for retry/existing-audio flows. This preserves tested domain conversion while ending transcript.txt-style production writes.

3. Rename all transcript intermediate types to caption-native names.
   This reduces naming confusion but is mostly mechanical and risks a broad diff without improving the active output boundary.

## Selected Design

Use approach 2. Keep `TranscriptDocument` and `TranscriptSegmentAccumulator` as internal intermediate models for provider reconciliation, fixtures, migration, and analysis. Remove active product dependence on `TranscriptFileWriter` by introducing caption-compatible sinks where live code needs persistence, and by changing retry/existing-audio flows to return structured documents instead of writing a provider-owned legacy file.

## Data Flow

- Active recording passes a `RecordingTranscriptUpdateSink` into provider startup. Providers with no sink should keep only in-memory reconciliation or throw when persistence would be required; they should not create text/legacy JSON files.
- Existing-audio retry providers return a `TranscriptDocument` from `transcribeExistingAudio(context:)`. The ViewModel converts that document to a `CaptionDocument` and saves through `FileTranscriptRepository`.
- `SystemSpeechTranscriber` writes updates through `TranscriptUpdateSink` when active recording supplies one. Legacy URL writer use is not part of production start paths.
- `WhisperSpeechTranscriptionProvider` returns a structured document for retry and sends updates to explicit sinks for active recording.

## Test Plan

- Update provider unit tests to assert no transcript.txt/legacy JSON fallback files are created for realtime paths without sinks.
- Update retry transcription tests to assert `provider-transcript.legacy` is absent and `transcript.json` contains caption turns.
- Keep explicit migration/legacy writer tests only if `TranscriptFileWriter` remains quarantined.
- Run focused provider/ViewModel tests, architecture guards, and `make test`.
