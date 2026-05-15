# Online Meeting Microphone Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Capture local microphone speech during online meeting recordings and send it downstream as standard `Me` speaker metadata without changing offline discussion behavior.

**Architecture:** Add a composite `AudioCaptureSource.processWithMicrophone` mode for process recordings. `MeetingRecorder` keeps the existing process pipeline as the primary path, adds an optional microphone capture/writer/transcriber pipeline, and wraps microphone speech events before they reach `RecordingTranscriptUpdateSink`. The merged transcript remains a single `CaptionDocument` consumed by captions, summaries, exports, and knowledge packages.

**Tech Stack:** Swift 5.9, XCTest, Core Audio capture abstractions, existing `SpeechRecognitionEvent` / `TranscriptSegment` / `CaptionDocument` pipeline.

---

### Task 1: Model Composite Capture And Microphone Artifact Metadata

**Files:**
- Modify: `Sources/MeetingAgentCore/AudioCaptureSource.swift`
- Modify: `Sources/MeetingAgentCore/MeetingRecord.swift`
- Modify: `Sources/MeetingAgentCore/MeetingStore.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecordTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingStoreTests.swift`

- [ ] **Step 1: Write failing source and metadata tests**

Add tests that prove the new composite source exposes a process target, keeps a process display name, and decodes legacy meeting metadata without a microphone URL.

```swift
func testProcessWithMicrophoneSourcePreservesTargetAndKind() {
    let target = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: "us.zoom.xos")
    let source = AudioCaptureSource.processWithMicrophone(target, microphoneDisplayName: "Studio Mic")

    XCTAssertEqual(source.kind, .processWithMicrophone)
    XCTAssertEqual(source.displayName, "Zoom")
    XCTAssertEqual(source.processID, 42)
    XCTAssertEqual(source.processTarget, target)
    XCTAssertEqual(source.microphoneDisplayName, "Studio Mic")
}

func testMeetingRecordDecodesLegacyMetadataWithoutMicrophoneAudioURL() throws {
    let data = Data("""
    {
      "id" : "11111111-1111-1111-1111-111111111111",
      "name" : "Legacy",
      "startedAt" : "2026-05-15T00:00:00Z",
      "audioURL" : "file:///tmp/audio.wav",
      "transcriptURL" : "file:///tmp/transcript.txt"
    }
    """.utf8)

    let record = try JSONDecoder.meetingAgent.decode(MeetingRecord.self, from: data)

    XCTAssertNil(record.microphoneAudioURL)
    XCTAssertEqual(record.captureMode, .process)
}
```

- [ ] **Step 2: Run tests and verify failure**

Run:

```sh
swift test --filter MeetingRecordTests
swift test --filter MeetingStoreTests
```

Expected: compile failures for `processWithMicrophone`, `microphoneAudioURL`, and `captureMode`.

- [ ] **Step 3: Implement model additions**

Add `processWithMicrophone` and a capture mode enum with legacy-safe defaults:

```swift
public enum AudioCaptureSourceKind: String, Codable, Equatable {
    case process
    case microphone
    case processWithMicrophone
}

public enum MeetingCaptureMode: String, Codable, Equatable {
    case process
    case microphone
    case processWithMicrophone
}

public enum AudioCaptureSource: Equatable {
    case process(AudioCaptureTarget)
    case microphone(displayName: String = "Computer Microphone")
    case processWithMicrophone(AudioCaptureTarget, microphoneDisplayName: String = "Computer Microphone")
}
```

Update computed properties so `.processWithMicrophone` returns the process target for `processTarget`, the target pid for `processID`, the target display name for `displayName`, and the microphone display name through a new `microphoneDisplayName` computed property.

Add `MeetingRecord.microphoneAudioURL` and `MeetingRecord.captureMode`, include both in the initializer and coding keys, and default missing values to `nil` and `.process`.

- [ ] **Step 4: Update store creation**

In `MeetingStore.createMeeting`, set `microphoneAudioURL` to `directory.appendingPathComponent("audio-microphone.wav")`. Keep `audioURL` as `audio.wav`.

Set `captureMode` when records are prepared in `MeetingRecorder.prepareRecord(named:source:)` based on `source.kind`.

- [ ] **Step 5: Run model/store tests**

Run:

```sh
swift test --filter MeetingRecordTests
swift test --filter MeetingStoreTests
```

Expected: both test groups pass.

### Task 2: Add Microphone Speaker Attribution Adapter

