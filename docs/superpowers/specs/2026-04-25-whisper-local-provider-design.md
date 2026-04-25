# Local Whisper STT Provider Design

## Purpose

Add a second speech-to-text provider that uses a local Whisper model through `whisper.cpp`, without changing the current Core Audio capture flow or weakening the existing macOS Speech provider.

The provider should let developers run:

```sh
swift run CoreAudioTapProbe --seconds 10 --wav --stt-provider whisper --stt-locale zh-CN
```

The first version prioritizes a reliable local transcription path over real-time partial transcription. WAV recording must continue even when Whisper is not installed, misconfigured, or fails during transcription.

## Scope

In scope:

- Add `whisper` as a supported `--stt-provider` value.
- Use a local `whisper.cpp` CLI executable, such as `whisper-cli`.
- Use a local Whisper model file, such as `ggml-small.bin` or `ggml-medium.bin`.
- Write the final transcript to the existing `.record/*.txt` path.
- Preserve the existing `.record/*.wav` recording behavior.
- Add unit tests for option parsing, provider selection, configuration, language mapping, command construction, and failure handling.

Out of scope for the first version:

- Real-time partial transcript updates.
- Linking Whisper directly into the Swift package.
- Downloading or managing model files.
- Calling OpenAI's hosted transcription API.
- UI for selecting models or providers.

## Provider Naming

The provider name should be `whisper`, not `openai`.

This keeps local Whisper separate from a future hosted OpenAI transcription provider. A future API-backed provider can use `openai` or a more specific name without overloading the local model path.

## Architecture

The existing provider boundary remains the integration point:

```swift
protocol AudioFrameTranscriber: AnyObject {
    func append(_ frame: AudioFrame) throws
    func finish()
}

protocol SpeechTranscriptionProvider {
    var provider: SpeechProvider { get }
    func start(transcriptURL: URL, localeIdentifier: String) async throws -> AudioFrameTranscriber
}
```

New types:

- `SpeechProvider.whisper`: CLI enum case for the new provider.
- `WhisperSpeechTranscriptionProvider`: provider factory entry point.
- `WhisperCLITranscriber`: receives `AudioFrame` values, writes a temporary WAV, and transcribes it on `finish()`.
- `WhisperConfiguration`: resolves the local binary and model file paths.
- `WhisperLanguageMapper`: converts locale identifiers into Whisper language codes.
- `WhisperProcessRunner`: wraps `Process` execution so command behavior can be unit tested.

The factory should become:

```swift
enum SpeechTranscriptionProviderFactory {
    static func provider(for provider: SpeechProvider) -> SpeechTranscriptionProvider {
        switch provider {
        case .local:
            return LocalSpeechTranscriptionProvider()
        case .whisper:
            return WhisperSpeechTranscriptionProvider()
        }
    }
}
```

## Configuration

The first version uses environment variables:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
```

`MEETING_AGENT_WHISPER_BIN` must point to an executable file. `MEETING_AGENT_WHISPER_MODEL` must point to a readable model file.

Environment variables keep the existing command surface small. CLI flags such as `--whisper-bin` and `--whisper-model` can be added later if repeated local use makes them worthwhile.

## Data Flow

The first implementation should transcribe after capture finishes:

```text
Core Audio Tap
  -> AudioFrameRingBuffer
  -> WavFileWriter writes .record/*.wav
  -> WhisperCLITranscriber writes a temporary WAV
  -> finish()
  -> whisper-cli transcribes the temporary WAV
  -> TranscriptFileWriter writes .record/*.txt
```

This duplicates WAV writing in the first version because `SpeechTranscriptionProvider.start()` currently receives only `transcriptURL` and `localeIdentifier`, not the user-visible `wavURL`. That keeps the change local to the STT boundary.

A later optimization can extend the provider start context to include `wavURL`, allowing Whisper to reuse the visible `.record/*.wav` instead of writing its own temporary input.

## Whisper Command

The process runner should construct arguments equivalent to:

```sh
whisper-cli \
  -m /Users/allan/models/ggml-small.bin \
  -f /tmp/meeting-agent-whisper/input.wav \
  -l zh \
  -otxt \
  -of /tmp/meeting-agent-whisper/transcript
```

The generated transcript is expected at the `-of` base path with `.txt` appended. After a successful run, its contents are copied to the final transcript URL.

If the mapped language is empty, the command should omit `-l` and allow Whisper to auto-detect language.

## Language Mapping

`--stt-locale` remains a locale identifier. Whisper receives a language code.

Initial mappings:

```text
zh-CN -> zh
zh-TW -> zh
en-US -> en
ja-JP -> ja
ko-KR -> ko
fr-FR -> fr
de-DE -> de
es-ES -> es
```

For other locale identifiers, the mapper should use the component before `-` or `_`. For example, `pt-BR` becomes `pt`.

If no usable language code can be derived, the provider should omit `-l`.

## Error Handling

WAV capture is the primary artifact. Whisper failures should be captured in the transcript file and should not delete the WAV.

Startup validation errors:

- Missing `MEETING_AGENT_WHISPER_BIN`.
- Binary path does not exist.
- Binary path is not executable.
- Missing `MEETING_AGENT_WHISPER_MODEL`.
- Model path does not exist.

Runtime transcription errors:

- `whisper-cli` exits with a non-zero status.
- The expected `.txt` output file is not created.
- The process cannot be launched.

Failure transcript format:

```text
Whisper transcription unavailable: MEETING_AGENT_WHISPER_MODEL is not set
```

The provider should close its transcript writer after writing the failure reason.

## CLI Help

Usage should advertise both providers:

```text
--stt-provider local|whisper
```

`SpeechProvider.supportedValuesDescription` should become:

```text
local, whisper
```

Unknown provider errors should use that same supported-values string.

## Tests

Unit tests should cover:

- `ProbeOptions` defaults to `.local`.
- `ProbeOptions` accepts `--stt-provider whisper`.
- Unknown provider errors list `local, whisper`.
- `SpeechTranscriptionProviderFactory` returns a Whisper provider for `.whisper`.
- `WhisperLanguageMapper` maps common locales and falls back to the primary language component.
- `WhisperConfiguration` reports clear errors for missing environment variables and missing files.
- `WhisperProcessRunner` builds the expected `whisper-cli` arguments.
- `WhisperCLITranscriber` writes a transcript failure reason when the process runner fails.

`swift test` should not require a real Whisper binary or model. Real model execution should remain a manual verification step.

## Manual Verification

After implementation, verify with:

```sh
export MEETING_AGENT_WHISPER_BIN=/opt/homebrew/bin/whisper-cli
export MEETING_AGENT_WHISPER_MODEL=/Users/allan/models/ggml-small.bin
swift run CoreAudioTapProbe --seconds 10 --wav --stt-provider whisper --stt-locale zh-CN
```

Expected results:

- `.record/*.wav` exists and is playable.
- `.record/*.txt` exists.
- If Whisper is configured correctly, `.record/*.txt` contains the recognized transcript.
- If Whisper is misconfigured, `.record/*.txt` contains a clear failure reason and the WAV still exists.

## Future Work

Future improvements can include:

- Reusing the visible `.record/*.wav` instead of writing a temporary WAV.
- Adding `--whisper-bin` and `--whisper-model` CLI flags.
- Segment-based transcription for periodic transcript updates.
- Native whisper.cpp library integration for lower latency and tighter packaging.
- A separate hosted OpenAI provider for network-backed transcription.
