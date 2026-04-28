# Deepgram Raw Response Logging Design

## Intent

Issue #54 asks for Deepgram raw return data logging to make provider debugging easier. The implementation should capture the raw JSON payloads returned by Deepgram before any decoding or transcript mapping, without exposing API keys or request headers.

## Requirements

- Log hosted Deepgram transcription response bodies before `DeepgramResponse` decoding.
- Log streaming Deepgram websocket text and data messages before `DeepgramStreamingResponseMapper` mapping.
- Keep normal app runs private by disabling raw response logging unless explicitly enabled.
- Provide an injectable logger so tests and future meeting-artifact logging can capture payloads without relying on process stderr.
- Preserve existing transcription behavior when logging is disabled.

## Non-Requirements

- No UI setting in this change.
- No request body, audio frame, API key, or header logging.
- No new persisted meeting artifact format.

## Selected Approach

Add a small `DeepgramRawResponseLogger` boundary in `DeepgramTranscriptionProvider.swift`. Hosted transcription providers call it after receiving client data and before decoding. URLSession streaming sessions call it for each websocket text or data message before mapping segments.

The default logger is environment-gated: `MEETING_AGENT_DEEPGRAM_RAW_RESPONSE_LOG=1` enables stderr logging; all other values use a no-op logger. Tests inject a recording logger to assert the payload and source path.

## Test Plan

- Add a hosted transcription test proving the raw response is captured before normal utterance mapping.
- Add a streaming session test proving websocket string and data payloads are captured before mapping.
- Run focused Deepgram tests, then `make test`.
