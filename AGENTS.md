# AGENTS.md

## Project Overview

This project is intended to become a meeting agent for globalizing companies and their managers. The long-term product goal is to help managers run cross-border meetings by reducing language barriers, translating intent into localized language that sounds natural to local participants, analyzing meeting progress in real time, extracting summaries and decisions, and producing targeted analysis based on key topics and meeting goals. The agent should also help managers respond in the local language with culturally and contextually appropriate phrasing.

The current code is only the first step toward that product. Today, this repository is a Swift Package with a `MeetingAgentApp` macOS app prototype focused on system audio capture, transcription, bilingual subtitles, realtime translation, meeting summaries, and export workflows.

The package targets macOS 14.2+ and uses Swift 5.9.

## Repository Layout

- `Package.swift` defines the Swift package, core library target, app target, and test target.
- `Sources/MeetingAgentCore/` contains shared meeting, capture, recording, process discovery, and transcription logic.
- `Sources/MeetingAgentApp/` contains the macOS SwiftUI menu bar app prototype.
- `Tests/MeetingAgentCoreTests/` contains XCTest coverage.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` contain historical design and implementation notes.

## Common Commands

Use these from the repository root:

```sh
make test
swift build --product MeetingAgentApp
make package-app
swift run MeetingAgentApp
```

The app stores user meeting data under `~/Library/Application Support/MeetingAgent/Meetings/`.

Use `make package-app` to create `dist/MeetingAgent.app` for local installation or prototype sharing. The generated app bundle is not Developer ID signed or Apple notarized, so recipients may need to right-click Open or approve it in System Settings the first time they launch it.

Implemented STT providers are `local`, backed by macOS Speech, and `whisper`, backed by a local `whisper.cpp` CLI and model.
The default STT provider is `whisper` for the app. Use the app settings to select `local` only when explicitly testing macOS Speech.
The `whisper` STT provider uses a local `whisper.cpp` CLI and model. Configure it with `MEETING_AGENT_WHISPER_BIN` and `MEETING_AGENT_WHISPER_MODEL`, for example:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
```

The default summary provider is OpenRouter-backed and uses the summary model configured in app settings. To generate summaries with OpenRouter, configure the API key:

```sh
export MEETING_AGENT_OPENROUTER_API_KEY=<your-openrouter-key>
```

Use the app settings to match the meeting language. The default is `en-US`; Chinese recognition should usually use `zh-CN`.

## Development Guidelines

- Prefer small, focused changes that match the existing Swift style.
- Keep platform-sensitive Core Audio and Speech behavior isolated behind small testable types where possible.
- Add or update tests for behavior changes. For bug fixes, write the failing test first when feasible.
- Run `make test` before claiming a change is complete. This is the required unit-test entrypoint and enforces code coverage.
- Do not commit generated files from `.build/`, `.swiftpm/`, or `DerivedData/`.
- Do not remove or weaken macOS permission strings in `Info.plist` unless the related capability is removed.

## Audio And Transcription Notes

- `AudioIOReader` reads process tap audio and converts float32 linear PCM to signed 16-bit PCM.
- `WavFileWriter` writes RIFF/WAVE output.
- `SpeechTranscriptionProvider` is the provider boundary for transcription backends.
- `LocalSpeechTranscriptionProvider` uses `SystemSpeechTranscriber`.
- `WhisperSpeechTranscriptionProvider` uses a local `whisper.cpp` CLI and model.
- `SystemSpeechTranscriber` adapts captured PCM frames into `SFSpeechAudioBufferRecognitionRequest`.
- If Speech recognition permission or availability fails, WAV recording should continue and the transcript file should contain the failure reason.

## Realtime Caption And Translation Architecture

- Realtime captions are the primary user-facing path. Translation must never block caption ingestion, caption chunking, or caption overlay publication.
- Active-recording translation uses the unit translation runtime, not the legacy replay backfill path:
  - `MeetingAgentViewModel` sends live transcript documents to `TranslationRuntimeActor`.
  - `TranslationRuntimeActor` serializes realtime apply/finalize operations so stop/finalize cannot race with in-flight translation applies.
  - `TranslationExperiencePipeline` builds live units and stable blocks, schedules live/accurate translation, stores visible results, and persists stable final results.
  - `TranslationUnitBuilder` must use the same `LiveCaptionChunker` boundary policy as the realtime caption projection. Stable translation block `sourceSegmentIDs` must match visible caption turn `sourceSegmentIDs`.
  - `LiveCaptionPipeline.attachTranslationResults` may attach a `stableFinal` result only when the result `sourceSegmentIDs` exactly match a visible turn. Partial overlap is a bug and must log `translation_unit_projection_mismatch`.
  - `liveFresh` results are allowed to attach only as temporary live previews for a single source segment contained in a visible turn.
- The legacy replay translation classes are now replay/backfill-only. `ReplayTranslationBackfillScheduler` and `ReplayTranslationBackfillPlanner` must not become the active-recording translation path again.
- Draft caption throttling must not cancel or stale an already pending final caption apply. A final transcript update must be allowed to reach the caption pipeline before later draft throttle updates are coalesced.
- `LiveTranslationScheduler` should coalesce same-lane live units in a batch to the latest unit. Do not waste provider calls translating an older prefix when a newer prefix for the same lane is already available.
- Translation persistence is separate from caption persistence. Stable final translation records are stored in `translation-results.jsonl` via `TranslationResultPersistenceStore` and must include `sourceSegmentIDs`.

## Translation E2E Verification Requirements

- Do not claim translation is fixed because provider calls, overlay events, or persisted records exist. The E2E gate must validate that translated data is visible, timely, and projected onto the correct caption turns.
- Use the analyzer against real meeting directories whenever validating recordings:

```sh
swift scripts/analyze-meeting-performance.swift --assert-translation-e2e "$HOME/Library/Application Support/MeetingAgent/Meetings/<MEETING_ID>"
```

- The E2E report must fail on all of these conditions:
  - realtime captions were visible but no translation became visible or persisted;
  - unit translations were scheduled but no provider call was observed;
  - provider calls started but never finished or failed;
  - provider unavailable, provider failed, or same-language skip events occurred unexpectedly;
  - first live translation latency exceeds the configured budget, currently 4 seconds from first audio frame to first `translation_live_result_visible`;
  - stable translation coverage is below the configured floor, currently 80% of realtime final caption turns;
  - `translation_unit_projection_mismatch` events are present;
  - persisted `translation-results.jsonl` records do not exactly match any non-replay `caption_turn_visible` `sourceSegmentIDs` set;
  - duplicate stable result persistence is detected;
  - realtime translation runtime snapshots are published after stop.
- Key E2E fields to inspect in reports:
  - `First Live Translation Latency`
  - `Stable Translation Coverage`
  - `Translation Projection Mismatch Events`
  - `Persisted Translation Projection Mismatches`
  - `Visible Unit Result Events`
  - `Translation Result Store Records`
- When a UI report says translations are missing, delayed, repeated, or jumping, first inspect `performance-events.jsonl`, `transcript-events.jsonl`, `transcript.json`, and `translation-results.jsonl`. Compare visible caption turn `sourceSegmentIDs` with stable translation result `sourceSegmentIDs`; exact set mismatch is the primary projection failure mode.
- Historical recordings made before a fix may continue to fail new E2E gates. Validate fixes by packaging the app, recording a fresh meeting, and running the analyzer on that new meeting directory.

## Git Hygiene

- Check `git status --short` before editing and before final handoff.
- Treat existing user changes as owned by the user; do not revert them unless explicitly asked.
- Commit only files related to the requested change.
