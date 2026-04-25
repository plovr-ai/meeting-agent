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
