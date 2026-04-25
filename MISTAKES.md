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
