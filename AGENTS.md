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
swift test
swift build --product MeetingAgentApp
swift run MeetingAgentApp
```

The app stores user meeting data under `~/Library/Application Support/MeetingAgent/Meetings/`.

Implemented STT providers are `local`, backed by macOS Speech, and `whisper`, backed by a local `whisper.cpp` CLI and model.
The default STT provider is `whisper` for the app. Use the app settings to select `local` only when explicitly testing macOS Speech.
The `whisper` STT provider uses a local `whisper.cpp` CLI and model. Configure it with `MEETING_AGENT_WHISPER_BIN` and `MEETING_AGENT_WHISPER_MODEL`, for example:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
```

The default summary provider is `extractive-local`. To generate summaries with OpenRouter, configure the provider, API key, and model:

```sh
export MEETING_AGENT_SUMMARY_PROVIDER=openrouter
export MEETING_AGENT_OPENROUTER_API_KEY=<your-openrouter-key>
export MEETING_AGENT_OPENROUTER_MODEL=openai/gpt-4.1-mini
```

Use the app settings to match the meeting language. The default is `en-US`; Chinese recognition should usually use `zh-CN`.

## Development Guidelines

- Prefer small, focused changes that match the existing Swift style.
- Keep platform-sensitive Core Audio and Speech behavior isolated behind small testable types where possible.
- Add or update tests for behavior changes. For bug fixes, write the failing test first when feasible.
- Run `swift test` before claiming a change is complete.
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

## Git Hygiene

- Check `git status --short` before editing and before final handoff.
- Treat existing user changes as owned by the user; do not revert them unless explicitly asked.
- Commit only files related to the requested change.
