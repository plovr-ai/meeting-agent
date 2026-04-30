# Stable Prefix Caption Rendering Design

## Context

Deepgram interim transcription can revise text repeatedly before a final segment arrives. `CaptionTurnAssembler` already owns the boundary between provider transcript segments and live caption turns, so it is the right place to attach display-only stability metadata without changing persisted transcript source data.

Issue #121 asks for stable-prefix rendering that keeps already-stable caption text visually anchored while allowing the unstable tail to change during interim updates.

## Goals

- Preserve `LiveCaptionTurn.originalText` as the complete provider text for every draft and final caption.
- Track the stable prefix and unstable tail for repeated interim updates to the same open caption turn.
- Let the UI render stable and unstable text differently later without changing transcript persistence.
- Clear or freeze display-only unstable state when a final caption or hard boundary arrives.
- Cover same-turn interim growth, interim correction, final promotion, and speaker or boundary reset behavior with unit tests.

## Non-Goals

- Do not split one provider interim into multiple persisted transcript segments.
- Do not change source transcript persistence or exported transcript text.
- Do not add a new user setting for caption stability in this issue.
- Do not redesign the transcript UI beyond exposing enough model state for future styling.

## Selected Approach

Add display-only stable-prefix metadata to `LiveCaptionTurn`, then compute that metadata in `CaptionTurnAssembler` when the same open interim segment receives a new draft update.

`originalText` remains the source of truth for the full caption text. New optional fields describe how the full text should be interpreted for display:

- `stableOriginalTextPrefix`: the text prefix that is unchanged across successive interim updates.
- `unstableOriginalTextTail`: the current remaining text after that stable prefix.

For first-time interim segments, the stable prefix is empty and the unstable tail is the full interim text. For repeated updates to the same segment and speaker, the assembler computes a word-boundary-safe shared prefix between the previous and current interim text. For final captions, both display-only fields are normalized so the final visible caption remains identical to the provider final text and is not treated as a mutable draft tail.

## Alternatives Considered

### UI-only text diffing

This keeps model changes smaller but puts speaker, segment, and boundary semantics in SwiftUI. The view does not have enough context to know when a stable prefix should reset.

### Split stable and unstable text into separate caption turns

This could make styling simple, but it would pollute transcript and translation semantics. It risks changing persistence, exports, same-speaker grouping, and translation scheduling for a display-only concern.

### Assembler-owned display metadata

This keeps provider text intact while making the display stability state testable at the pipeline boundary. It matches the existing `CaptionTurnAssembler` responsibility and the issue proposal.

## Data Flow

1. The ASR provider emits an interim `TranscriptSegment`.
2. `CaptionTurnAssembler.apply(_:)` creates or updates an open draft turn.
3. On same-segment draft updates, the assembler compares the previous draft text and current segment text.
4. The shared word-boundary prefix becomes `stableOriginalTextPrefix`; the remaining current text becomes `unstableOriginalTextTail`.
5. Final segments clear the matching open draft and flow through `LiveCaptionChunker`, preserving final provider text.
6. `LiveCaptionStore` stores and updates the display metadata with the turn, but transcript persistence continues to use transcript segments and `originalText`.

## Edge Cases

- If the provider corrects an early word, only the prefix before the correction remains stable.
- If the speaker changes for the same segment ID, stability resets because the display turn semantics changed.
- If a final or hard boundary arrives, the final turn is sealed with provider final text and no mutable unstable tail.
- Legacy decoded caption JSON should continue to work with empty stability metadata.
- Same-speaker merge paths must not invent stable prefix metadata across separate source segments.

## Test Plan

- Add `CaptionTurnAssemblerTests` coverage for interim growth where `"We should"` becomes `"We should decide"` and the shared prefix remains stable.
- Add interim correction coverage where `"We should decide"` becomes `"We might decide"` and only `"We "` remains stable.
- Add final promotion coverage showing final text equals provider final text and unstable tail is cleared.
- Add speaker reset coverage showing same segment ID with a new speaker does not inherit prior stability.
- Run focused tests, then `make test` to satisfy the coverage gate.
