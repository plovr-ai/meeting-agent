# Original Caption Segmentation Design

## Context

Issue #135 is a bug report for original transcript and live caption segmentation. The latest analyzed meeting, `ACC15B94-1199-4DD9-9ED4-229BED75A8F5`, still shows repeated adjacent text in the persisted transcript:

```text
to be able to take to be able to take advantage of these public preview features
```

The meeting had 69 Deepgram raw responses, 12 final transcript segments, 2 interim segments, and no `speechFinal=true` responses. Deepgram `is_final=true` is therefore providing stable word chunks, not user-facing utterance boundaries.

This design only affects new recording and realtime write paths. It does not migrate or repair existing meeting artifacts when historical meetings are opened.

## Goals

- Keep Deepgram provider finality and user-facing segmentation separate.
- Prevent new persisted transcripts from containing adjacent duplicated phrases caused by overlapping provider chunks.
- Prevent live captions from duplicating suffix/prefix text while merging stable chunks.
- Treat `speechFinal=true` as a hard boundary and `speechFinal=false` as stable input that may continue an open caption.
- Treat only terminal sentence punctuation as a soft sentence boundary.
- Preserve stop-recording/manual flush behavior so open caption text is emitted.

## Non-Goals

- Do not change Deepgram request parameters or endpointing configuration.
- Do not change `DeepgramStreamingResponseMapper`'s `isFinal` mapping.
- Do not tune translation providers or translation scheduling as a primary objective.
- Do not add historical transcript migration or display-time repair for existing meetings.
- Do not change SwiftUI layout or visible controls.

## Selected Approach

Use the canonical transcript accumulator as the source cleanup layer, and keep the live caption chunker focused on user-facing display boundaries.

`TranscriptSegmentAccumulator` will normalize newly upserted transcript segments before they are persisted. `LiveCaptionChunker` will consume the cleaned stable text and apply display boundary rules. This keeps `transcript.json`, `transcript.txt`, exports, summaries, and live captions aligned for new recordings without changing historical artifacts.

## Architecture

### Canonical Transcript Cleanup

`TranscriptSegmentAccumulator` remains the owner of canonical streaming transcript state. After each `.upsert(segment)`, it will apply overlap cleanup to the in-memory document before returning the result.

The cleanup applies only to compatible adjacent or overlapping segments:

- same `sourceProvider`
- compatible speakers using the existing speaker compatibility rule
- nearby or overlapping timing when timing is available
- token-level suffix/prefix overlap of at least two tokens

The token comparison ignores case and punctuation, while text rewriting preserves the incoming segment's original casing and punctuation outside the removed overlap.

For final-to-final overlap, the accumulator trims the repeated prefix from the later final segment. If the later segment becomes empty, it is removed.

For final-to-interim-to-final overlap, the accumulator trims interim text already covered by the preceding final and the following final. If the interim becomes empty, it is removed. This specifically covers the issue shape where an interim segment bridges two final chunks and leaves duplicated text in `transcript.txt`.

Existing final-to-interim coverage pruning remains in place.

### Live Caption Display Segmentation

`LiveCaptionChunker` continues to ignore non-final segments and append only stable `segment.isFinal == true` segments to the open display chunk.

When appending a same-speaker final segment to an open chunk, it will join with suffix/prefix overlap removal. This avoids a transient live caption duplicate even when the canonical document has not yet been rewritten through a later accumulator pass.

Boundary handling:

- `speechFinal=true` hard-seals the open chunk with `.speechFinal`.
- speaker change hard-seals the previous open chunk with `.speakerChanged`.
- terminal punctuation may create a soft `.punctuation` boundary when configured length thresholds are met.
- max readable length and max hard length remain as safety boundaries.
- max duration may create a soft boundary only when terminal punctuation is present.
- manual stop flush seals the current open chunk with the provided reason.

Terminal punctuation means the trimmed text ends with one of:

```text
. ? ! 。 ？ ！
```

Inline punctuation no longer counts as a sentence boundary.

## Data Flow

1. Deepgram streaming response maps to `TranscriptSegment`.
2. `DeepgramStreamingTranscriber` writes the segment through `TranscriptFileWriter.upsert` and emits `.upsert` into the realtime transcript sink.
3. `TranscriptSegmentAccumulator` normalizes the canonical document during upsert.
4. `TranscriptFileWriter` renders the cleaned canonical document to `transcript.json` and `transcript.txt`.
5. Active recording view-model state receives realtime transcript updates and feeds stable final segments into `CaptionTurnAssembler`.
6. `CaptionTurnAssembler` passes final segments to `LiveCaptionChunker`.
7. `LiveCaptionChunker` overlap-joins same-speaker stable chunks and seals only on hard or conservative soft boundaries.

## Tests

Add focused tests before implementation:

- `TranscriptSegmentAccumulatorTests.testUpsertDeduplicatesAdjacentFinalSegmentOverlap`
- `TranscriptSegmentAccumulatorTests.testUpsertTrimsInterimCoveredBySurroundingFinalSegments`
- `TranscriptSegmentAccumulatorTests.testIssue135MeetingShapeDoesNotRepeatAbleToTake`
- `LiveCaptionChunkerTests.testJoiningAdjacentFinalChunksRemovesSuffixPrefixOverlap`
- `LiveCaptionChunkerTests.testInlineSentencePunctuationDoesNotCreateBoundary`
- `CaptionTurnAssemblerTests` coverage that `speechFinal=false` final chunks keep merging and `speechFinal=true` still hard-seals

Adjust the existing long Deepgram chunk test that expects inline sentence punctuation to seal. The new behavior is terminal-punctuation-only.

Add a `TranscriptFileWriterTests` regression only if accumulator coverage does not prove the rendered text path.

## Verification

Run SwiftPM verification serially in the issue worktree:

```sh
swift test --filter TranscriptSegmentAccumulatorTests
swift test --filter LiveCaptionChunkerTests
swift test --filter CaptionTurnAssemblerTests
swift test --filter TranscriptFileWriterTests
make test
```

## Risks And Controls

- Real repeated words may be over-trimmed. Control: trim only cross-segment suffix/prefix overlap with at least two matching tokens; never remove repetition inside one segment.
- Speaker drift may cause incorrect joins. Control: reuse existing speaker compatibility and avoid cleanup when speaker identifiers conflict.
- Coverage may be affected by small helper closures. Control: prefer explicit helper branches over compact fallback closures in coverage-enforced core code.
- Existing inline punctuation behavior conflicts with the issue acceptance criteria. Control: update the old test to the new terminal punctuation rule instead of supporting both semantics.

## Acceptance Criteria

- New Deepgram final chunks with `speechFinal=false` do not by themselves hard-seal user-facing subtitle segments.
- New adjacent final chunks with repeated suffix/prefix text persist without duplicated words.
- New final/interim/final bridge shapes do not leave repeated phrases in `transcript.txt`.
- Inline punctuation does not trigger `.punctuation` freeze.
- Terminal `.`, `?`, `!`, `。`, `？`, or `！` can trigger `.punctuation` freeze when thresholds are met.
- Stop-recording/manual flush still emits open caption text.
- Existing `speechFinal=true` behavior continues to create a hard boundary.
