# Caption-Only Transcript Persistence Design

## Issue

GitHub issue #144 asks whether realtime caption persistence should keep the old `TranscriptFileWriter` bridge. The approved decision is to remove the redundant legacy transcript artifact from new realtime meetings.

## User Intent

New recordings should treat `CaptionDocument` in `transcript.json` as the only persisted realtime subtitle source of truth. The app may still export a transcript text file on demand, but it must not maintain `transcript.txt` as a parallel cache for active recording, retry, or edit flows.

## Requirements

- New meetings do not receive a `transcriptURL` pointing at `transcript.txt`.
- Active recording writes realtime captions through a caption-first store boundary.
- Stopping or finalizing a recording cannot overwrite a populated `CaptionDocument` with an empty legacy transcript document.
- Retry transcription writes a new `CaptionDocument` snapshot, not a legacy rendered transcript.
- UI readiness and export affordances use `transcriptJSONURL` or in-memory transcript state instead of `transcriptURL`.
- Text transcript export remains available by rendering `CaptionDocument` at export time.

## Non-Requirements

- Do not delete the `TranscriptFileWriter` type in this issue. It still supports older tests and isolated non-realtime compatibility code.
- Do not migrate existing user metadata files in place. Existing decoded `transcriptURL` values may remain for old meetings, but new writes should not depend on them.
- Do not remove subtitle export, summary generation, meeting export, or knowledge package flows.

## Considered Approaches

1. Keep `transcript.txt` as a documented backup bridge.
   - Lowest code churn, but preserves the ambiguity the issue is trying to remove.
2. Remove legacy rendered text from active recording only.
   - Improves the main path, but retry and edit flows would still maintain the redundant artifact.
3. Remove new-meeting `transcript.txt` persistence across active recording, retry, edits, and UI readiness.
   - Best matches the approved product direction. Export can still render a text file when the user asks for one.

## Selected Approach

Use approach 3. `transcript.json` remains the meeting transcript repository artifact. `transcript.txt` is no longer created for new meetings and no longer updated by active recording, retry, or edit flows. Any remaining `TranscriptFileWriter` usage must be outside the new realtime persistence boundary.

## Architecture

`MeetingStore` creates new records with `transcriptURL == nil` and `transcriptJSONURL == <meeting>/transcript.json`. `MeetingRecorder` creates a recording update sink from the transcript JSON location. Segment-style provider updates are reduced into a `CaptionDocument` and saved through the same JSON file. Speech event providers continue using `MeetingTranscriptStore`.

Retry transcription converts provider segments into a `CaptionDocument` and saves that document through `TranscriptRepository`. UI actions that previously checked `transcriptURL` now check for `transcriptJSONURL` or hydrated transcript state. Exported transcript text is generated on demand from `CaptionDocument`.

## Testing

- `MeetingStoreTests` proves new meetings no longer include `transcriptURL`.
- `RecordingTranscriptPersistenceStoreTests` proves segment updates persist `CaptionDocument` only and do not create `transcript.txt`.
- `MeetingRecorderTests` proves stop/finalize preserves the caption document without a text transcript URL.
- `MeetingAgentViewModelTests` proves retry and transcript edits update `CaptionDocument` without writing rendered text.
- App layout/source tests prove export and agenda readiness no longer depend on `transcriptURL`.

