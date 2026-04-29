## [4] Clear stale structured transcript data on plain-text fallback

**Date**: 2026-04-25
**Category**: logic-error

### What went wrong
Introducing `transcript.json` as the preferred source of truth initially left old structured segments in place when a failure path wrote plain text to `transcript.txt`.

### Correct approach
Plain-text fallback writes must clear the structured transcript document so readers do not prefer stale JSON over the current fallback message.

### How to avoid
When adding a new source-of-truth file beside a legacy cache or fallback, update or invalidate both paths in every write mode.

---

## [5] STT settings persistence test isolation

**Date**: 2026-04-25
**Category**: test-mistake

### What went wrong
The first persisted STT settings implementation used the default `UserDefaults` store in view-model tests, which allowed one test's settings to affect another test.

### Correct approach
Inject a suite-scoped `UserDefaults` through `SpeechTranscriptionConfigurationStore` in tests that read or write persisted settings.

### How to avoid
Never use process-global persistence directly in unit tests; inject an isolated store.

---

## [14] Apply patches in the active issue worktree

**Date**: 2026-04-25
**Category**: wrong-assumption

### What went wrong
The first regression test patch was applied from the original checkout after creating the issue worktree, so verification in the worktree did not compile or run the new test.

### Correct approach
Use absolute paths or verify `git status --short` in the issue worktree immediately after every patch when working outside the original checkout.

### How to avoid
After creating a worktree, apply patches with the worktree path and confirm the changed files are visible there before running tests.

---

## [7] Applying patches from a linked worktree

**Date**: 2026-04-25
**Category**: convention-violation

### What went wrong
The first design-document patch used relative paths while the active task was in a linked issue worktree, so the files landed in the original checkout before being moved.

### Correct approach
When editing a linked worktree with `apply_patch`, use absolute paths or otherwise verify the patch target is the issue worktree before writing files.

### How to avoid
For worktree-based issue fixes, patch absolute paths under the issue worktree.

---

## [15] Parallel SwiftPM commands in one worktree

**Date**: 2026-04-25
**Category**: test-mistake

### What went wrong
Focused `swift test --filter ...` commands were launched in parallel in the same worktree, causing SwiftPM to serialize on the shared `.build` directory and produce noisy waiting output.

### Correct approach
Run SwiftPM build and test commands one at a time per worktree, or use separate worktrees when true parallel SwiftPM verification is needed.

### How to avoid
Do not parallelize SwiftPM commands that share the same `.build` directory.

---

## [6] Backfill derived artifact URLs for legacy metadata

**Date**: 2026-04-25
**Category**: wrong-assumption

### What went wrong
Adding optional summary artifact URLs to `MeetingRecord` initially handled new meetings but left older decoded metadata with nil summary paths, preventing regeneration for existing completed meetings.

### Correct approach
When adding derived artifact paths to persisted metadata, assign defaults during load as well as during creation.

### How to avoid
For every optional field added for Codable compatibility, decide whether consumers need a load-time default before using it in new workflows.

---

## [20] Split mixed-responsibility files before deleting feature-specific code

**Date**: 2026-04-27
**Category**: logic-error

### What went wrong
Removing CLI-only `RecordingOutput.swift` initially also removed `TranscriptFileWriter`, which was still used by app transcription paths because both types lived in the same source file.

### Correct approach
Before deleting a feature-specific source file, inspect every type it defines and move still-shared types into accurately named files.

### How to avoid
Search references by type, not only by filename, before deleting files with mixed responsibilities.

---

## [22] Verify preserved controls after UI restyles

**Date**: 2026-04-27
**Category**: logic-error

### What went wrong
The first command-center restyle passed callbacks through the new view hierarchy but failed to render the existing Stop Recording and Retry Transcription controls.

### Correct approach
When replacing a UI shell, map every old visible control to a new visible control before treating callback preservation as complete.

### How to avoid
For UI restyles, review both callback wiring and rendered control labels against the previous screen.

---

## [27] Sync all layout guard tests after replacing UI controls

**Date**: 2026-04-28
**Category**: test-mistake

### What went wrong
The first speaker-name menu implementation updated one layout regression test but missed another test that still asserted the removed speaker edit icon. It also introduced an inline `.font(.system(...))`, violating the existing shared typography guard.

### Correct approach
When replacing a SwiftUI control, search all source-layout tests for the old control marker and use existing design-system typography instead of inline font declarations.

### How to avoid
Before full verification, search tests for every removed symbol and source files for project-wide prohibited style patterns touched by the change.

---

## [25] Avoid sorting-only tests for preferred-target behavior

