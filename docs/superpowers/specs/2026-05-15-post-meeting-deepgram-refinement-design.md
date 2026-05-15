# Post-Meeting Deepgram Transcript Refinement Design

## Context

Issue #156 adds a post-meeting transcript refinement path. Realtime captions must stay low-latency and caption-only, but completed meetings with a saved `audio.wav` should be able to run a higher-accuracy batch STT pass with diarization. The refined transcript becomes the in-memory and persisted `CaptionDocument` source for summary, export, and knowledge flows.

Issue #155 is independently adding current-user speaker attribution (`Me`). This design keeps #156 focused on anonymous provider diarization (`Speaker 1`, `Speaker 2`) and preserves speaker metadata without hard-coding `Me` semantics.

## User Intent

After a recording stops, MeetingAgent should improve the transcript using the complete WAV recording and Deepgram batch diarization. If refinement cannot run or produces no usable turns, the live transcript remains the source of truth.

## Requirements

- Add a batch transcription provider setting for post-meeting refinement.
- For this milestone, support only Deepgram batch refinement.
- Use the configured meeting language for batch requests.
- Use Deepgram prerecorded transcription with diarization and utterances.
- Project successful batch output to `CaptionDocument` / `CaptionTurn`.
- Preserve speaker metadata as stable anonymous speaker IDs and labels.
- Update `MeetingSessionState.transcript` and persist `transcript.json` only on success.
- Preserve live transcript on missing audio, provider failure, or empty batch output.
- Record provider, model, status, failure reason, and duration on `MeetingRecord`.
- Keep realtime caption and translation architecture unchanged.

## Non-Requirements

- Do not implement local Whisper diarization.
- Do not implement speaker enrollment or `Me` recognition.
- Do not introduce realtime translation or caption translation events.
- Do not delete existing summary or transcript assets.

## Model And Provider

The refinement provider is Deepgram prerecorded STT. The default model is `nova-3`.

Requests use:

- `model=<configured batch model>`
- `language=<meeting speechLocaleIdentifier>`
- `diarize=true`
- `utterances=true`
- `smart_format=true`
- `punctuate=true`

The API key uses the existing Deepgram credential field, with environment fallback to `MEETING_AGENT_DEEPGRAM_API_KEY`.

## Settings Design

Add post-meeting batch settings to the Settings screen:

- Batch Transcript Provider: Deepgram
- Batch Transcript Model: Deepgram Nova 3, Deepgram Nova 2

The configuration model stores:

- `batchTranscriptionProviderID`, default `deepgram-batch-transcribe`
- `batchTranscriptionModelID`, default `nova-3`

The UI only exposes Deepgram for now, but the separate fields keep realtime transcription and post-meeting refinement decoupled.

## Architecture

Add `PostMeetingTranscriptRefinementService` in `MeetingAgentCore`.

Inputs:

- `MeetingRecord`
- current live `CaptionDocument`
- `SpeechTranscriptionConfiguration`

Dependencies:

- `DeepgramBatchTranscriptRefinementProvider`
- `TranscriptRepository`
- `MeetingStore`
- clock closure for deterministic duration tests

Flow:

1. Stop recording and flush live caption persistence.
2. If `record.audioURL` is missing or not readable, mark refinement failed/skipped and keep live transcript.
3. Run Deepgram batch transcription.
4. Convert returned diarized transcript segments into a `CaptionDocument`.
5. If no final text turns exist, mark failed and keep live transcript.
6. Save refined document to `transcript.json`.
7. Update selected in-memory `MeetingSessionState.transcript` to the refined document.
8. Save `MeetingRecord` with refinement metadata.

## Data Mapping

Each batch `TranscriptSegment` becomes one final `CaptionTurn`:

- `speakerID`: provider speaker ID, for example `deepgram-speaker-0`
- `speakerLabel`: existing label or generated `Speaker 1`
- `startTimeSeconds` / `endTimeSeconds`: provider timings
- `source.providerID`: `deepgram-batch-transcribe`
- `source.resultIDs` and section `utteranceIDs`: segment ID
- `provider`: `CaptionProviderInfo(id: "deepgram-batch-transcribe", model: configuredModel, locale: meetingLocale)`

Speaker labels are generated consistently by first appearance order.

## Error Handling

Failures never overwrite a usable live transcript.

Failure states include:

- missing audio URL
- audio file missing or unreadable
- Deepgram request failure
- batch result contains no usable final turns
- persistence failure

The meeting record stores the failure reason and duration. The existing live `CaptionDocument` remains in memory and on disk.

## Testing

Focused tests cover:

- settings persistence for batch provider/model
- SettingsView source guard for batch provider controls
- Deepgram batch request URL includes diarization, utterances, smart formatting, punctuation, model, and language
- successful refinement writes refined speaker-separated caption document and updates in-memory state
- failed refinement preserves live transcript
- missing audio preserves live transcript and records failure
- empty batch result preserves live transcript and records failure

Full verification remains `make test`.
