# Realtime Speaker Identification Design

## Goal

Identify the same human speaker across different meetings while a meeting is still in progress, so live captions can move from local provider labels such as `Speaker 2` to stable names such as `Allan` or a reusable anonymous profile such as `Speaker 4`.

The feature must preserve the current realtime caption and translation guarantees. Voice identity work runs beside the caption pipeline; it never blocks transcript ingestion, caption chunking, overlay publication, translation scheduling, or meeting recording.

## Scope

Build the first complete local voice-identity path:

- Detect new local speaker lanes from realtime transcript segments.
- Accumulate enough same-speaker audio evidence during the active meeting.
- Generate local voice embeddings with a Python sidecar backed by SpeechBrain ECAPA-TDNN.
- Match embeddings against a local cross-meeting speaker profile store.
- Publish realtime speaker identity resolutions so the UI can update visible speaker labels during the meeting.
- Persist confirmed and anonymous speaker profiles outside individual meeting export directories.
- Keep the raw STT provider speaker identifiers in transcript data so existing caption and translation projection logic remains stable.

Out of scope for the first implementation:

- A full speaker-confirmation management UI.
- Cloud speaker recognition.
- Replacing provider diarization. Deepgram diarization or future provider speaker labels remain the source of local speaker lanes.
- Reprocessing historical meetings automatically.
- Exporting long-term voice embeddings with meeting exports.

## Product Behavior

When a new local speaker appears during a meeting, the UI initially shows the existing generated label, for example `Speaker 2`. In the background, the app collects several seconds of audio evidence for that local speaker. Once enough evidence is available, the app invokes the local embedding sidecar and compares the result to the local speaker profile store.

If the match is high confidence, live captions update to the matched profile display name. If no high-confidence match exists, the app creates or reuses a stable anonymous profile name. If the match lands in an ambiguous range, the runtime publishes a resolution that marks the identity as needing confirmation, but the UI can continue showing the best safe display name.

Existing visible caption turns may refresh their speaker display label after a resolution arrives. The underlying `TranscriptSegment.speakerID`, caption `sourceSegmentIDs`, translation lane IDs, and persisted translation records are not rewritten by the identity layer.

## Architecture

### Core Types

- `SpeakerVoiceEmbedding`: stores a model identifier, vector values, source duration, created date, and quality metadata.
- `SpeakerProfile`: stores a stable profile id, optional display name, anonymous fallback name, embeddings, source meeting ids, confirmation status, and timestamps.
- `SpeakerIdentityResolution`: maps one meeting-local `TranscriptSpeaker` to a `SpeakerProfile` with confidence, decision state, and display label.
- `SpeakerProfileStore`: reads and writes profiles at `~/Library/Application Support/MeetingAgent/speaker-profiles.json`.
- `SpeakerIdentityResolver`: compares a candidate embedding with stored profile embeddings using cosine similarity and threshold rules.
- `SpeakerEmbeddingProvider`: protocol for generating an embedding from a WAV clip.
- `SidecarSpeakerEmbeddingProvider`: Swift implementation that invokes `scripts/speaker-embedding.py`.
- `RealtimeSpeakerIdentificationRuntime`: active-meeting coordinator that observes transcript segments, requests audio clips, schedules embedding work, resolves identity, and publishes speaker label updates.

### Python Sidecar

The sidecar script lives at `scripts/speaker-embedding.py`.

Input is a JSON request containing:

- WAV file path.
- Start and end offsets or a temporary clip path.
- Model id, defaulting to SpeechBrain ECAPA-TDNN.
- Minimum speech duration requirements.

Output is JSON containing:

- `modelID`.
- `embedding`.
- `durationSeconds`.
- `sampleRate`.
- `quality`.
- Optional `error` for recoverable failures.

The sidecar runs locally. First use may require installing Python dependencies and downloading the SpeechBrain/PyTorch model cache. If the sidecar is unavailable, the app logs the failure and falls back to local speaker labels for that meeting.

