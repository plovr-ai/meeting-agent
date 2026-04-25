# AGENTS.md

## Project Overview

This project is intended to become a meeting agent for globalizing companies and their managers. The long-term product goal is to help managers run cross-border meetings by reducing language barriers, translating intent into localized language that sounds natural to local participants, analyzing meeting progress in real time, extracting summaries and decisions, and producing targeted analysis based on key topics and meeting goals. The agent should also help managers respond in the local language with culturally and contextually appropriate phrasing.

The current code is only the first step toward that product. Today, this repository is a Swift Package with a `MeetingAgentApp` macOS app prototype and a `CoreAudioTapProbe` command-line prototype focused on system audio capture. It captures audio from selected meeting processes through Core Audio Process Tap APIs, can write captured audio to WAV, and can use the macOS Speech framework to write a matching transcript.

The package targets macOS 14.2+ and uses Swift 5.9.

## Repository Layout

- `Package.swift` defines the Swift package, core library target, app target, CLI target, and test target.
- `Sources/MeetingAgentCore/` contains shared meeting, capture, recording, process discovery, and transcription logic.
- `Sources/MeetingAgentApp/` contains the macOS SwiftUI menu bar app prototype.
- `Sources/CoreAudioTapProbe/` contains the command-line executable implementation.
- `Sources/CoreAudioTapProbe/Info.plist` is embedded into the executable through linker flags and contains macOS permission usage strings.
- `Tests/MeetingAgentCoreTests/` contains XCTest coverage.
- `docs/superpowers/specs/` and `docs/superpowers/plans/` contain historical design and implementation notes.
- `.record/` is runtime output and must not be committed.

## Common Commands

Use these from the repository root:

```sh
swift test
swift build --product MeetingAgentApp
swift run MeetingAgentApp
swift build --product CoreAudioTapProbe
swift run CoreAudioTapProbe --list
swift run CoreAudioTapProbe --seconds 10
swift run CoreAudioTapProbe --seconds 10 --wav
swift run CoreAudioTapProbe --seconds 10 --wav --stt-provider local --stt-locale zh-CN
swift run CoreAudioTapProbe --seconds 10 --wav --stt-provider whisper --stt-locale zh-CN
swift run CoreAudioTapProbe --pid <PID> --seconds 10 --wav capture.wav
```

The app stores user meeting data under `~/Library/Application Support/MeetingAgent/Meetings/`.
The CLI still writes debug output to `.record/`.

When `--pid` is omitted, the program auto-selects the first preferred running meeting app or common Google Meet browser process. Use `--pid` to override that selection.
Implemented STT providers are `local`, backed by macOS Speech, and `whisper`, backed by a local `whisper.cpp` CLI and model.
The `whisper` STT provider uses a local `whisper.cpp` CLI and model. Configure it with `MEETING_AGENT_WHISPER_BIN` and `MEETING_AGENT_WHISPER_MODEL`, for example:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
```

Use `--stt-locale` to match the meeting language. The default is `en-US`; Chinese recognition should usually use `zh-CN`.

When `--wav` is provided without a filename, the program writes timestamped files such as:

```text
.record/20260425-132530.wav
.record/20260425-132530.txt
```

When `--wav capture.wav` is provided, the program writes:

```text
.record/capture.wav
.record/capture.txt
```

## Development Guidelines

- Prefer small, focused changes that match the existing Swift style.
- Keep platform-sensitive Core Audio and Speech behavior isolated behind small testable types where possible.
- Add or update tests for behavior changes. For bug fixes, write the failing test first when feasible.
- Run `swift test` before claiming a change is complete.
- Do not commit generated files from `.build/`, `.swiftpm/`, `DerivedData/`, or `.record/`.
- Do not remove or weaken macOS permission strings in `Info.plist` unless the related capability is removed.

## Audio And Transcription Notes

- `AudioIOReader` reads process tap audio and converts float32 linear PCM to signed 16-bit PCM.
- `WavFileWriter` writes RIFF/WAVE output.
- `RecordingOutput` owns the `.record/` file naming convention.
- `SpeechTranscriptionProvider` is the provider boundary for transcription backends.
- `LocalSpeechTranscriptionProvider` uses `SystemSpeechTranscriber`.
- `WhisperSpeechTranscriptionProvider` uses a local `whisper.cpp` CLI and model.
- `SystemSpeechTranscriber` adapts captured PCM frames into `SFSpeechAudioBufferRecognitionRequest`.
- If Speech recognition permission or availability fails, WAV recording should continue and the transcript file should contain the failure reason.

## Git Hygiene

- Check `git status --short` before editing and before final handoff.
- Treat existing user changes as owned by the user; do not revert them unless explicitly asked.
- Commit only files related to the requested change.
- If runtime recordings were created while testing, leave them ignored under `.record/`.
