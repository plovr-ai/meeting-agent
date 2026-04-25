# Speaker-Labeled Transcript Design

## Goal

Standardize transcript output so every STT provider writes speaker-labeled text in a common format:

```text
User A:
hello
continued speech from the same speaker

User B:
thanks
```

The first implementation focuses on provider-neutral formatting and data flow. It does not add true speaker diarization yet. Providers that cannot identify speakers will emit a default speaker, rendered as `User A`.

## Scope

- Add a provider-neutral transcript segment model in `MeetingAgentCore`.
- Render transcript files through one shared formatter that groups consecutive segments from the same speaker into speaker turns.
- Map stable speaker identifiers to display labels `User A`, `User B`, `User C`, and so on.
- Keep existing STT providers working:
  - `WhisperSpeechTranscriptionProvider` appends each non-empty chunk as a segment.
  - `LocalSpeechTranscriptionProvider` replaces the current partial transcript as a single segment.
- Preserve current error behavior: if transcription setup or runtime processing fails, the transcript file contains the failure reason.

Out of scope:

- Voice embedding, clustering, or model-backed speaker diarization.
- Binding the transcript file format to `whisper.cpp`, macOS Speech, or any single provider.
- UI redesign beyond displaying the standardized transcript text already read from `transcript.txt`.

## Architecture

Introduce small transcript-domain types in core:

- `TranscriptSpeaker`: stores an optional provider-neutral speaker identifier.
- `TranscriptSegment`: stores a speaker and text.
- `TranscriptFormatter`: renders segments into the public text file format.
- `SpeakerLabelMapper`: assigns stable display letters during one transcript render.

The file format is produced only by `TranscriptFormatter`. Providers do not construct strings like `User A:` directly. They pass text, and optionally a speaker identifier, into the shared transcript layer.

`TranscriptSegment` represents raw STT output, not the final display paragraph. A provider may emit many short segments for one speaker because the recognizer runs in chunks. `TranscriptFormatter` groups consecutive segments with the same speaker into an internal speaker turn and emits the speaker label once per turn.

The rendered format for one turn is:

```text
User A:
first recognized segment
second recognized segment
```

When the speaker changes, the formatter starts a new turn and separates turns with a blank line:

```text
User A:
first speaker text

User B:
second speaker text
```

For the initial implementation, both existing providers will use a default speaker when they have no speaker metadata. This keeps output consistent while leaving a clear seam for later diarization work to supply different speaker identifiers.

## Data Flow

Whisper:

1. Audio frames accumulate into a chunk.
2. The chunk is sent to `whisper.cpp`.
3. Empty lines and `[BLANK_AUDIO]` are filtered as today.
4. Each non-empty chunk becomes `TranscriptSegment(speaker: .default, text: chunkText)`.
5. The complete segment list is rendered as speaker turns and replaces the transcript file.

macOS Speech:

1. Audio frames are appended to `SFSpeechAudioBufferRecognitionRequest`.
2. Partial and final results update one current transcript segment.
3. The file is rewritten as one default-speaker turn.

Future diarization:

1. A diarization component, provider, or upstream STT result supplies stable speaker identifiers.
2. The existing formatter maps those identifiers to `User A`, `User B`, and later labels without changing app or CLI display code.

## Error Handling

Transcription failures continue to write plain failure messages without a `User A:` prefix. This keeps operational errors easy to distinguish from recognized speech.

If segment text is blank after trimming, the formatter omits it. If no segments remain, the rendered transcript is empty.

## Testing

Add focused XCTest coverage for:

- Default segments render as a single `User A` turn.
- Consecutive segments from the same speaker render under one label.
- Distinct speaker identifiers map stably to `User A`, `User B`, and reuse prior labels when speakers take another turn.
- Blank segment text is omitted.
- Whisper chunk transcripts are written in standardized turn format.
- Whisper blank audio filtering still omits `[BLANK_AUDIO]`.
- Local Speech transcript updates use the shared formatter where practical through testable formatting units.

## Compatibility

Existing transcript files remain readable because the app and CLI already treat them as plain UTF-8 text. New recordings will use the speaker-labeled format. No migration is needed for historical files.
