# [82] File-backed sink write failures

**Date**: 2026-04-29
**Category**: api-misuse

### What went wrong
A file-backed transcript sink initially exposed only the non-throwing live `TranscriptUpdateSink.receive(_:)` path, which made batch and retry transcription callers silently ignore persistence failures after sink construction.

### Correct approach
Keep `receive(_:)` best-effort for realtime providers, but expose and use a throwing persistence method for batch/retry code paths that need failures to propagate.

### How to avoid
When adapting a realtime callback interface for batch workflows, preserve batch error semantics with a separate throwing API.
