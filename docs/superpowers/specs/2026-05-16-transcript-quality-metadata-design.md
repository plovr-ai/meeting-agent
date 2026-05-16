# Transcript Quality Metadata Design

## Context

Meeting intelligence needs to know whether a transcript is trustworthy before it drives summaries, readiness reports, exports, and manager-facing decisions. The app now treats `CaptionDocument` as the persisted transcript source of truth and projects it through `MeetingSessionState`, `TranscriptState`, and `TranscriptConsumptionView` for product flows.

Post-meeting refinement can replace live captions with a cleaner batch transcript. When refinement fails, the app keeps the live caption document. That fallback is currently visible only through `MeetingRecord.transcriptRefinement`, so transcript consumers must infer quality instead of reading explicit transcript metadata.

## Goals

- Persist transcript source and quality metadata with the structured caption document.
- Project quality metadata into in-memory transcript consumption so summary generation, export, and UI code do not read transcript files directly.
- Mark live-only transcripts, post-processed transcripts, and refinement fallback transcripts explicitly.
- Record quality metrics: final turn count, draft turn count, unknown speaker turn count, and empty final turn count.
- Surface the transcript source and quality state in the meeting UI and readiness report.
- Include transcript quality context in summary prompts.

## Non-Goals

- Do not reintroduce `transcript.txt` as an internal artifact.
- Do not add realtime translation metadata or translation overlay events.
- Do not create a separate metadata sidecar file for transcript quality.
- Do not change the semantics of empty transcript handling in the summary provider.

## Model

Add a `TranscriptQualityMetadata` value to `CaptionDocument`.

`TranscriptQualitySource` has these persisted cases:

- `liveOnly`: the document is the live caption transcript and no post-processing has replaced it.
- `postProcessed`: the document was produced by post-meeting refinement.
- `fallbackLive`: the app intentionally kept the live transcript because refinement was skipped or unavailable.
- `refinementFailed`: refinement was attempted and failed, so the live transcript remains the source.

The metadata also stores:

- `fallbackReason: String?`
- `metrics: TranscriptQualityMetrics`
- `updatedAt: Date`

`TranscriptQualityMetrics` stores:

- `finalTurnCount`
- `draftTurnCount`
- `unknownSpeakerTurnCount`
- `emptyFinalTurnCount`

Legacy caption documents decode with `qualityMetadata == nil`. Projection code derives metrics from current turns and defaults source to `liveOnly` unless refinement metadata on the meeting says otherwise.

## Data Flow

Live recording writes and flushes `CaptionDocument` with `liveOnly` quality metadata.

Post-meeting refinement success writes a replacement `CaptionDocument` with `postProcessed` metadata and fresh metrics.

Post-meeting refinement failure keeps the live document, updates its metadata to `refinementFailed`, records the failure reason, recomputes metrics, and saves it. If refinement is skipped because the configuration cannot run batch refinement, the source is `fallbackLive`.

`TranscriptConsumptionView.project` reads `CaptionDocument.qualityMetadata`, recomputes metrics from the current document, and exposes a `TranscriptConsumptionQuality` that includes source and fallback reason.

`MeetingSummaryInput` carries that consumption quality into `OpenRouterMeetingSummaryProvider.prompt`, which includes a concise transcript quality context before transcript segments.

`MeetingArtifactSnapshot` exposes a short quality label for UI surfaces. `MeetingExportService.readinessReport` includes a `Transcript Quality` section with source, fallback reason, and metric counts.

## UI

The meeting detail transcript phase displays a compact quality row near the transcript heading:

- `Live transcript`
- `Post-processed transcript`
- `Fallback live transcript`
- `Refinement failed`

The row includes metrics that matter for trust: unknown speaker count, draft count, and empty final count. Failure/fallback reasons are shown when available.

The UI remains informational. It does not block summary generation or exports.

## Testing

Add focused tests for:

- `CaptionDocument` encodes and decodes transcript quality metadata.
- Legacy `CaptionDocument` JSON without metadata still decodes.
- `TranscriptConsumptionView.project` exposes source, fallback reason, and computed metrics.
- `PostMeetingTranscriptRefinementService` marks successful refinement as `postProcessed`.
- Refinement failure persists `refinementFailed` or `fallbackLive` metadata on the preserved live document.
- Summary prompt includes transcript quality context.
- Readiness report includes transcript quality.
- Meeting detail UI source contains the expected quality labels.

Run `make test` as the required final verification.
