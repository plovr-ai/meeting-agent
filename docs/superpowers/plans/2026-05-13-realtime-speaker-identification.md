# Realtime Speaker Identification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build realtime cross-meeting speaker identity matching so live captions can update local speaker labels to stable known or anonymous speaker profiles during an active meeting.

**Architecture:** Add a local speaker identity domain in `MeetingAgentCore`: profile models/store, cosine resolver, frame evidence clipper, sidecar embedding provider, and realtime runtime. Wire `MeetingRecorder` to retain recently drained PCM frames, wire `MeetingAgentViewModel` to submit changed realtime transcript segments to the runtime, and render resolved labels through the existing `LiveCaptionTurn.speaker.label` display path without rewriting raw provider speaker ids.

**Tech Stack:** Swift 5.9, XCTest, Foundation `Process`, local Python sidecar, SpeechBrain ECAPA-TDNN/PyTorch for real embedding generation.

---

### Task 1: Speaker Identity Models And Resolver

**Files:**
- Create: `Sources/MeetingAgentCore/SpeakerIdentification.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeakerIdentificationTests.swift`

- [ ] **Step 1: Write failing resolver tests**

Add tests that construct deterministic embeddings and assert cosine scoring, auto-match, review-match, anonymous creation, and profile embedding merge behavior:

```swift
func testResolverMatchesExistingProfileAboveAutoThreshold() throws {
    let profile = SpeakerProfile(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        displayName: "Allan",
        anonymousName: "Speaker 1",
        confirmationStatus: .confirmed,
        embeddings: [
            SpeakerVoiceEmbedding(modelID: "fake", vector: [1, 0, 0], durationSeconds: 4, sourceMeetingID: nil)
        ]
    )
    let resolver = SpeakerIdentityResolver(autoMatchThreshold: 0.80, reviewThreshold: 0.65)

    let result = resolver.resolve(
        candidate: SpeakerVoiceEmbedding(modelID: "fake", vector: [0.98, 0.02, 0], durationSeconds: 4, sourceMeetingID: nil),
        profiles: [profile],
        nextAnonymousName: "Speaker 2"
    )

    XCTAssertEqual(result.decision, .matched)
    XCTAssertEqual(result.profile.id, profile.id)
    XCTAssertEqual(result.displayLabel, "Allan")
    XCTAssertGreaterThan(result.confidence, 0.80)
}
```

- [ ] **Step 2: Run the new test file and verify it fails**

Run: `swift test --filter SpeakerIdentificationTests`

Expected: compile failure because the speaker identity types do not exist.

- [ ] **Step 3: Implement models and resolver**

Create `SpeakerIdentification.swift` with `SpeakerVoiceEmbedding`, `SpeakerProfile`, `SpeakerProfileConfirmationStatus`, `SpeakerIdentityDecision`, `SpeakerIdentityResolution`, `SpeakerIdentityResolver`, and cosine similarity. `resolve` returns an updated or new profile plus score metadata, and `SpeakerProfile.addEmbedding` appends bounded high-quality embeddings.

- [ ] **Step 4: Run the resolver tests**

Run: `swift test --filter SpeakerIdentificationTests`

Expected: tests pass.

### Task 2: Persistent Speaker Profile Store

**Files:**
- Modify: `Sources/MeetingAgentCore/SpeakerIdentification.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeakerProfileStoreTests.swift`

- [ ] **Step 1: Write failing store tests**

Add tests for loading an absent store as empty, saving/loading profiles, generating the next anonymous speaker name, and merging a resolved profile by id.

- [ ] **Step 2: Run store tests and verify failure**

Run: `swift test --filter SpeakerProfileStoreTests`

Expected: compile failure for missing `SpeakerProfileStore`.

- [ ] **Step 3: Implement `SpeakerProfileStore`**

Add a lock-protected JSON store with app-support default path `speaker-profiles.json`, explicit test initializer, `loadProfiles`, `saveProfiles`, `nextAnonymousName`, and `upsert`.

- [ ] **Step 4: Run store tests**

Run: `swift test --filter SpeakerProfileStoreTests`

Expected: tests pass.

### Task 3: Realtime Audio Evidence Clipper

**Files:**
- Create: `Sources/MeetingAgentCore/SpeakerAudioEvidenceStore.swift`
- Modify: `Sources/MeetingAgentCore/MeetingRecorder.swift`
- Test: `Tests/MeetingAgentCoreTests/SpeakerAudioEvidenceStoreTests.swift`

- [ ] **Step 1: Write failing evidence tests**

Add tests that append synthetic PCM frames, request clip ranges from transcript segment start/end times, verify clips are written as WAV files, verify insufficient duration returns nil, and verify old frames are pruned.

- [ ] **Step 2: Run evidence tests and verify failure**

Run: `swift test --filter SpeakerAudioEvidenceStoreTests`

Expected: compile failure for missing `SpeakerAudioEvidenceStore`.

- [ ] **Step 3: Implement `SpeakerAudioEvidenceStore`**

Implement a lock-protected cumulative audio-time frame cache. It appends drained frames, tracks start/end seconds, prunes to a configurable retention window, and writes a temporary WAV clip from frames overlapping a speaker's finalized transcript segment ranges.

- [ ] **Step 4: Wire `MeetingRecorder`**

