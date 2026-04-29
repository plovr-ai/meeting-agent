# Persist Caption Translations Design

## Context

GitHub issue #81 reports that reopening a meeting triggers caption translation again. The app currently stores transcript source segments in `transcript.json`, but translated caption text lives only in `MeetingAgentViewModel`'s `LiveCaptionStore`. When a meeting is reopened, `refreshLiveCaptionTurnsFromSelectedMeeting()` rebuilds live captions from source segments and schedules translation for pending turns.

## Success Criteria

- A completed caption translation is written to the meeting's structured transcript artifact.
- Reopening or reselecting a meeting hydrates live caption translated text from that artifact.
- Cached translations prevent another provider request for the same source text and target locale.
- Editing source transcript text clears stale cached translation for that segment.
- Legacy transcript JSON without translation fields continues to decode.

## Approach

Add optional translation cache fields to `TranscriptSegment`: translated text, target locale, and translation finality. `TranscriptFileWriter` will expose a focused method for updating a segment's cached translation and will preserve cached translation only when a source segment is unchanged. Existing source text edits clear cached translation fields.

`MeetingAgentViewModel` will persist successful draft and final caption translations back to the structured transcript segment represented by the translated live caption turn. During replay, caption updates built from cached translated segments will attach that text to the live turn, mark translation health live, and mark final translations final. Because hydrated turns are no longer pending, the scheduler will not call the provider again.

## Alternatives Considered

- A separate translation sidecar JSON file: rejected because it introduces another artifact to keep in sync with transcript edits and segment replacement.
- Persisting only view-model `LiveCaptionTurn` snapshots: rejected because captions are derived display state and can change with chunking policy, while transcript segments are the stable source artifact.
- Caching in process memory or settings: rejected because it does not survive app relaunch and is not scoped to a meeting.

## Affected Files

- `Sources/MeetingAgentCore/TranscriptSegment.swift`
- `Sources/MeetingAgentCore/TranscriptFileWriter.swift`
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- `Tests/MeetingAgentCoreTests/TranscriptFileWriterTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

## Test Plan

- Add a transcript writer test proving translation cache fields persist and source text edits clear them.
- Add a view-model regression proving a translation is written to `transcript.json`.
- Add a reopen regression proving a new view model hydrates the cached translation and does not call the translation provider again.
- Run focused Swift tests, then `make test`.
