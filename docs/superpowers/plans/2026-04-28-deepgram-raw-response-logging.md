# Deepgram Raw Response Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in raw Deepgram response logging for hosted and streaming transcription paths.

**Architecture:** Introduce an injectable logger protocol in the Deepgram provider file. Hosted providers log client response data before decoding, and URLSession streaming sessions log websocket payloads before mapping.

**Tech Stack:** Swift 5.9, Foundation, XCTest, SwiftPM.

---

### Task 1: Hosted Raw Response Logging

**Files:**
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/DeepgramTranscriptionProviderTests.swift`

- [ ] Add a failing hosted-provider test with a recording logger.
- [ ] Add `DeepgramRawResponseLogger`, context types, no-op logger, and env-gated stderr logger.
- [ ] Inject the logger into `DeepgramAudioTranscriptionProvider`.
- [ ] Call the logger before decoding the hosted response.
- [ ] Run `swift test --filter DeepgramTranscriptionProviderTests`.

### Task 2: Streaming Raw Response Logging

**Files:**
- Modify: `Sources/MeetingAgentCore/DeepgramTranscriptionProvider.swift`
- Modify: `Tests/MeetingAgentCoreTests/DeepgramStreamingTranscriptionProviderTests.swift`

- [ ] Add a failing websocket session test with a recording logger.
- [ ] Inject the logger into `URLSessionDeepgramStreamingTranscriptionClient` and `URLSessionDeepgramStreamingSession`.
- [ ] Log websocket string and data payloads before `DeepgramStreamingResponseMapper.segments`.
- [ ] Run `swift test --filter DeepgramStreamingTranscriptionProviderTests`.

### Task 3: Verification

**Files:**
- Modify: changed source, tests, docs

- [ ] Run `make test`.
- [ ] Review the diff for accidental request credential logging.
- [ ] Commit the implementation with `feat: log raw Deepgram responses (#54)`.
