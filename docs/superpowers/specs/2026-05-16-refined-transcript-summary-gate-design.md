# Refined Transcript Summary Gate Design

## Context

Issue #157 asks summary and knowledge generation to wait for post-meeting transcript refinement before consuming transcript text. The current `stopRecordingAndGenerateSummary` path stops recording, flushes the live caption document, invokes post-meeting refinement, and then calls `generateSummary`. The missing product contract is explicit: users and downstream providers cannot tell whether the summary came from the refined batch transcript or from the low-latency live transcript fallback.

Issue #156 added `PostMeetingTranscriptRefining`, `TranscriptRefinementMetadata`, and refined caption document persistence. This design builds on that boundary and keeps summary generation consuming `MeetingSessionState` instead of direct transcript files.

## Goals

- Show a distinct `Refining transcript` status after recording stops and before summary generation.
- Generate summaries from the refined `MeetingSessionState.transcript` when refinement succeeds.
- Continue to generate summaries from the live transcript when refinement fails.
- Preserve and expose the fallback reason so summary provider input can distinguish refined vs fallback transcript source.
- Keep empty-transcript behavior explicit: no transcript turns should produce a failed summary, not an empty successful result.
- Cover success, failure fallback, empty transcript, and status ordering with focused ViewModel tests.

## Non-Goals

- Do not add realtime translation, summary translation, or new caption persistence artifacts.
- Do not change post-meeting refinement provider selection beyond the existing #156 configuration.
- Do not make knowledge export automatically trigger refinement; this issue gates the stop-and-generate summary path and makes summary input metadata available for later knowledge consumers.

## Selected Approach

Use the existing refinement service as the gate in `stopRecordingAndGenerateSummary`, then pass transcript source metadata through `MeetingSummaryInput`.

When summary generation starts, `MeetingAgentViewModel` derives a `MeetingSummaryTranscriptSource` from the selected or hydrated session:

- `.refined` when the meeting's `TranscriptRefinementMetadata.status` is `.refined`.
- `.fallback(reason:)` when metadata is `.failed`, preserving the failure reason.
- `.live` when no refinement was attempted.

`generateSummary` includes this source in `MeetingSummaryInput`. Providers can consume it immediately, while existing providers remain source-compatible because the field has a default.

## Alternatives Considered

1. Store the source only in `MeetingSummary`.
   This makes persisted summaries self-describing, but it does not satisfy the provider-input requirement and risks wider Codable compatibility work.

2. Add a dedicated summary-generation method for stopped recordings.
   This would keep metadata local to one workflow, but it would duplicate summary input construction and make manual summary regeneration less consistent.

3. Selected: add source metadata to `MeetingSummaryInput`.
   This keeps the contract at the provider boundary and lets existing memory-first summary generation decide source from the current meeting record.

## Data Flow

1. `stopRecordingAndGenerateSummary` stops recording and persists the selected live caption document.
2. The ViewModel sets `statusText` to `Refining transcript`.
3. `PostMeetingTranscriptRefining.refineTranscript` runs.
4. On success, `applyPostMeetingTranscriptRefinementResult` updates the selected session transcript to the refined caption document.
5. On failure, the selected session transcript remains the persisted live fallback and the meeting record stores the failure reason.
6. `generateSummary` sets `statusText` to `Generating summary`.
7. `MeetingSummaryInput` carries `transcriptSource`.
8. The summary provider generates a succeeded or failed summary from the memory-backed `TranscriptConsumptionView`.

## Error Handling

Refinement failures are non-fatal for summary generation if a live transcript exists. The fallback reason comes from `TranscriptRefinementMetadata.failureReason`, with a generic fallback only if metadata is incomplete.

If the transcript consumption view has no turns, `generateSummary` still delegates to the existing summary provider path so provider-owned empty-input behavior is preserved. Tests assert this produces a failed summary rather than an empty success.

## Testing

Add focused `MeetingAgentViewModelTests` coverage:

- refinement success replaces live turns before summary input is captured;
- refinement failure leaves live turns in use and passes fallback source metadata;
- no transcript after stop produces a failed summary;
- status transitions include `Refining transcript`, `Generating summary`, and `Summary generated`.

Existing provider tests get a small Codable/default-argument regression for `MeetingSummaryInput.transcriptSource` if needed.
