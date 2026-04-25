# Phase 1E Product Readiness Export Design

## Intent

Issue #7 asks for Phase 1 product readiness validation under real meeting conditions. The current prototype cannot automate live Zoom, Teams, Google Meet, Safari, and language validation reliably from unit tests, but it can make each recorded meeting easier to validate, retry, inspect, and export.

This design implements the product-readiness slice that belongs in the app today: meeting artifacts remain associated with the meeting record, users can export the important artifacts, and the app can produce a Markdown readiness report for manual validation runs.

## Requirements

- Every new meeting record should reserve stable artifact paths for audio, transcript text, structured transcript JSON, diagnostics JSON, and summary Markdown.
- Core code should export:
  - rendered transcript text,
  - structured meeting metadata JSON,
  - summary Markdown when a summary artifact exists,
  - a Markdown readiness report containing meeting metadata, artifact paths, transcription status, failure reason, transcript excerpt, and diagnostics status.
- The app should expose export actions in the meeting detail view.
- The app should support copying the summary artifact to the clipboard when it exists.
- Export failures should surface as clear app status text.
- Tests should cover the core export behavior without depending on live meeting apps, Core Audio, Speech, or the clipboard.

## Non-Requirements

- Do not automate real Zoom, Teams, Meet, Slack, or browser validation in this issue.
- Do not add an AI summary generation backend.
- Do not add summary retry behavior until summary generation exists.
- Do not alter existing audio capture, STT provider, or transcript retry flow except where export status reads those artifacts.

## Approach

Add a focused `MeetingExportService` to `MeetingAgentCore`. It reads existing meeting artifact URLs, writes exports to caller-provided destination URLs, and creates a Markdown report suitable for the validation matrix in the issue. `MeetingRecord` gains an optional `summaryURL` with backward-compatible decoding.

The SwiftUI app will keep the detail view simple by routing export and copy commands through `MeetingAgentViewModel`. AppKit-specific clipboard and save-panel work remains in the app target; export file generation remains in core for testability.

## Affected Files

- `Sources/MeetingAgentCore/MeetingRecord.swift`
- `Sources/MeetingAgentCore/MeetingStore.swift`
- `Sources/MeetingAgentCore/MeetingExportService.swift`
- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- `Sources/MeetingAgentApp/MainWindowView.swift`
- `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

## Testing

Unit tests create temporary meeting directories with transcript, summary, metadata, and diagnostics fixtures. Tests assert exported content, missing-artifact error messages, backward-compatible record decoding, and view-model status behavior. Full local verification runs `swift test` and `swift build --product MeetingAgentApp`.
