# Readable Caption Boundaries Design

## Context

Issue #122 asks for bilingual subtitle chunks that read naturally instead of mirroring raw ASR segment boundaries. The current caption assembly path already exposes boundary reason and strength through `LiveCaptionTurn`, and the core chunking behavior lives in `LiveCaptionChunker` with `CaptionTurnAssembler` adapting final provider segments into chunk updates.

## Goals

- Merge same-speaker short fragments into a readable caption turn when timing is close.
- Always start a new turn on speaker change and mark the previous turn as a hard boundary.
- Treat sentence-ending punctuation as a natural soft boundary once the caption is readable.
- Freeze very long turns before they become hard to read.
- Preserve provider speech-final boundaries as hard final boundaries.
- Keep boundary reason and strength visible in the emitted `LiveCaptionTurn` values and covered by unit tests.

## Non-Goals

- No UI redesign for subtitle rendering.
- No provider-specific parsing beyond existing `TranscriptSegment` fields.
- No change to translation scheduling semantics except the boundary metadata already consumed by existing code.

## Selected Approach

Enhance `LiveCaptionChunkingPolicy` and `LiveCaptionChunker` directly. The existing chunker already owns open-caption state, speaker-change detection, timing windows, punctuation checks, and freeze reasons, so the smallest reliable change is to make those heuristics more expressive there.

The chunker will keep hard boundaries for speaker changes and provider `speechFinal` segments. It will treat sentence-ending punctuation as a soft boundary when the caption has reached a readable minimum length, including provider chunks that contain a complete sentence followed by more same-speaker text. It will continue merging short same-speaker fragments while their timing gap is close and the combined text remains below the readable length limit. Long captions will freeze with `.maxLength`, preserving existing boundary observability.

## Policy Shape

`LiveCaptionChunkingPolicy` will retain existing fields for compatibility and add narrowly scoped controls:

- `readableCharacterLimit`: preferred upper bound for a readable turn before soft length freezing.
- `shortFragmentCharacters`: threshold under which a same-speaker fragment should prefer merging.
- `maxMergeGapSeconds`: maximum timing gap for short-fragment merging when both segment timings are available.
- `minSentenceBoundaryCharacters`: minimum length before terminal punctuation can seal a turn.

The existing `maxCharacters`, `maxDurationSeconds`, and `minPunctuationCharacters` fields remain available. `maxCharacters` stays as the hard safety cap, while readable limits guide softer UX boundaries.

## Boundary Rules

1. If the next final segment has a different speaker, freeze the current open chunk with `.speakerChanged` and `.hard`.
2. Append or replace the same segment ID as today so interim-to-final replacement remains stable.
3. If the latest segment is `speechFinal`, freeze the merged turn with `.speechFinal` and `.hard`.
4. If the merged turn reaches `maxCharacters`, freeze with `.maxLength`.
5. If the merged turn exceeds the readable character limit, freeze with `.maxLength` after emitting the draft update.
6. If the merged turn contains sentence-ending punctuation and meets the sentence-boundary minimum, freeze with `.punctuation` and `.soft`.
7. If duration exceeds `maxDurationSeconds` and the turn has terminal sentence punctuation, freeze with `.maxDuration`.
8. Otherwise keep the turn open so nearby same-speaker fragments can merge.

## Testing

Unit tests will cover:

- Same-speaker short fragments merge into one readable turn.
- Speaker change always seals the previous turn with `.speakerChanged` and `.hard`.
- Terminal sentence punctuation seals with `.punctuation` and `.soft`.
- Punctuation inside the middle of text does not prematurely seal.
- Very long turns freeze with `.maxLength` before becoming unreadable.
- Provider `speechFinal` stays `.speechFinal` and `.hard`.

Verification commands:

- `swift test --filter LiveCaptionChunkerTests`
- `swift test --filter CaptionTurnAssemblerTests`
- `make test`
