# Current User Speaker Label Design

## Goal

When realtime microphone transcription can match a speaker lane to the current user's enrolled voice profile with high confidence, MeetingAgent should display and persist that lane as `Me` while keeping ordinary speaker labels for everyone else.

## Scope

This issue builds the metadata and projection path for the current-user identity. It does not add a full enrollment UI or force-label the first microphone speaker as the user. A speaker is labeled `Me` only when speaker identification resolves the lane to a profile marked as the current user and the match reaches the automatic-match threshold.

## Behavior

- A `SpeakerProfile` can represent the current user.
- Current-user profiles render as `Me` after high-confidence matches.
- Ambiguous current-user matches stay in `needsConfirmation` and do not display `Me`; they continue to use the profile's safe anonymous label.
- Non-current-user matches keep the existing display-name or anonymous speaker behavior.
- `MeetingAgentViewModel` continues to apply speaker identity labels to visible `LiveCaptionTurn` values and to the active in-memory `CaptionDocument`, so the `Me` label is available to summaries, exports, and knowledge-package flows through `TranscriptState`.

## Data Flow

```text
TranscriptSegment.speakerID
  -> RealtimeSpeakerIdentificationRuntime
  -> SpeakerIdentityResolver
  -> SpeakerIdentityResolution(displayLabel: "Me")
  -> MeetingAgentViewModel.liveCaptionTurns
  -> TranscriptState.captionDocument
  -> TranscriptConsumptionView / export / summary inputs
```

The raw provider speaker identifier is preserved. Only the display label changes.

## Error Handling

If the current-user profile is absent, the embedding provider fails, evidence is insufficient, or confidence is below the automatic threshold, the app keeps the existing speaker label path. The feature must not block recording, caption projection, persistence, summaries, or export.

## Tests

Focused unit tests cover:

- Current-user profile display label and Codable compatibility.
- Resolver behavior for high-confidence `Me` matches.
- Resolver behavior for ambiguous current-user matches that must not show `Me`.
- ViewModel realtime projection and active transcript state persistence of the `Me` label while preserving the provider speaker id.
