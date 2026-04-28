# Feishu System Audio Capture Design

GitHub issue #48 asks Meeting Agent to listen to Feishu meetings. The confirmed scope is the same system audio capture path already used for Zoom, Teams, browsers, and Tencent Meeting. This is not a Feishu Open Platform integration.

## Intent

When the Feishu or Lark desktop app is producing meeting audio, Meeting Agent should treat that process as a meeting capture target, prompt the user, and then reuse the existing `AudioCaptureSession`, `MeetingRecorder`, transcription, bilingual subtitle, translation, summary, and export workflows.

## Requirements

- Prefer native Feishu and Lark desktop app processes during running-process discovery.
- Prompt only when the process has active audio output, matching the current meeting app behavior.
- Keep non-audio Feishu/Lark processes from prompting.
- Preserve the existing recorder and transcription pipeline unchanged.
- Add regression coverage for bundle-ID and display-name based Feishu/Lark detection.

## Non-Requirements

- Do not add Feishu API, OAuth, bot, calendar, or meeting-record integration.
- Do not add a new capture backend.
- Do not change meeting persistence formats.
- Do not weaken active-audio gating for preferred meeting apps.

## Approach

Add a small classification helper in `RunningProcessDiscovery` so preferred meeting targets are recognized by either known bundle identifier or tightly-scoped Feishu/Lark display names. `targets(from:currentProcessID:)`, `automaticTarget(from:)`, and `MeetingProcessMonitor.detectNewCandidates` should all use the same helper so sorting, automatic target selection, and prompt detection stay consistent.

Known bundle identifiers already include `com.larksuite.Lark` and `com.electron.larkFeishu`. The fallback should match display names such as `Feishu`, `飞书`, `Lark`, and `Lark Meeting`, but should avoid broad substring matching that could promote unrelated helper apps.

## Testing

- Add `RunningProcessDiscovery` tests showing Feishu/Lark display names sort before non-meeting apps and automatically select only when audio is active.
- Add `MeetingProcessMonitor` tests showing an active Feishu/Lark display-name target prompts even with an unknown bundle ID.
- Run `make test` as the required repository verification command.
