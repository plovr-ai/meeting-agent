# Caption-Only Configuration Cleanup Design

## Context

Issue #146 asks the active app surface to stop presenting realtime captions as a bilingual or translation pipeline. Active recording is caption-only, while old translation models and artifacts may remain for legacy data compatibility.

## Requirements

- Settings must expose only speech, transcription, summary model, and provider credentials.
- `MainWindowView` must not depend on bilingual profiles to render settings.
- Visible transcript UI implementation names should match caption-only behavior.
- Old user defaults containing translation or bilingual keys must still decode safely.
- New configuration saves should avoid writing legacy translation and bilingual keys.

## Non-Requirements

- Do not delete historical translation model types, stores, fixtures, or old tests that still protect legacy data.
- Do not remove transcript segment translation fields used by old artifacts.
- Do not introduce a realtime translation path.

## Approach

Keep legacy keys as decode-only migration inputs in `SpeechTranscriptionConfiguration`. Store them in a small legacy compatibility container so old defaults can be read, but encode only current caption-era fields. `MeetingAgentViewModel.saveSpeechConfiguration` should preserve current transcription and summary settings while dropping derived bilingual profile behavior.

`SettingsView` should remove the `profiles` input and stop accepting `BilingualPipelineProfile`. It can still use transcription and summary model option constants until the larger factory is renamed in a future cleanup, but the settings entry point should no longer be driven by bilingual profiles.

`MainWindowView` should pass settings without profiles and rename private transcript rendering views from `BilingualTranscriptGroup` / `BilingualTranscriptBlock` to `CaptionTranscriptGroup` / `CaptionTranscriptBlock`. Its meeting header should describe the active transcription chain directly rather than looking up a bilingual profile display name.

## Test Plan

- Add/adjust configuration tests so legacy bilingual/translation keys decode without throwing.
- Assert newly encoded configuration JSON omits legacy bilingual and translation keys.
- Update view-model settings tests so save behavior preserves transcription and summary fields while dropping legacy profile derivation.
- Update source-layout tests to expect caption-only UI type names and no `BilingualPipelineFactory.builtInProfiles` settings dependency.
