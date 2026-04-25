# CoreAudioTapProbe Design

Date: 2026-04-25

## Goal

Build the first macOS audio-capture prototype for the meeting agent. The prototype validates that the app can capture meeting audio from another running process using Core Audio Process Tap on macOS 14.2 or later.

This design focuses only on receiving meeting audio. Sending audio back into the meeting, virtual microphone output, TTS playback, speaker diarization, and full meeting-agent intelligence are outside this phase.

## Product Assumptions

- The first version targets macOS 14.2 or later.
- The user manually selects the meeting-related process to capture.
- The selected process may be a native meeting app, such as Zoom or Teams, or a browser hosting a meeting, such as Chrome, Arc, or Safari.
- The app does not mute the original meeting audio. The user can still hear the meeting normally.
- ScreenCaptureKit is not part of the first implementation. It remains a future fallback option.

## Architecture

The prototype is split into five small components:

```text
Running Process Discovery
        -> Audio Tap Manager
        -> HAL Aggregate Device
        -> Audio IO Reader
        -> Audio Frame Stream
```

### Running Process Discovery

This component lists candidate apps using `NSWorkspace.shared.runningApplications`.

The first version should expose:

- Process ID
- Display name
- Bundle identifier, when available

The UI or debug interface should prioritize common meeting and browser apps, but still allow selecting other running apps.

Suggested model:

```swift
struct AudioCaptureTarget {
    let processID: pid_t
    let displayName: String
    let bundleIdentifier: String?
}
```

### Audio Tap Manager

This component creates and destroys the Core Audio Process Tap.

It should:

- Build a `CATapDescription` for the selected process.
- Call `AudioHardwareCreateProcessTap`.
- Keep the returned `AudioObjectID`.
- Call `AudioHardwareDestroyProcessTap` when capture stops.

Default tap behavior:

- `isPrivate = true`
- Do not mute captured process audio.
- Capture only the selected process.
- Prefer mono mixdown for the first prototype, because speech recognition usually does not need stereo input.

### HAL Aggregate Device

The tap must be attached to a HAL aggregate device so the app can read it as an input stream.

This component should:

- Create a temporary aggregate device.
- Read the tap UID from `kAudioTapPropertyUID`.
- Add the tap UID to `kAudioAggregateDevicePropertyTapList`.
- Expose the aggregate device ID to the IO reader.
- Destroy the aggregate device when capture stops.

This component should hide `AudioObjectID` and Core Audio property plumbing from higher-level code.

### Audio IO Reader

This component reads audio buffers from the aggregate device in real time.

It should normalize output to a consistent speech-friendly format before sending frames downstream:

- Mono
- 16 kHz target sample rate
- PCM suitable for streaming ASR

The exact PCM representation can be adjusted once the first ASR provider is selected. Until then, float32 PCM is acceptable inside the app, with conversion at provider boundaries.

Suggested frame model:

```swift
struct AudioFrame {
    let pcm: Data
    let sampleRate: Double
    let channelCount: Int
    let timestamp: ContinuousClock.Instant
}
```

### Audio Frame Stream

Higher-level meeting-agent features should not depend on Core Audio APIs. They should consume a simple async stream:

```swift
protocol MeetingAudioCapture {
    func start(target: AudioCaptureTarget) async throws
    func stop()
    var audioFrames: AsyncStream<AudioFrame> { get }
}
```

This boundary allows ScreenCaptureKit or other capture providers to be added later without rewriting transcription, translation, or meeting-summary logic.

## Permissions

The macOS app must include `NSAudioCaptureUsageDescription` in `Info.plist`.

The first time capture starts, macOS should prompt the user for system audio recording permission. The prototype should surface a clear error if permission is denied or not yet granted.

## Prototype UX

The first implementation can be a minimal macOS debug app rather than the final product UI.

Minimum interactions:

1. Show a list of running apps.
2. Let the user select a process.
3. Start capture.
4. Show live level metering or write captured audio to a WAV file.
5. Stop capture and clean up the tap and aggregate device.

## Verification

The prototype is successful when:

1. A user can select a running meeting or browser process.
2. The app can create a Core Audio Process Tap for that process.
3. macOS requests the expected audio capture permission.
4. The app receives continuous audio frames while the target process plays meeting audio.
5. The captured audio can be verified through either a WAV recording or live audio level display.
6. Stopping capture destroys the tap and aggregate device without requiring the user to restart Core Audio or the target meeting app.

## Deferred Work

- ScreenCaptureKit fallback.
- Support for macOS versions earlier than 14.2.
- Automatic meeting-app detection.
- Browser tab-level meeting detection.
- Speaker diarization.
- Realtime transcription, translation, and summarization.
- Virtual microphone output and sending translated speech back into the meeting.
- Production installer and notarization flow.

