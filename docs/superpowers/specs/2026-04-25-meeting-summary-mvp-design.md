# Meeting Summary MVP Design

## Context

Issue #6 asks for a first post-meeting summary experience. The current app records meeting audio, writes a plain-text transcript, and writes a structured transcript document at `transcript.json`. Managers need a shorter artifact that extracts outcomes from the transcript without replacing or corrupting the source transcript and audio files.

This MVP should produce `summary.json` as the source of truth for app display and future integrations, plus `summary.md` as a human-readable export. It should keep the summary implementation behind a provider boundary so local and hosted providers can be added later.

## User Intent And Success Criteria

The user wants a completed meeting with structured transcript data to generate a useful post-meeting summary. The summary must separate overview text from decisions and action items, preserve traceability to transcript segment IDs where practical, and fail without damaging existing transcript or audio artifacts.

Success criteria:

- Completed meetings with transcript segments can generate a summary.
- Summary output is saved to both `summary.json` and `summary.md`.
- Decisions and action items are represented as separate structured arrays.
- Summary generation failures are represented in `summary.json` and visible in the app.
- Summary output can be regenerated from the current transcript.
- Decisions, action items, and other extracted claims include source segment IDs when available.

## Non-Requirements

- No hosted LLM provider is introduced in this phase.
- No privacy, consent, account, or API-key settings are introduced in this phase.
- No chunked long-meeting summarization pipeline is implemented yet.
- No automatic summary generation is required while a meeting is still recording.

## Selected Approach

Build a deterministic local extractive provider first. The provider consumes structured transcript segments and meeting metadata, then emits a schema-compatible summary based on lightweight heuristics. This is intentionally conservative: it keeps the app useful and testable while preserving a provider boundary for future LLM-backed summarizers.

Alternative approaches considered:

- Hosted LLM provider now: likely higher quality, but introduces privacy, configuration, cost, retry, and external failure concerns before product policy is settled.
- Schema-only implementation: lower risk, but does not satisfy the acceptance criterion that completed meetings can generate a useful summary.

## Data Model

Add summary artifact URLs to `MeetingRecord`:

- `summaryJSONURL`
- `summaryMarkdownURL`

`MeetingStore.createMeeting` will assign these paths inside the meeting directory:

- `summary.json`
- `summary.md`

Add a `MeetingSummary` model with:

- `overview`
- `keyTopics`
- `decisions`
- `actionItems`
- `openQuestions`
- `risks`
- `followUps`
- `language`
- `sourceSegmentIDs`
- `generatedAt`
- `provider`
- `status`
- `failureReason`

Action items include:

- `description`
- `owner`
- `dueDate`
- `sourceSegmentIDs`
- `confidence`

Decisions include:

- `description`
- `participants`
- `sourceSegmentIDs`
- `confidence`

`status` is an enum with `succeeded` and `failed`. `failureReason` is set only for failed summaries.

## Provider Boundary

Introduce:

- `MeetingSummaryProvider`
- `MeetingSummaryInput`
- `ExtractiveMeetingSummaryProvider`

`MeetingSummaryInput` includes meeting name, started and ended timestamps, locale or language, optional meeting goal or agenda, and structured transcript segments.

The provider returns a complete `MeetingSummary`. The initial extractive provider will:

- Trim empty transcript segments.
- Fail with status `failed` when no usable transcript segments exist.
- Use the first meaningful transcript text as a compact overview seed.
- Extract decisions from segments containing phrases such as `decided`, `decision`, `approved`, or `agreed`.
- Extract action items from segments containing phrases such as `action item`, `todo`, `follow up`, `will`, or `need to`.
- Extract open questions from text ending in `?` or containing question phrases.
- Extract risks from text containing `risk`, `blocked`, `concern`, `delay`, or `issue`.
- Use source segment IDs from the segments that produced each claim.

The heuristic provider is not expected to be semantically perfect. It is a deterministic MVP that exercises the full product flow and can be replaced by an LLM provider later.

## Persistence

Add `MeetingSummaryWriter` for writing and reading summary artifacts. It will write `summary.json` atomically and render `summary.md` from the same in-memory summary to avoid drift.

The issue #4 lesson applies here: `summary.json` and `summary.md` must be updated together on success and failure so the app never prefers stale structured data over current fallback text.

## App Experience

The meeting detail view will show a Summary section above the Transcript section when a meeting is selected.

The Summary section includes:

- Overview.
- Decisions.
- Action items.
- Open questions.
- Risks.
- A regenerate summary button.
- A failure reason when the latest summary failed.

The regenerate action is disabled while recording. If no summary exists yet, the section shows a short empty state and still offers generation for completed meetings with transcript data.

## Error Handling

Summary generation failures must not modify audio or transcript artifacts. Failures are represented by a failed `MeetingSummary` written to both summary artifacts, including a failure reason and the provider name.

Expected failure cases:

- No structured transcript file.
- Structured transcript file exists but contains no usable segments.
- Summary artifact write failure.

Read failures in the app should show the absence of a summary rather than crashing the view.

## Testing

Unit tests cover:

- `MeetingRecord` Codable compatibility with optional summary URLs.
- `MeetingStore` creates summary artifact URLs.
- `MeetingSummary` JSON round trip.
- `MeetingSummaryMarkdownRenderer` renders overview, decisions, action items, open questions, and failure reason.
- `ExtractiveMeetingSummaryProvider` produces separate decisions and action items with source segment IDs.
- `ExtractiveMeetingSummaryProvider` returns a failed summary for empty transcript input.
- `MeetingSummaryWriter` writes JSON and Markdown together.
- `MeetingAgentViewModel` regenerates a summary for a completed meeting with structured transcript segments.

No E2E test convention exists in the repository. Integration-style behavior is covered through core and view model XCTest coverage.
