# Transcript Memory Consumption Design

## Context

The realtime caption architecture now treats `CaptionDocument` as the caption-native transcript model. The remaining rough edge is that several post-meeting consumers still treat transcript and summary files as business interfaces. That keeps old transcript logic alive in places such as summary generation, artifact snapshots, exports, and historical meeting selection.

This design makes files a persistence detail only. Product code should consume meeting transcript and summary state from memory. Opening a completed meeting hydrates memory once from persisted assets, then all consumers read the hydrated in-memory state.

For this design, "historical meeting" means a meeting recorded and completed under the new caption architecture. Legacy meetings may keep compatibility adapters, but they are not the main target of this refactor.

## Goals

- Make in-memory meeting state the single business consumption surface for transcript and summary data.
- Keep `transcript.json` as a backup and restore source for `CaptionDocument`, not as a direct consumer API.
- Keep `summary.json` and `summary.md` as summary-owned persisted assets.
- When opening a completed meeting, load summary from `summary.json` if present. If summary is missing, generate it from the in-memory transcript state and persist the result.
- Remove direct transcript-file reads from summary, progress, export, and UI artifact snapshot logic.
- Preserve caption-native structure for downstream consumers: speaker turns, sections, timing, source IDs, provider metadata, and final/draft state.

## Non-Goals

- Do not migrate or repair old meetings generated before the caption architecture.
- Do not reintroduce realtime translation, translation runtime, or translation backfill into the active recording path.
- Do not add another transcript persistence file.
- Do not make summary auto-regenerate when `summary.json` exists, even if transcript content has changed. Summary file presence wins for this design.

## Recommended Architecture

Use a meeting-scoped memory state as the only consumption interface:

```text
Provider / Recorder
    -> MeetingSessionState
        -> UI
        -> Summary
        -> Progress
        -> Export
        -> Knowledge package

MeetingSessionState <-> TranscriptRepository
MeetingSessionState <-> SummaryRepository
```

`MeetingSessionState` owns the active in-memory state for one selected or active meeting:

```swift
struct MeetingSessionState {
    let meetingID: UUID
    var transcript: TranscriptState
    var summary: SummaryState
}
```

`TranscriptState` owns the current `CaptionDocument` and exposes derived read models:

- `captionDocument`
- `visibleTurns`
- `consumptionView`
- `source`: active recording, hydrated from persistence, or empty

`SummaryState` owns summary memory:

- `summary: MeetingSummary?`
- `status`: missing, loaded, generating, generated, failed
- `source`: loaded from persistence or generated in session

Consumers must not depend on transcript or summary URLs.

## Persistence Boundaries

Only repository types should touch files:

```swift
protocol TranscriptRepository {
    func loadCaptionDocument(for meeting: MeetingRecord) throws -> CaptionDocument
    func saveCaptionDocument(_ document: CaptionDocument, for meeting: MeetingRecord) throws
}

protocol SummaryRepository {
    func loadSummary(for meeting: MeetingRecord) throws -> MeetingSummary?
    func saveSummary(_ summary: MeetingSummary, for meeting: MeetingRecord) throws
}
```

Rules:

- `transcript.json` stores `CaptionDocument` snapshots for backup and restore.
- `transcript-events.jsonl` may remain the append-only recovery log for provider speech events.
- `summary.json` stores structured `MeetingSummary`.
- `summary.md` stores the readable rendered summary.
- `transcript.txt` and legacy transcript JSON are compatibility or export artifacts only.
- `TranscriptFileWriter.readDocument(...)` must not be used as a product-level summary/progress/export input.

## TranscriptConsumptionView

`CaptionDocument` remains the caption runtime model. Downstream consumers should use a stable read model projected from it:

```swift
struct TranscriptConsumptionView {
    let meetingID: UUID
    let language: String?
    let provider: CaptionProviderInfo?
    let finalTurns: [TranscriptConsumptionTurn]
    let quality: TranscriptConsumptionQuality
}

struct TranscriptConsumptionTurn {
    let turnID: String
    let speakerID: String?
    let speakerLabel: String?
    let sections: [TranscriptConsumptionSection]
    let text: String
    let startTimeSeconds: Double?
    let endTimeSeconds: Double?
    let sourceIDs: [String]
}

struct TranscriptConsumptionSection {
    let id: String
    let text: String
    let startTimeSeconds: Double?
    let endTimeSeconds: Double?
    let sourceIDs: [String]
}
```

The projector centralizes consumer rules:

- use final turns for summary and post-meeting analysis;
- filter empty sections;
- preserve speaker separation;
- preserve readable section boundaries;
- normalize speaker label fallback;
- expose source evidence IDs;
- compute quality information such as final turn count, unknown speaker count, empty text count, and draft presence.

