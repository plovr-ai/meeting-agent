# Remove Realtime Speech Translation Design

## Context

Issue #88 asks to remove the unused realtime speech translation chain from live captions. The active product path is STT-driven captions plus caption text translation. The realtime speech translation chain sends captured audio frames to a separate provider and attaches independent translation turns back to captions by order, which is not a stable alignment model.

The user also requested removing related Settings configuration.

## Requirements

- Remove the realtime speech translation controller, provider, model types, and store tests when they no longer serve another active path.
- Remove `MeetingRecorder.realtimeFrameConsumer` and the test-only realtime frame delivery hook.
- Remove `MeetingAgentViewModel` realtime translation status, live translation turns, start/stop/sync APIs, and order-based attachment bookkeeping.
- Remove Settings UI and configuration fields that are only for realtime speech translation.
- Preserve STT-driven live captions and caption text translation.
- Preserve hosted OpenAI realtime transcription configuration, which is a separate STT provider path and not part of the removed speech translation chain.

## Non-Requirements

- Do not redesign realtime speech translation alignment.
- Do not change OpenRouter caption text translation behavior.
- Do not remove OpenAI realtime transcription support.
- Do not alter unrelated meeting summary, export, or capture workflows.

## Selected Approach

Delete the unused realtime speech translation feature rather than leaving disconnected dead code. This reduces architectural surface area and eliminates the unsafe caption attachment model. The implementation will keep changes narrow: remove direct references, delete now-unused files/tests, then let compiler errors identify any remaining stale edges.

## Affected Files

- `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- `Sources/MeetingAgentCore/MeetingRecorder.swift`
- `Sources/MeetingAgentCore/RealtimeTranslation.swift`
- `Sources/MeetingAgentCore/RealtimeTranslationController.swift`
- `Sources/MeetingAgentCore/OpenAIRealtimeTranslationProvider.swift`
- `Sources/MeetingAgentApp/SettingsView.swift`
- `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`
- `Tests/MeetingAgentCoreTests/RealtimeTranslationControllerTests.swift`
- `Tests/MeetingAgentCoreTests/OpenAIRealtimeTranslationProviderTests.swift`
- `Tests/MeetingAgentCoreTests/RealtimeTranslationStoreTests.swift`
- Settings and configuration tests that mention realtime speech translation fields.

## Test Plan

- Update or remove tests that only validate the removed realtime speech translation chain.
- Keep or add tests proving `MeetingRecorder` drains frames to WAV/transcriber without realtime consumers.
- Keep Settings tests asserting realtime speech translation controls are absent.
- Run `make test`.