Add a private `speakerAudioEvidenceStore`, append frames in `drainFrames`, reset it at recording start/stop, and expose `speakerEvidenceClip(for:minimumDurationSeconds:)`.

- [ ] **Step 5: Run evidence and recorder tests**

Run: `swift test --filter SpeakerAudioEvidenceStoreTests`

Expected: tests pass.

### Task 4: Sidecar Embedding Provider

**Files:**
- Create: `Sources/MeetingAgentCore/SpeakerEmbeddingProvider.swift`
- Create: `scripts/speaker-embedding.py`
- Test: `Tests/MeetingAgentCoreTests/SpeakerEmbeddingProviderTests.swift`

- [ ] **Step 1: Write failing provider tests**

Add tests that decode successful sidecar JSON, decode recoverable sidecar errors, and verify malformed vectors fail clearly.

- [ ] **Step 2: Run provider tests and verify failure**

Run: `swift test --filter SpeakerEmbeddingProviderTests`

Expected: compile failure for missing provider types.

- [ ] **Step 3: Implement Swift provider boundary**

Add `SpeakerEmbeddingProvider`, `SpeakerEmbeddingRequest`, `SpeakerEmbeddingProviderError`, `SidecarSpeakerEmbeddingProvider`, and sidecar JSON parsing. The process invocation reads request JSON on stdin and expects response JSON on stdout.

- [ ] **Step 4: Implement Python sidecar**

Create `scripts/speaker-embedding.py`. It reads JSON from stdin, loads SpeechBrain's ECAPA verifier, encodes the requested WAV, mean-pools if needed, and writes a JSON response with `modelID`, `embedding`, `durationSeconds`, `sampleRate`, and `quality`. Import failures return JSON errors instead of tracebacks where possible.

- [ ] **Step 5: Run provider tests**

Run: `swift test --filter SpeakerEmbeddingProviderTests`

Expected: tests pass without importing Python dependencies.

### Task 5: Realtime Identification Runtime

**Files:**
- Create: `Sources/MeetingAgentCore/RealtimeSpeakerIdentificationRuntime.swift`
- Test: `Tests/MeetingAgentCoreTests/RealtimeSpeakerIdentificationRuntimeTests.swift`

- [ ] **Step 1: Write failing runtime tests**

Add async tests with fake embedding provider and fake clip provider. Verify a new finalized speaker schedules one job, duplicate updates coalesce while in flight, insufficient evidence does not create a profile, and a successful resolution is published with the original local speaker id.

- [ ] **Step 2: Run runtime tests and verify failure**

Run: `swift test --filter RealtimeSpeakerIdentificationRuntimeTests`

Expected: compile failure for missing runtime.

- [ ] **Step 3: Implement runtime actor**

Implement `RealtimeSpeakerIdentificationRuntime` as an actor with lane state keyed by local speaker id. It accepts changed transcript segments, groups finalized segments by speaker, requests a clip when enough segment duration exists, calls the embedding provider, resolves against `SpeakerProfileStore`, upserts the profile, and calls an async resolution handler.

- [ ] **Step 4: Run runtime tests**

Run: `swift test --filter RealtimeSpeakerIdentificationRuntimeTests`

Expected: tests pass.

### Task 6: View Model And UI Wiring

**Files:**
- Modify: `Sources/MeetingAgentCore/MeetingAgentViewModel.swift`
- Modify: `Sources/MeetingAgentApp/MainWindowView.swift` only if needed by existing initializer data flow
- Test: `Tests/MeetingAgentCoreTests/MeetingAgentViewModelTests.swift`
- Test: `Tests/MeetingAgentCoreTests/MainWindowViewLayoutTests.swift` only if UI structure changes

- [ ] **Step 1: Write failing view model test**

Add a test that injects a fake realtime speaker identification runtime/provider, applies a transcript result with `speakerID`, publishes a resolution, and asserts `liveCaptionTurns` now show the resolved label while preserving `speaker.identifier`.

- [ ] **Step 2: Run the view model test and verify failure**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: failure because the view model does not apply identity resolutions.

- [ ] **Step 3: Wire runtime into `MeetingAgentViewModel`**

Add a `speakerIdentityMap` keyed by provider speaker id, a runtime factory injection point for tests, start/reset runtime with recording lifecycle, submit realtime changed segments after caption publication, and re-apply identity labels whenever a resolution arrives.

- [ ] **Step 4: Run view model tests**

Run: `swift test --filter MeetingAgentViewModelTests`

Expected: tests pass.

### Task 7: Full Verification

**Files:**
- All changed files

- [ ] **Step 1: Run targeted test suite**

Run:

```sh
swift test --filter SpeakerIdentificationTests
swift test --filter SpeakerProfileStoreTests
swift test --filter SpeakerAudioEvidenceStoreTests
swift test --filter SpeakerEmbeddingProviderTests
swift test --filter RealtimeSpeakerIdentificationRuntimeTests
swift test --filter MeetingAgentViewModelTests
```

Expected: all targeted tests pass.

- [ ] **Step 2: Run required project test entrypoint**

Run: `make test`

Expected: full unit test and coverage command passes.

- [ ] **Step 3: Review diff**

Run: `git diff --stat` and `git diff --check`.

Expected: no whitespace errors and only speaker identification related files changed.