**Files:**
- Create: `Sources/MeetingAgentCore/SpeechEventSpeakerAttribution.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeechEventSpeakerAttributionTests.swift`

- [ ] **Step 1: Write failing adapter tests**

Add tests for hypothesis, final, and provider status behavior:

```swift
func testMicrophoneAttributionRewritesHypothesisAndFinalSpeakerToMe() {
    let sink = RecordingSpeechEventSink()
    let attributed = MicrophoneSpeakerAttributionSink(downstream: sink)
    let payload = SpeechUtterancePayload(
        providerID: "deepgram-transcribe",
        providerUtteranceID: "utt-1",
        speaker: TranscriptSpeaker(identifier: "provider-speaker-7", label: "Speaker 7"),
        startTimeSeconds: 1,
        endTimeSeconds: 2,
        text: "I can take the launch follow-up",
        language: "en-US",
        confidence: 0.91,
        boundary: SpeechBoundary(speechFinal: true)
    )

    attributed.receive(.final(payload))

    XCTAssertEqual(sink.events.first?.payload?.speaker, TranscriptSpeaker(identifier: "local-user", label: "Me"))
}

func testMicrophoneAttributionLeavesProviderStatusUnchanged() {
    let sink = RecordingSpeechEventSink()
    let attributed = MicrophoneSpeakerAttributionSink(downstream: sink)

    attributed.receive(.providerStatus(ProviderStatus(providerID: "deepgram-transcribe", message: "connected")))

    XCTAssertEqual(sink.events, [.providerStatus(ProviderStatus(providerID: "deepgram-transcribe", message: "connected"))])
}
```

- [ ] **Step 2: Run adapter tests and verify failure**

Run:

```sh
swift test --filter SpeechEventSpeakerAttributionTests
```

Expected: compile failure for missing adapter.

- [ ] **Step 3: Implement adapter**

Create a small final class that conforms to `SpeechRecognitionEventSink` and rewrites only utterance events:

```swift
public final class MicrophoneSpeakerAttributionSink: SpeechRecognitionEventSink {
    public static let localUserSpeaker = TranscriptSpeaker(identifier: "local-user", label: "Me")
    private weak var downstream: SpeechRecognitionEventSink?

    public init(downstream: SpeechRecognitionEventSink) {
        self.downstream = downstream
    }

    public func receive(_ event: SpeechRecognitionEvent) {
        downstream?.receive(Self.attributed(event))
    }

    public static func attributed(_ event: SpeechRecognitionEvent) -> SpeechRecognitionEvent {
        switch event {
        case .hypothesis(let payload):
            return .hypothesis(payload.withSpeaker(localUserSpeaker))
        case .final(let payload):
            return .final(payload.withSpeaker(localUserSpeaker))
        case .providerStatus:
            return event
        }
    }
}
```

Add an internal `SpeechUtterancePayload.withSpeaker(_:)` helper that recreates the payload with all fields preserved except `speaker`. Do not change `providerID`, utterance ids, timing, text, language, confidence, or boundary.

- [ ] **Step 4: Run adapter tests**

Run:

```sh
swift test --filter SpeechEventSpeakerAttributionTests
```

Expected: tests pass.

### Task 3: Make MeetingRecorder Support A Secondary Microphone Pipeline

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`

- [ ] **Step 1: Split test fixtures for process and microphone**

Update `RecorderFixture` so it can provide separate process and microphone fake sessions, writers, and transcribers:

```swift
let processSession = FakeRecorderCaptureSession(sampleRate: 16_000, channelCount: 1)
let microphoneSession = FakeRecorderCaptureSession(sampleRate: 16_000, channelCount: 1)
let processWriter = FakeAudioFrameWriter()
let microphoneWriter = FakeAudioFrameWriter()
let processTranscriber = FakeAudioFrameTranscriber()
let microphoneTranscriber = FakeAudioFrameTranscriber()
```

Use the full `MeetingRecorder` initializer with `processCaptureSessionFactory` and `microphoneCaptureSessionFactory` instead of the single `captureSessionFactory` convenience initializer.

- [ ] **Step 2: Write failing dual-pipeline recorder tests**

Add tests:

```swift
func testProcessWithMicrophoneStartsTwoCaptureSessionsAndTranscribers() async throws {
    let fixture = try RecorderFixture()
    let record = try fixture.store.createMeeting(name: "Zoom", startedAt: Date()).record

    try await fixture.recorder.startRecording(
        source: .processWithMicrophone(fixture.target),
        record: record,
        speechConfiguration: .default
    )

    XCTAssertEqual(fixture.processSession.startedSources, [.processWithMicrophone(fixture.target)])
    XCTAssertEqual(fixture.microphoneSession.startedSources, [.microphone(displayName: "Computer Microphone")])
    XCTAssertEqual(fixture.transcriberFactory.requests.count, 2)
}