This keeps summary, progress, export, and knowledge package from each reimplementing caption filtering and speaker logic.

## Completed Meeting Open Flow

When selecting a completed meeting:

```text
selectMeeting(meetingID)
  -> load MeetingRecord metadata
  -> TranscriptRepository.loadCaptionDocument(meeting)
  -> sessionState.transcript = hydrated CaptionDocument
  -> SummaryRepository.loadSummary(meeting)
      if summary exists:
          sessionState.summary = loaded summary
      else:
          generate summary from sessionState.transcript.consumptionView
          SummaryRepository.save(summary)
          sessionState.summary = generated summary
```

Important behavior:

- Summary presence wins. If `summary.json` exists, load it and do not inspect transcript freshness.
- If summary is missing, generation uses the already-hydrated in-memory transcript. It must not read `transcript.json` again.
- UI observes memory state only.
- Consumers should not know whether state came from active recording or persisted files.

## Active Recording Stop Flow

When a recording stops:

```text
stop recording
  -> flush realtime caption pipeline into TranscriptState
  -> TranscriptRepository.saveCaptionDocument(sessionState.transcript.captionDocument)
  -> generate summary from sessionState.transcript.consumptionView
  -> SummaryRepository.save(summary)
  -> sessionState.summary = generated summary
```

The recorder may continue writing provider event logs and caption snapshots during recording, but business consumers read the in-memory state.

## Summary Generation

`MeetingSummaryInput` should move from legacy segments to the consumption view:

```swift
struct MeetingSummaryInput {
    let meetingName: String
    let startedAt: Date
    let endedAt: Date?
    let language: String?
    let targetLanguage: String?
    let meetingGoal: String?
    let transcript: TranscriptConsumptionView
    let generatedAt: Date
}
```

The OpenRouter summary prompt should render final turns and sections, for example:

```text
[00:01:12-00:01:25] Allan
我们今天先确认上线负责人。
source: deepgram-utt-1, deepgram-utt-2
```

Summary output still persists through `summary.json` and `summary.md`.

## Cleanup Targets

Remove or replace these product-level paths:

- `MeetingAgentViewModel.generateSummary(...)` reading `meeting.transcriptJSONURL`.
- `MeetingArtifactSnapshot.load(...)` reading transcript and summary files directly for UI display.
- `MeetingExportService` reading `TranscriptFileWriter.readDocument(...)` as the transcript business input.
- Historical meeting replay code that projects directly from `transcriptJSONURL` instead of hydrating `TranscriptState`.
- Any ViewModel or UI consumer that branches on transcript/summary file paths for data access rather than availability.

Keep these lower-level utilities where needed:

- `MeetingTranscriptStore` for speech event persistence and caption snapshot backup.
- `TranscriptFileWriter` for legacy local/whisper transcription paths and compatibility tests.
- `MeetingSummaryWriter` behind `SummaryRepository`.
- Legacy fixture loaders inside test/support boundaries.

## Error Handling

- If transcript hydration fails for a completed meeting, initialize an empty `TranscriptState`, mark transcript health failed, and do not auto-generate summary.
- If summary load fails but the file exists, mark `SummaryState.failed` with the read error and do not overwrite the file automatically.
- If summary is missing and transcript has no final turns, mark summary as failed with a clear reason and persist the failed summary only when the existing summary file is absent.
- If summary generation fails, update memory state to failed and persist the failed summary payload through `SummaryRepository`.

## Testing Plan

- Opening a completed meeting with `summary.json` hydrates transcript and summary memory, and does not call the summary provider.
- Opening a completed meeting without `summary.json` hydrates transcript memory, generates summary from `TranscriptConsumptionView`, and persists `summary.json` / `summary.md`.
- Summary generation succeeds after transcript files are removed following hydration, proving the provider input is memory-backed.
- UI artifact snapshot reads session state, not transcript or summary files.
- Export reads `TranscriptConsumptionView` from session state.
- Active recording stop flushes caption document backup, generates summary from memory, and persists summary assets.
- Product code searches should show no direct `TranscriptFileWriter.readDocument(...)` use from summary/progress/export/UI paths after migration.

## Acceptance Criteria

- All post-transcript consumers use `MeetingSessionState` or a dependency-injected session/read model.
- `summary.json` presence prevents automatic regeneration on completed meeting open.
- Missing summary is generated from in-memory transcript and then persisted.
- `CaptionDocument` remains the source model, and `TranscriptConsumptionView` is the consumer contract.
- Files are used only by repositories or legacy compatibility utilities.
- `make test` passes.
