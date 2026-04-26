# Realtime Language Translation Design

## Goal

Add an independent realtime language translation chain that users can enable while a meeting is already being recorded. The chain reuses the same Core Audio process capture as the main recording path, sends the captured meeting audio to OpenAI `gpt-realtime` over WebSocket, plays translated target-language speech locally, and shows the translated target-language text in the app.

The main meeting chain remains the source of truth for the meeting record:

```text
AudioCaptureSession
  -> MeetingRecorder
      -> WAV
      -> source-language STT
      -> source transcript
      -> summary, decisions, action items, exports
```

The realtime translation chain is an auxiliary experience layer:

```text
AudioCaptureSession
  -> RealtimeTranslationController
      -> OpenAIRealtimeSpeechTranslationProvider
      -> local target-language audio playback
      -> live target-language text display
```

## Scope

In scope:

- Add a realtime translation session that can start and stop independently during active recording.
- Reuse the current meeting audio capture frames rather than opening a second capture session.
- Implement the first provider as an OpenAI Realtime WebSocket provider for `gpt-realtime`.
- Send captured audio frames to the provider as `input_audio_buffer.append` events.
- Receive translated audio from `response.output_audio.delta` and play it locally.
- Receive translated text from `response.output_audio_transcript.delta` and show it in the meeting UI.
- Keep realtime translation errors isolated from recording, WAV writing, source STT, and summary generation.
- Stop any active realtime translation session automatically when recording stops.

Out of scope for the first implementation:

- Sending translated speech back into Teams, Zoom, or another meeting app through a virtual audio device.
- Persisting realtime translated audio or text as an official meeting artifact.
- Replacing the canonical source-language transcript with translated output.
- Guaranteeing exact parity between realtime interpretation text and any later official translation.
- Supporting non-OpenAI realtime speech-to-speech providers.
- Full settings-page account management for OpenAI credentials.

## User Experience

When a meeting is recording, the meeting detail view shows a Live Translation control. The user can choose a target locale and click Start Live Translation.

While starting, the UI shows `Connecting`. Once the WebSocket session is ready, it shows `Connected`, starts playing translated target-language audio through the local speaker, and displays target-language live text as it arrives.

The user can click Stop Live Translation at any time. This stops the realtime session and playback, but recording and source STT continue.

If translation fails, the UI shows a failure state and a retry action. The meeting recorder continues unaffected.

## Architecture

### Audio Fan-Out

`MeetingRecorder.drainFrames()` is the existing point where captured frames are drained from `AudioCaptureSession.frameBuffer` and sent to WAV writing and source STT.

The design adds a non-owning realtime audio consumer at this point:

```text
drained frames
  -> WavFileWriter.append
  -> AudioFrameTranscriber.append
  -> RealtimeTranslationController.append
```

The translation append path must never block the recorder. If realtime translation cannot keep up, it drops queued translation frames and reports degraded status rather than delaying WAV writing or STT.

### RealtimeTranslationController

`RealtimeTranslationController` owns the lifecycle of one realtime translation session for the active meeting.

Responsibilities:

- Validate that recording is active before starting.
- Build a `RealtimeTranslationConfiguration`.
- Start the configured `RealtimeSpeechTranslationProvider`.
- Accept captured `AudioFrame` batches from the recorder.
- Forward frames to the active session on a background task.
- Consume provider events and update `LiveTranslationStore`.
- Forward output audio deltas to `AudioPlaybackSink`.
- Stop and clean up the session when the user stops translation or recording ends.

The controller does not own the `AudioCaptureSession`, meeting record, transcript files, or summary generation.

### Provider Boundary

The provider boundary is specific to realtime speech translation and separate from the existing bilingual subtitle provider protocols.

```swift
public protocol RealtimeSpeechTranslationProvider {
    var descriptor: ProviderDescriptor { get }
    func start(configuration: RealtimeTranslationConfiguration) async throws -> RealtimeTranslationSession
}

public protocol RealtimeTranslationSession {
    var events: AsyncStream<RealtimeTranslationEvent> { get }
    func append(_ frames: [AudioFrame]) async throws
    func stop() async
}
```

`RealtimeTranslationEvent` includes:

- `connected`
- `targetAudioDelta(Data)`
- `targetTextDelta(String)`
- `targetTextFinal(String)`
- `rateLimitsUpdated`
- `failed(String)`
- `stopped`

### OpenAI Realtime WebSocket Provider

The first provider is `OpenAIRealtimeSpeechTranslationProvider`.

It connects to:

```text
wss://api.openai.com/v1/realtime?model=gpt-realtime
```

Authentication uses:

```text
Authorization: Bearer <MEETING_AGENT_OPENAI_API_KEY>
```

On connection, it sends a `session.update` event:

```json
{
  "type": "session.update",
  "session": {
    "type": "realtime",
    "model": "gpt-realtime",
    "instructions": "You are a real-time meeting interpreter. Translate all incoming speech into zh-CN. Output only the translation. Preserve meaning, tone, intent, names, numbers, dates, and business context. Do not answer the speaker or add commentary.",
    "audio": {
      "input": {
        "turn_detection": {
          "type": "server_vad"
        }
      },
      "output": {
        "voice": "marin",
        "format": {
          "type": "audio/pcm",
          "rate": 24000
        }
      }
    }
  }
}
```