### Realtime Runtime

`RealtimeSpeakerIdentificationRuntime` is a side path from the realtime transcript flow:

1. Receive finalized or sufficiently stable transcript segments.
2. Ignore segments without a local speaker identifier.
3. Track each meeting-local speaker lane independently.
4. Accumulate evidence windows from the meeting audio stream or recording buffer.
5. Once a lane reaches the minimum usable duration, schedule exactly one embedding job for that lane.
6. Resolve the embedding against `SpeakerProfileStore`.
7. Publish a `SpeakerIdentityResolution` to the view model.
8. Allow future rechecks only when substantially more evidence is available or the earlier result was low quality.

This runtime is low priority and cancellable when the meeting stops. Stop/finalize may persist the latest profile state, but the feature does not wait until stop to identify speakers.

## Data Flow

```text
Audio frame stream
  -> existing recording / realtime transcript pipeline
  -> realtime TranscriptSegment with speakerID
  -> RealtimeSpeakerIdentificationRuntime observes speaker lane
  -> audio evidence window is clipped for that speaker
  -> SidecarSpeakerEmbeddingProvider generates embedding
  -> SpeakerIdentityResolver compares with SpeakerProfileStore
  -> SpeakerIdentityResolution published
  -> MeetingAgentViewModel updates speakerIdentityMap
  -> Live captions render stable speaker display label
```

The identity map is display-only:

```text
provider speakerID: deepgram-speaker-2
profile id: 51A2...
display label: Allan
confidence: 0.86
decision: matched
```

Translation units and caption turns continue to use provider speaker ids and exact `sourceSegmentIDs`.

## Matching Policy

The first implementation uses cosine similarity:

- `autoMatchThreshold`: high-confidence profile match.
- `reviewThreshold`: ambiguous possible match, needs confirmation.
- Below `reviewThreshold`: create a new anonymous profile.

Profiles may hold multiple embeddings. A candidate score is the maximum or weighted average of recent high-quality embeddings for a profile. The resolver records the winning score, second-best score, and score margin so future UI can explain ambiguous matches.

Anonymous profiles use stable generated names such as `Speaker 4`. If the user later names or confirms a profile, new meetings can show that name automatically.

## Privacy And Storage

Voice embeddings are biometric-like data. Store them locally in the app support profile store, not in per-meeting export directories. The design should make later deletion straightforward by keeping all long-term speaker profiles in one store.

No voice embedding API calls are made to a cloud provider. SpeechBrain model files may be downloaded by the local Python environment during setup or first run.

## Error Handling

Speaker identification failures must not affect recording, transcription, caption display, translation, summaries, or exports.

Recoverable failures include:

- Sidecar executable missing.
- Python dependency missing.
- Model download unavailable.
- Not enough clean audio for a speaker.
- Embedding output malformed.
- Profile store read/write failure.

Failures are logged with enough metadata to diagnose the issue. The visible fallback is the existing local speaker label.

## Testing

Unit tests cover:

- Cosine similarity and threshold decisions.
- Matching a candidate to an existing profile.
- Creating an anonymous profile when no match is strong enough.
- Preserving raw transcript speaker ids while applying display labels.
- Parsing successful and failed sidecar JSON output.
- Runtime scheduling rules: first new speaker triggers work, duplicate work is coalesced, and low-quality evidence can retry later.

The regular `make test` path should not require downloading SpeechBrain or PyTorch. Tests use deterministic fake embedding providers. A separate integration verification can exercise the real Python sidecar on local fixture audio when dependencies are installed.

## Implementation Notes

The implementation should favor small testable Swift types before UI work. The first UI connection can be a display label map in `MeetingAgentViewModel` consumed by existing caption row rendering. A richer confirmation UI can be added after the realtime identity path is stable.

Because realtime translation requires exact caption turn projection, this feature must not alter `sourceSegmentIDs`, translation result persistence, or translation lane construction.
