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