func testMicrophoneFramesWriteOnlyMicrophoneAudioAndAreAttributedAsMe() async throws {
    let fixture = try RecorderFixture()
    var record = try fixture.store.createMeeting(name: "Zoom", startedAt: Date()).record
    record.captureMode = .processWithMicrophone

    try await fixture.recorder.startRecording(source: .processWithMicrophone(fixture.target), record: record, speechConfiguration: .default)
    fixture.microphoneTranscriber.emitSpeechEvent(.final(testPayloadEvent(speakerID: "provider-speaker-1", text: "I agree")))

    let results = fixture.recorder.drainTranscriptUpdates()

    XCTAssertEqual(results.first?.document.segments.first?.speakerID, "local-user")
    XCTAssertEqual(results.first?.document.segments.first?.speakerLabel, "Me")
}
```

Also add a test that a process-stream event with `deepgram-speaker-1` is not rewritten to `Me`.

- [ ] **Step 3: Run recorder tests and verify failure**

Run:

```sh
swift test --filter MeetingRecorderTests
```

Expected: compile/runtime failures because the recorder has one session/writer/transcriber.

- [ ] **Step 4: Introduce pipeline storage**

In `MeetingRecorder`, keep the existing primary fields and add microphone-side fields:

```swift
private var microphoneCaptureSession: AudioCaptureSessionManaging?
private var microphoneWriter: AudioFrameWriting?
private var microphoneTranscriber: AudioFrameTranscriber?
private var microphoneTranscriptAttributionSink: MicrophoneSpeakerAttributionSink?
private var microphoneProcessingTask: Task<Void, Never>?
```

Keep `captureSession`, `writer`, and `transcriber` as the primary process pipeline for compatibility.

- [ ] **Step 5: Start the microphone pipeline only for composite source**

After primary process session starts successfully, if `source.kind == .processWithMicrophone`, create and start a microphone session with `.microphone(displayName: source.microphoneDisplayName)`.

Use `record.microphoneAudioURL` for the microphone writer. If the URL is nil, skip mic WAV writing but still allow mic transcription.

Start a second transcriber with the same `SpeechTranscriptionConfiguration`, sample rate, and channel count from the microphone session. Pass the same `RecordingTranscriptUpdateSink` as `transcriptUpdateSink`, but pass `MicrophoneSpeakerAttributionSink(downstream: updateSink)` as `speechEventSink`.

- [ ] **Step 6: Drain both frame buffers**

Refactor frame processing into a helper that accepts session, writer, transcriber, and source label:

```swift
private func processFrames(
    _ frames: [AudioFrame],
    writer: AudioFrameWriting?,
    transcriber: AudioFrameTranscriber?,
    audioSource: RecorderAudioSource,
    bufferBacklog: Int,
    droppedFrameCount: Int
) throws
```

The primary process path continues to append frames to `speakerAudioEvidenceStore`; the microphone path should not feed the existing speaker identity evidence runtime in this issue.

- [ ] **Step 7: Stop both pipelines**

Update `stopRecording` to cancel both processing tasks, finish both frame buffers, drain both sessions, close both writers, call `finish()` on both transcribers, stop both capture sessions, and nil out both sets of fields.

Make sure a microphone transcriber failure reason does not overwrite a process failure reason unless process has no failure. Log mic failures separately through `performanceEventLogger`.

- [ ] **Step 8: Run recorder tests**

Run:

```sh
swift test --filter MeetingRecorderTests
```

Expected: tests pass.

### Task 4: Route Online Meeting Starts Through Composite Source

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`

- [ ] **Step 1: Write failing ViewModel routing tests**

Add tests:

```swift
func testOnlineMeetingStartUsesProcessWithMicrophoneSource() async throws {
    let fixture = try ViewModelRecorderFixture()
    let target = AudioCaptureTarget(processID: 42, displayName: "Zoom", bundleIdentifier: "us.zoom.xos")
    let viewModel = MeetingAgentViewModel(store: fixture.store, recorder: fixture.recorder, processTargetsProvider: { [] })

    try await viewModel.startRecording(for: target)

    XCTAssertEqual(fixture.processSession.startedSources.first, .processWithMicrophone(target))
    XCTAssertEqual(viewModel.selectedMeeting?.captureMode, .processWithMicrophone)
}

func testOfflineMicrophoneRecordingDoesNotUseProcessWithMicrophoneSource() async throws {
    let fixture = try ViewModelRecorderFixture()
    let viewModel = MeetingAgentViewModel(store: fixture.store, recorder: fixture.recorder, processTargetsProvider: { [] })

    try await viewModel.startOfflineMicrophoneRecording()

    XCTAssertEqual(fixture.processSession.startedSources, [])
    XCTAssertEqual(fixture.microphoneSession.startedSources.first, .microphone(displayName: "Computer Microphone"))
}
```

- [ ] **Step 2: Run ViewModel tests and verify failure**

Run:

```sh
swift test --filter MeetingAgentViewModelTests
```

Expected: online meeting still starts `.process`.

- [ ] **Step 3: Update online meeting start paths**

In `startRecordingPreparedRecord`, set:

```swift
let source = AudioCaptureSource.processWithMicrophone(candidate)
activeSource = source
```

Call:

```swift
try await recorder.startRecording(
    source: source,
    record: record,
    speechConfiguration: recordingConfiguration
)
```

Do the same for paths that accept a pending candidate. Keep `startOfflineMicrophoneRecording` unchanged.

- [ ] **Step 4: Run ViewModel tests**

Run:

```sh
swift test --filter MeetingAgentViewModelTests
```

Expected: tests pass.

### Task 5: Verify Merged Transcript Consumption And Stop Persistence

**Files:**
- Modify: `Tests/MeetingAgentCoreTests/MeetingRecorderTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/TranscriptConsumptionViewTests.swift`
- Modify: `Tests/MeetingAgentCoreTests/MeetingExportServiceTests.swift` if an existing export test needs explicit `Me` coverage

- [ ] **Step 1: Add persistence regression**

In `MeetingRecorderTests`, start a composite recording, emit one process final event and one microphone final event, stop recording, load `transcript.json`, and assert both turns are present:

```swift
XCTAssertTrue(document.turns.contains { $0.speakerID == "local-user" && $0.speakerLabel == "Me" })
XCTAssertTrue(document.turns.contains { $0.speakerID == "deepgram-speaker-1" && $0.speakerLabel != "Me" })
```

- [ ] **Step 2: Add consumption regression**

In `TranscriptConsumptionViewTests`, project a `CaptionDocument` with a `Me` turn and assert `finalTurns.first?.speakerLabel == "Me"`.

- [ ] **Step 3: Run persistence and consumption tests**

Run:

```sh
swift test --filter MeetingRecorderTests
swift test --filter TranscriptConsumptionViewTests
```

Expected: pass.

### Task 6: Local Verification And Implementation Commit

**Files:**
- All changed files

- [ ] **Step 1: Run focused tests serially**

Run:

```sh
swift test --filter SpeechEventSpeakerAttributionTests
swift test --filter MeetingRecordTests
swift test --filter MeetingStoreTests
swift test --filter MeetingRecorderTests
swift test --filter MeetingAgentViewModelTests
swift test --filter TranscriptConsumptionViewTests
```

Expected: all pass. Keep SwiftPM commands serial in this worktree.

- [ ] **Step 2: Run app build**

Run:

```sh
swift build --product MeetingAgentApp
```

Expected: build succeeds.

- [ ] **Step 3: Run required project verification**

Run:

```sh
make test
```

Expected: unit tests and coverage pass. If another worktree is using the coverage scratch path, rerun with a worktree-specific `MEETING_AGENT_COVERAGE_SCRATCH_PATH`.

- [ ] **Step 4: Review diff**

Run:

```sh
git diff --check
git diff --stat
```

Expected: no whitespace errors and only issue-related source, tests, spec, and plan files changed.

- [ ] **Step 5: Commit implementation**

Commit after tests pass:

```sh
git add Sources/MeetingAgentCore Tests/MeetingAgentCoreTests docs/superpowers/plans/2026-05-15-online-meeting-microphone-attribution.md
git commit -m "feat: capture microphone as Me in online meetings (#155)"
```

Commit body should mention:

```text
Adds process-with-microphone recording for online meetings, keeps audio.wav as process audio, writes microphone audio separately, and attributes microphone STT events to Me.

Closes #155
```

