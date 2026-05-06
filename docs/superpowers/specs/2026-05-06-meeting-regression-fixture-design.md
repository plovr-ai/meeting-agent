# Meeting Regression Fixture Replay Design

## Context

The app needs a repeatable regression path that proves recorded meeting data still renders the correct visible source captions and translated text after code changes. Provider calls, persisted translation records, and performance events are not enough by themselves. The regression must validate the full projection from transcript segments to visible caption turns and from stable translation results to those exact turns.

The first fixture will use the latest local meeting:

```text
/Users/allan/Library/Application Support/MeetingAgent/Meetings/D5C47AEC-4E86-4C66-9B61-FEE3D151006C
```

This meeting is approved for repository use and is not sensitive. It should be classified as the first scenario:

```text
single-speaker-long-no-speech-final
```

It covers one speaker, long source content, long caption chunking, and final transcript segments where `speechFinal` is false. Later fixtures should add multi-speaker, speaker-change, short-turn, interruption, mixed-language, and explicit `speechFinal` cases.

The current latest meeting is not a golden pass fixture yet. Running the E2E analyzer against it currently fails with delayed first live translation, low stable coverage, projection mismatch events, and persisted translation projection mismatches. It should initially be committed as a known-failure fixture so future work can fix the pipeline against a real recorded case.

## Goals

- Store real meeting artifacts in a fixture directory that can be committed and used offline.
- Provide a reusable capture script for turning any local meeting directory into a regression fixture.
- Replay transcript and translation data without calling hosted STT or translation providers in unit tests.
- Assert the visible UI text through `LiveCaptionDisplayState`, not only through performance events.
- Validate exact `sourceSegmentIDs` projection from stable translation results to visible caption turns.
- Allow known-failure fixtures to be checked in before the underlying bug is fixed.
- Make it easy to promote a known-failure fixture to a golden fixture after the pipeline is corrected.

## Non-Goals

- Do not run real STT or real translation providers in CI.
- Do not make screenshot or pixel tests the primary correctness gate.
- Do not require every future fixture to include audio if the scenario is synthetic. Real recorded fixtures should include audio when available.
- Do not replace `scripts/analyze-meeting-performance.swift`; extend the test harness around it.

## Fixture Layout

Create a new fixture root:

```text
Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings/
  microsoft-teams-public-preview-en-zh/
    manifest.json
    audio.wav
    metadata.json
    diagnostics.json
    transcript-events.jsonl
    transcript.json
    translation-results.jsonl
    performance-events.jsonl
    expected-ui.json
```

The fixture should preserve the meeting artifacts closely enough that the existing analyzer can run directly against the fixture directory.

`audio.wav` is provenance and a future manual/provider-regeneration input. CI replay tests should not depend on rerunning STT from audio.

## Manifest

`manifest.json` declares the scenario and expected status:

```json
{
  "id": "microsoft-teams-public-preview-en-zh",
  "sourceMeetingID": "D5C47AEC-4E86-4C66-9B61-FEE3D151006C",
  "scenario": "single-speaker-long-no-speech-final",
  "sourceLocale": "en-US",
  "targetLocale": "zh-CN",
  "purpose": "knownFailure",
  "expectedAnalyzerStatus": "fail",
  "expectedFailures": [
    "first live translation exceeded latency budget",
    "stable translations did not cover realtime final caption turns",
    "stable translation projection mismatched visible caption turns",
    "persisted translations do not match visible caption turn boundaries"
  ],
  "notes": [
    "Single speaker.",
    "Long content.",
    "Final transcript segments have speechFinal=false.",
    "Initial fixture captures the current projection failure mode."
  ]
}
```

After the pipeline is fixed, update the manifest:

```json
{
  "purpose": "golden",
  "expectedAnalyzerStatus": "pass",
  "expectedFailures": []
}
```

## Expected UI Contract

`expected-ui.json` is the primary visible correctness contract. It should describe expected rendered text by display mode and `sourceSegmentIDs`.

Example shape:

```json
{
  "displayModes": {
    "both": [
      {
        "sourceSegmentIDs": [
          "deepgram-transcribe-stream-0.0",
          "deepgram-transcribe-stream-9.79"
        ],
        "primaryText": "Microsoft Teams public preview page translated into Chinese...",
        "sourceText": "Microsoft Teams public preview page, and I'll drop the link in the description...",
        "isFinal": true,
        "translationState": "final"
      }
    ],
    "translationOnly": [
      {
        "sourceSegmentIDs": [
          "deepgram-transcribe-stream-0.0",
          "deepgram-transcribe-stream-9.79"
        ],
        "primaryText": "Microsoft Teams public preview page translated into Chinese..."
      }
    ]
  }
}
```

The exact text should be generated from current fixture artifacts, then reviewed when a known-failure fixture is promoted to golden. The test must compare exact visible strings for golden fixtures. Known-failure fixtures may assert failure diagnostics first and can carry provisional expected UI data for later promotion.

## Test Layer 1: Analyzer Gate

Add `MeetingRegressionFixtureAnalyzerTests`.

For each fixture under `Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings`, read `manifest.json` and run:

```sh
swift scripts/analyze-meeting-performance.swift --assert-translation-e2e <fixture-dir>
```

Behavior:

- If `expectedAnalyzerStatus == "pass"`, the command must exit 0.
- If `expectedAnalyzerStatus == "fail"`, the command must exit nonzero and stdout must contain every configured `expectedFailures` item.
- The test should print the fixture ID in failure messages so it is clear which scenario regressed.

This allows the current latest meeting to enter the suite immediately as a known-failure fixture without pretending the behavior is correct.

## Test Layer 2: UI Projection Replay Gate

Add `MeetingRegressionUIProjectionTests`.

The replay gate should run fully offline:

```text
transcript-events.jsonl or transcript.json
  -> TranscriptDocument updates
  -> RegressionFixtureTranslationProvider
  -> TranslationRuntimeActor
  -> LiveCaptionPipeline.attachTranslationResults
  -> LiveCaptionDisplayState
  -> expected-ui.json
```

Assertions for golden fixtures:

- Final visible turns match the expected `sourceSegmentIDs` exactly.
- `LiveCaptionDisplayMode.both` renders translated text as primary text and source text as secondary text.
- `LiveCaptionDisplayMode.translationOnly` renders translated text as the only visible text.
- Missing translation renders pending state and does not reuse stale or unrelated translation text.
- Stable final translation only attaches when the result `sourceSegmentIDs` exactly match a visible turn.
- Partial-overlap stable results are rejected and produce a projection mismatch diagnostic.

The first latest-meeting fixture can initially assert the known projection failure rather than exact final UI correctness. After the pipeline fix, the same test data becomes the golden proof.

## Fixture Translation Provider

Add a test-only provider:

```swift
final class RegressionFixtureTranslationProvider: TextTranslationProvider
```

It should load `translation-results.jsonl` and index translations by:

```text
canonical(sourceSegmentIDs) -> translatedText
sourceTextHash -> translatedText
```

Lookup order:

1. Exact canonical `sourceSegmentIDs` match.
2. Exact `sourceTextHash` match.
3. Failure with a clear fixture-miss error.

The exact `sourceSegmentIDs` lookup is intentional. If the runtime builds a translation unit whose boundary no longer matches the fixture, the test should fail instead of silently translating the wrong unit.

## Capture Script

Add:

```text
scripts/capture-regression-fixture.swift
```

Command:

```sh
swift scripts/capture-regression-fixture.swift \
  --meeting "$HOME/Library/Application Support/MeetingAgent/Meetings/<MEETING_ID>" \
  --name microsoft-teams-public-preview-en-zh \
  --scenario single-speaker-long-no-speech-final \
  --output Tests/MeetingAgentCoreTests/Fixtures/RegressionMeetings
```

Responsibilities:

- Validate required artifacts exist.
- Copy `audio.wav`, `metadata.json`, `diagnostics.json`, `transcript-events.jsonl`, `transcript.json`, `translation-results.jsonl`, and `performance-events.jsonl`.
- Generate `manifest.json`.
- Generate an initial `expected-ui.json` from `transcript.json` and `translation-results.jsonl`.
- Run the analyzer and set `expectedAnalyzerStatus` to `pass` or `fail`.
- Include analyzer failure messages in `expectedFailures` when the fixture is known-failure.
- Print a short review summary listing the scenario, segment count, stable translation record count, and analyzer status.

The script should not mutate the source meeting directory.

## First Fixture

Use:

```text
D5C47AEC-4E86-4C66-9B61-FEE3D151006C
```

Scenario:

```text
single-speaker-long-no-speech-final
```

Initial status:

```text
knownFailure
```

Why this fixture matters:

- It is a real recorded meeting with audio.
- It has one speaker, which isolates boundary problems from speaker diarization problems.
- It has long source content, which stresses caption chunking and stable unit boundaries.
- Its final transcript segments have `speechFinal=false`, which covers the manual-stop/finalization path.
- It currently reproduces the stable translation projection failures that the regression framework must catch.

## Future Fixture Matrix

After the first fixture, add scenarios incrementally:

- `multi-speaker-speaker-change`: stable translations must not cross speaker boundaries incorrectly.
- `short-turns-with-speech-final`: short final utterances with explicit provider final boundaries.
- `mixed-language-same-language-skip`: same-language skip must not hide expected source captions.
- `interruption-overlap`: rapid alternation and partial drafts must not attach stale translations.
- `translation-provider-failure`: visible captions continue and UI shows failed translation state.
- `post-stop-late-result`: translation results arriving after stop are dropped and not displayed.

## Acceptance Criteria

- The first latest-meeting fixture is committed under `RegressionMeetings`.
- `make test` runs analyzer fixture tests and UI projection replay tests.
- Known-failure fixtures assert the expected failure messages.
- Golden fixtures assert exact UI display state output.
- The latest meeting can later be promoted from known-failure to golden by changing the manifest and expected UI after the projection bug is fixed.
- New real recorded meetings can be added with one capture script command.

## Implementation Notes

- Keep all replay helpers in the test target unless a reusable parsing type clearly belongs in core.
- Prefer structured decoding of JSON and JSONL over ad hoc string parsing.
- Keep fixture provider behavior deterministic and fail closed on missing translations.
- Do not weaken `scripts/analyze-meeting-performance.swift --assert-translation-e2e`; tests should adapt to the analyzer contract, not bypass it.
- Keep generated fixture files small enough for normal repository operations. If future audio fixtures become large, decide separately whether to trim audio or move audio storage out of git.