**Date**: 2026-04-28
**Category**: test-mistake

### What went wrong
The first Feishu discovery regression test expected Feishu to sort before Notes, but that passed alphabetically even when Feishu was not in the preferred bundle set.

### Correct approach
Test preferred-target behavior through automatic selection or candidate detection where non-preferred active apps are filtered out.

### How to avoid
When testing priority classification, choose assertions that fail without the classification, not assertions that can pass due to unrelated ordering.

---

## [28] Preserve idempotence when merging append-only state

**Date**: 2026-04-28
**Category**: logic-error

### What went wrong
The first same-speaker live caption merge only checked the latest `sourceSegmentID`, so refreshing the same transcript document could append an earlier already-represented segment into the merged turn again.

### Correct approach
Merged display turns need to track every represented source segment ID and reject appends for segment IDs already present in that merged turn.

### How to avoid
When changing append-only state into grouped state, add an idempotent replay test that appends the same source item again after grouping.

---

## [33] Do not pass actor-isolated state inout across await

**Date**: 2026-04-28
**Category**: api-misuse

### What went wrong
The first view-model translation implementation tried to pass the main-actor-isolated live caption store as `inout` to an async adapter call, which Swift rejects because the actor-isolated property could be accessed across a suspension point.

### Correct approach
Await the provider call using local immutable inputs, then mutate the actor-isolated store after the await returns on the actor.

### How to avoid
When a helper both awaits and mutates actor-owned state, split it into an async value-producing step and a synchronous actor mutation step.

---

## [35] Update scheduler predicates when preserving visible fallback state

**Date**: 2026-04-28
**Category**: logic-error

### What went wrong
The first stable caption translation fix preserved the old translated text during same-speaker merging, but the translation scheduler still required pending turns to have empty translated text before requesting the updated full-turn translation.

### Correct approach
Use the semantic translation key and in-flight state to decide whether a pending turn needs translation; do not use visible fallback text emptiness as the scheduling gate.

### How to avoid
When preserving old UI state during async refreshes, audit every downstream predicate that previously treated empty state as the only signal for pending work.

---

## [38] Exclude bundle templates from SwiftPM source scanning

**Date**: 2026-04-28
**Category**: build-config

### What went wrong
The first app packaging pass added `Sources/MeetingAgentApp/Resources/Info.plist` under an executable target without excluding it from SwiftPM, which produced an unhandled-file warning. The packaging command also generated `dist/MeetingAgent.app` before `dist/` was ignored.

### Correct approach
Keep bundle templates in the app source tree for packaging, but add `exclude: ["Resources"]` to the SwiftPM target and ignore generated package output directories.

### How to avoid
When adding non-source packaging assets under `Sources/`, update both `Package.swift` source scanning rules and `.gitignore` in the same change.

---

## [46] Keep interim replacement IDs from collapsing later final segments

**Date**: 2026-04-28
**Category**: logic-error

### What went wrong
The first Deepgram interim upsert design used one fallback active segment ID for responses without word timings, which let an interim update become final but also caused later unrelated final responses without word timings to overwrite the previous final segment.

### Correct approach
Use a stateful fallback ID in the streaming transcriber: keep one active fallback ID through interim updates, then advance it after the final segment is written.

### How to avoid
When using upsert for streaming interim data, test both interim-to-final replacement and multiple final utterances that lack provider timing IDs.

---

## [57] Avoid public API expansion for injectable defaults

**Date**: 2026-04-28
**Category**: api-misuse

### What went wrong
The first summary provider injection made the default provider factory public only because Swift public initializer default arguments cannot reference private helpers.

### Correct approach
Use an optional injectable closure defaulting to `nil`, then assign the private default factory inside the initializer body.

### How to avoid
When adding test injection to a public initializer, keep helper factories private unless callers genuinely need them.

---

## [48] Apply preferred-target test lessons before writing new tests

**Date**: 2026-04-28
**Category**: test-mistake

### What went wrong
The first Feishu display-name sorting regression test used an ordering assertion that was too close to the existing preferred-target test mistake pattern, so manual review had to tighten it after implementation.

### Correct approach
When `MISTAKES.md` contains a relevant prior lesson, apply it before writing the new test rather than relying on review to catch the repeated pattern.

### How to avoid
Before adding tests in an area mentioned by `MISTAKES.md`, choose assertions that would fail without the intended behavior and document why.

---

## [47] Do not assume origin/HEAD is configured

**Date**: 2026-04-28
**Category**: wrong-assumption

### What went wrong
The first issue worktree command derived an empty default branch from `git symbolic-ref refs/remotes/origin/HEAD`, so it tried to create a worktree from `origin/` instead of `origin/main`.