The exact event shape should follow the current OpenAI GA Realtime API. The implementation should keep the session JSON isolated so it can be adjusted if the API field names change.

Captured audio frames are converted to PCM16 bytes, base64 encoded, and sent as:

```json
{
  "type": "input_audio_buffer.append",
  "audio": "<base64-pcm16>"
}
```

The provider listens for:

- `response.output_audio.delta`: base64 target-language audio chunks for local playback.
- `response.output_audio_transcript.delta`: incremental transcript of the translated output audio.
- `response.output_audio_transcript.done`: final text for the current translated output.
- `response.output_audio.done`: output audio completion marker.
- `response.done`: response completion and usage marker.
- `error`: provider/API failure.
- `rate_limits.updated`: optional diagnostics.

The first version uses server-side VAD. The app does not manually commit every utterance unless testing shows the model fails to create timely responses from process audio.

## Configuration

The first implementation uses environment variables rather than settings UI fields:

```text
MEETING_AGENT_OPENAI_API_KEY
MEETING_AGENT_REALTIME_MODEL=gpt-realtime
MEETING_AGENT_REALTIME_TARGET_LOCALE=zh-CN
MEETING_AGENT_REALTIME_VOICE=marin
```

If `MEETING_AGENT_OPENAI_API_KEY` is missing, the UI disables Start Live Translation or shows a clear configuration error. The recorder remains usable.

The app may continue to use `SpeechTranscriptionConfiguration.targetLocaleIdentifier` as the default target locale if present, but realtime translation should have its own configuration type so later settings can diverge from subtitle translation.

## Audio Playback

`AudioPlaybackSink` accepts PCM output chunks from the provider and plays them through the local default output device.

The OpenAI provider should request PCM output at a known sample rate, initially 24 kHz mono PCM16. If the playback implementation requires a different format, add a small output converter at the sink boundary.

Playback failure is isolated:

- Target-language text continues to display.
- The UI shows playback failed.
- The provider session can remain connected unless playback failure makes the user stop translation.

## Data Model

Realtime translation state is separate from the canonical meeting transcript.

```swift
public enum RealtimeTranslationStatus: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}

public struct LiveTranslationTurn: Identifiable, Equatable {
    public var id: String
    public var targetLocale: String
    public var text: String
    public var isFinal: Bool
    public var createdAt: Date
}
```

`LiveTranslationStore` maintains the current target-language text stream for UI display. It can coalesce deltas into the active turn and finalize text when `response.output_audio_transcript.done` arrives.

First implementation keeps this state in memory only. If persistence is added later, it should write a separate live interpretation artifact and label it as realtime interpretation, not official translation.

## View Model Integration

`MeetingAgentViewModel` gains published realtime translation state:

```swift
@Published public private(set) var realtimeTranslationStatus: RealtimeTranslationStatus
@Published public private(set) var liveTranslationTurns: [LiveTranslationTurn]
```

It exposes:

```swift
public func startRealtimeTranslation(targetLocale: String) async
public func stopRealtimeTranslation() async
```

`stopRecording` and `stopRecordingAndGenerateSummary` call `stopRealtimeTranslation()` before or during recorder cleanup.

The view model does not pass realtime translation output into summary generation.

## Error Handling

- Missing API key: translation start fails with a configuration error; recording continues.
- WebSocket connection failure: translation status becomes failed; recording continues.
- Provider event parse failure: record a provider error and stop only the translation session.
- Send backlog: drop older unsent translation frames and show degraded translation status if sustained.
- Output audio playback failure: continue target text display and show playback failure.
- Recording stopped: stop translation session and playback.

## Testing

Unit tests should cover:

- Starting translation is rejected or reported clearly when no recording is active.
- Missing OpenAI API key produces a translation-only failure.
- Recorder fan-out sends drained frames to translation without changing WAV/STT behavior.
- Translation append failures do not throw out of `MeetingRecorder.drainFrames()`.
- `LiveTranslationStore` coalesces transcript deltas and finalizes turns.
- Stopping recording stops the active translation controller.
- Provider event decoding maps OpenAI event names into `RealtimeTranslationEvent`.

Integration tests should use a fake WebSocket transport and fake audio playback sink. Real OpenAI API calls should not be part of the default `swift test` suite.

## Implementation Notes

Swift Package Manager does not include a built-in WebSocket client across all target contexts. The implementation should first check whether `URLSessionWebSocketTask` is sufficient for the macOS app target. If package-level Linux support becomes relevant later, introduce a small transport protocol and a platform-specific WebSocket implementation.

The provider should keep OpenAI event payload structs private or internal. Public app-facing types should remain provider-neutral so future realtime providers can be added without changing the UI.

The initial prompt must be generated from configuration:

```text
You are a real-time meeting interpreter.
Translate all incoming speech into <targetLocale>.
Output only the translation.
Preserve meaning, tone, intent, names, numbers, dates, and business context.
Do not answer the speaker or add commentary.
```

The realtime chain is successful when a user can start recording a meeting, click Start Live Translation, hear translated target-language speech locally, see translated target-language text in the meeting detail view, stop translation without stopping recording, and stop recording without leaving any realtime session running.
