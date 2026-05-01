# Transcript Display Mode Design

## Context

Issue #126 asks the transcript module to support original-language only, translation only, and both-language display modes, with both as the default. The current meeting workspace always renders live caption turns as source text plus translated text when a second language is available, and falls back to original text when no translation is available.

## Goals

- Add a transcript display control in the meeting workspace.
- Support three modes: both languages, original only, and translation only.
- Keep the default behavior as both languages.
- Limit the change to display behavior. Transcription, translation scheduling, persistence, and exports stay unchanged.

## Non-Goals

- Do not add a global persisted setting.
- Do not change the bilingual transcript file format.
- Do not stop translation requests when the user temporarily hides translation text.
- Do not change transcript export output.

## Selected Approach

Add a local transcript display mode state to the workspace transcript pane and pass it through the existing transcript view hierarchy. A small segmented picker in the Transcript header lets the user switch between Both, Original, and Translation. This keeps the option close to the affected content and avoids expanding application settings for a view-only preference.

## Alternatives Considered

### Settings-Level Preference

Persisting the mode in settings would make the preference survive app relaunches, but it broadens the issue into configuration persistence and migration. The issue is about transcript module display, so this is unnecessary for the first version.

### Reusing Second-Language Enablement

The existing `secondLanguageEnabled` logic only decides whether translation should appear based on locale and translation availability. Overloading it for explicit user modes would make "translation only" hard to model and would blur automatic locale behavior with user intent.

## Architecture

- Add `LiveCaptionDisplayMode` in core as a small public enum with `.both`, `.originalOnly`, and `.translationOnly`.
- Extend `LiveCaptionDisplayState` to accept a display mode while preserving the existing initializer for current tests and callers.
- Keep fallback behavior explicit: translation-only mode shows translated text when available; otherwise it shows translation pending or unavailable states instead of silently rendering original text as the primary content.
- Store `@State private var transcriptDisplayMode: LiveCaptionDisplayMode = .both` inside `TranscriptPaneView`.
- Add a segmented picker beside the Transcript header and pass the selected mode into each transcript block.

## Testing

- Unit test `LiveCaptionDisplayState` for all three display modes, including translation-only pending and failed states.
- Source-layout test that `MainWindowView` defines the display mode state, segmented picker labels, and passes the mode to transcript blocks.
- Run the required `make test` verification.

## User Approval

The design was presented in conversation and approved with "OK" before implementation.