### Correct approach
If `origin/HEAD` is absent or empty, query `git remote show origin` or fall back to the known remote default branch before creating the issue worktree.

### How to avoid
Validate the resolved default branch is non-empty before passing it to `git fetch` or `git worktree add`.

---

## [52] Do not publish capture sessions before consumers are ready

**Date**: 2026-04-28
**Category**: logic-error

### What went wrong
The first startup replay implementation focused on the Deepgram connection delay but left `captureSession` visible to the app drain loop before the WAV writer and startup spool state were ready.

### Correct approach
Start Core Audio capture first, but expose the session to drain callers only after local writing and startup transcription buffering have been initialized.

### How to avoid
When a producer starts before its consumers, test the exact window where external drain or poll loops can observe partially initialized state.

---

## [54] Keep awaited actor values out of XCTest autoclosures

**Date**: 2026-04-28
**Category**: test-mistake

### What went wrong
The first streaming raw-response logging test placed `await received.texts` directly inside `XCTAssertEqual`, which Swift rejects because XCTest assertions use non-async autoclosures.

### Correct approach
Await actor-isolated values into local constants before passing them to XCTest assertions.

### How to avoid
When asserting actor state in XCTest, split `let value = await actor.value` from `XCTAssertEqual(value, expected)`.

---

## [56] Keep internal helpers out of the public API

**Date**: 2026-04-29
**Category**: api-misuse

### What went wrong
The first silence detector implementation made the new detector public even though only `MeetingRecorder` and `@testable` unit tests needed it.

### Correct approach
Default new helper types to internal and expose them publicly only when external package callers need them.

### How to avoid
Before committing a new `public` type or member, verify it is part of the intended package API rather than only an injectable implementation detail.

---

## [43] Use detected transcript language after source setting removal

**Date**: 2026-04-29
**Category**: wrong-assumption

### What went wrong
The first same-language translation skip was written against the old source-locale setting model, but main later removed the Deepgram source language setting and made transcript segments carry detected language codes.

### Correct approach
Live caption translation skip logic should compare each turn's actual source locale from the transcript segment against the configured main/target language, including bare detected language codes like `ja` against locales like `ja-JP`.

### How to avoid
When a setting is redefined or removed, audit behavior against the runtime data that now represents that concept instead of the old configuration field.

---

## [58] Trace display metadata through pre-render coalescing

**Date**: 2026-04-29
**Category**: logic-error

### What went wrong
The first subtitle timestamp design put `startedAt` on speaker groups, but review found that same-speaker caption turns could already be merged by `LiveCaptionStore`, with `createdAt` overwritten by the latest segment before grouping.

### Correct approach
When displaying first-item metadata for grouped UI state, preserve that metadata at every earlier coalescing layer, not only in the final view grouping type.

### How to avoid
For grouped display metadata, trace the data from source segment to store merge to view grouping before treating a group-level test as sufficient.

---

## [63] Make async coalescing regressions deterministic

**Date**: 2026-04-29
**Category**: test-mistake

### What went wrong
The first superseded draft translation regression used a sleeping fake provider and asserted completion state, which could pass or fail based on task scheduling instead of proving the stale request was skipped before provider work.

### Correct approach
Use a manually delayed provider and assert the pending provider queue shape directly when testing async coalescing or cancellation behavior.

### How to avoid
For async cancellation tests, assert deterministic intermediate state instead of relying on sleep timing or completion ordering.

---

## [67] Use narrow context when patching repeated test initializers

**Date**: 2026-04-29
**Category**: test-mistake

### What went wrong
While injecting deterministic summary providers into view-model summary tests, a broad patch matched repeated `MeetingAgentViewModel(store:processTargetsProvider:)` initializers in unrelated progress-loading tests before the intended legacy summary URL test.

### Correct approach
Patch repeated test setup with nearby behavior-specific context, then inspect the exact changed hunks before running verification.

### How to avoid
When a test file repeats the same initializer shape, include the test name or adjacent setup lines in the patch context.

---

## [69] Refresh view-model metadata after recorder startup persistence

**Date**: 2026-04-29
**Category**: logic-error

### What went wrong
Starting a detected meeting let `MeetingRecorder` persist the record as transcribing, but `MeetingAgentViewModel` kept the pre-start in-memory record, so the meeting page could still show transcription as not started.

### Correct approach
After async recorder startup completes, refresh the affected meeting from the store so UI state reflects recorder-owned transcription metadata, including startup failures.

### How to avoid
When a lower-level service mutates persisted model state during an async operation, update the caller's in-memory model before returning to the UI.

---
