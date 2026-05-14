# AGENTS.md

## Project Overview

This project is intended to become a meeting agent for globalizing companies and their managers. The long-term product goal is to help managers run cross-border meetings by reducing language barriers, translating intent into localized language that sounds natural to local participants, analyzing meeting progress in real time, extracting summaries and decisions, and producing targeted analysis based on key topics and meeting goals. The agent should also help managers respond in the local language with culturally and contextually appropriate phrasing.

The current code is only the first step toward that product. Today, this repository is a Swift Package with a `MeetingAgentApp` macOS app prototype focused on system audio capture, provider-backed transcription, realtime captions, meeting summaries, and export workflows.

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

Implemented STT providers include `local`, backed by macOS Speech; `whisper`, backed by a local `whisper.cpp` CLI and model; and hosted Deepgram transcription for realtime captioning.
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

Use the app settings to match the meeting language. The default is `en-US`; Chinese recognition should usually use `zh-CN`. Hosted Deepgram requests must use the configured meeting language instead of hard-coded `multi` unless a provider-specific experiment explicitly requires it.

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

## Realtime Caption Architecture

- Realtime captions are currently caption-only. Active recording must not call realtime translation providers, `TranslationRuntime`, `TranslationExperiencePipeline`, `LiveTranslationScheduler`, replay backfill schedulers, or publish `caption_translation_*` / `translation_*` overlay events.
- The active path is:
  - audio capture writes WAV through `MeetingRecorder`;
  - the selected `SpeechTranscriptionProvider` emits `SpeechRecognitionEvent` / `TranscriptSegment` updates;
  - Deepgram-style realtime events are reconciled by `DeepgramTranscriptReconciler`;
  - `MeetingAgentViewModel` applies updates to a caption-only `LiveCaptionPipeline`;
  - `LiveCaptionPipeline` uses `LiveCaptionChunker` / caption reducers to publish `CaptionTurn` snapshots to the SwiftUI overlay.
- Provider-specific transcription belongs behind `SpeechTranscriptionProvider` and related configuration types. Model/provider switching must not leak into caption chunking, UI rendering, or persistence logic.
- Speaker separation should come from provider/model output when available. Different speakers must naturally create separate visible turns. Same-speaker text should remain in the same turn and use readable sections only when pause, punctuation, or `speechFinal` boundaries justify it. Do not split realtime captions by arbitrary character count.
- Interim text may revise in place, for example `A` -> `AB` -> `AC`. The UI must replace the active draft rather than append every interim prefix as separate visible rows.
- Final transcript updates must bypass draft throttling. Draft caption throttling must not cancel or stale an already pending final caption apply.
- Caption persistence is the source of truth for realtime subtitles. On stop, `MeetingRecorder` must flush the caption document and must not overwrite it with an empty legacy transcript document.
- Product consumers must use `MeetingSessionState` / `TranscriptState` / `SummaryState` in memory. Transcript and summary files are repository-backed hydrate/backup details only: opening a completed meeting may load files into memory once, but summary, export, artifact snapshot, clipboard, and knowledge package flows must read the in-memory state whenever it exists instead of directly reading transcript or summary files.
- `transcript.txt` / legacy transcript JSON support exists for compatibility, export, retry, and non-realtime transcription paths. Do not add redundant meeting artifacts for the realtime caption path; preserve existing post-meeting markdown/summary assets unless the user explicitly asks to delete them.
- Historical translation classes and `translation-results.jsonl` fixtures may remain for old data analysis or isolated legacy tests, but they must not be reachable from `MeetingAgentViewModel`, `MeetingRecorder`, or the app subtitle UI during active recording.

## Realtime Caption Verification Requirements

- Do not claim realtime captions are fixed only because raw provider messages or transcript files exist. Verify the user-visible caption projection.
- For real meeting debugging, inspect `performance-events.jsonl`, `transcript-events.jsonl`, `transcript.json`, and the caption document produced for the meeting. Check these symptoms first:
  - provider language matches the meeting language, especially `zh-CN` for Chinese;
  - speaker IDs from the provider are preserved into visible caption turns;
  - interim updates replace the active draft instead of producing `A`, `AB`, `ABC` duplicates;
  - same-speaker readable sections follow pause, punctuation, or `speechFinal` boundaries, not arbitrary length;
  - final caption updates appear promptly and are not delayed behind draft throttling;
  - no active-recording `caption_translation_*` or `translation_*` events are emitted.
- Validate fixes with focused unit tests for provider request configuration, caption reduction, recorder stop persistence, and ViewModel realtime projection. Run `make test` before claiming completion.
- Historical recordings made before a fix may continue to show old bad behavior. Validate realtime behavior by packaging/running the app, recording a fresh meeting, and analyzing that new meeting directory.

## Git Hygiene

- Check `git status --short` before editing and before final handoff.
- Treat existing user changes as owned by the user; do not revert them unless explicitly asked.
- Commit only files related to the requested change.
