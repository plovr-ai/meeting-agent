# App-Only Package Design

## Issue

GitHub issue #20 asks to remove CLI mode and keep only the app. The confirmed scope is to remove the `CoreAudioTapProbe` SwiftPM executable product, target, CLI entry point, CLI Info.plist, CLI argument parser, CLI-focused tests, and CLI command references. Shared capture, recording, transcription, translation, and meeting logic stays in `MeetingAgentCore` for `MeetingAgentApp`.

## Success Criteria

- `Package.swift` exposes `MeetingAgentCore`, `MeetingAgentApp`, and `MeetingAgentCoreTests` only.
- `Sources/CoreAudioTapProbe/` is gone.
- CLI-only `ProbeOptions`, `.record` output naming, and tests for CLI flag parsing are gone.
- Docs no longer present `swift run CoreAudioTapProbe` as a supported workflow.
- `swift test` and `swift build --product MeetingAgentApp` pass.

## Options Considered

1. Fully remove the CLI product and CLI-only files.
   - Pros: matches the issue directly, reduces product surface, keeps reusable logic intact.
   - Cons: removes a debugging executable that has been useful historically.

2. Keep the target but hide the command from docs.
   - Pros: lower implementation risk.
   - Cons: does not actually remove CLI mode.

3. Replace the CLI with an app-only diagnostic command inside the app.
   - Pros: preserves some diagnostic workflows.
   - Cons: larger feature with UI/product decisions outside this issue.

Selected approach: option 1. The existing architecture already moved reusable behavior into `MeetingAgentCore`, so deleting the CLI wrapper is a small package cleanup.

## Design

`Package.swift` will remove the `CoreAudioTapProbe` product and executable target. The app target remains unchanged and continues to depend on `MeetingAgentCore`.

`Sources/CoreAudioTapProbe/ProbeMain.swift` and `Sources/CoreAudioTapProbe/Info.plist` will be deleted. `Sources/MeetingAgentCore/ProbeOptions.swift` will also be deleted because it only parses CLI flags and has no app consumers. `Sources/MeetingAgentCore/RecordingOutput.swift` will be deleted because it only supports the removed CLI `.record` output convention, while the still-used `TranscriptFileWriter` will move into its own file.

Tests will keep coverage for reusable core types, remove CLI parser and `.record` naming assertions, and keep transcript writer coverage under `TranscriptFileWriterTests`. A small manifest regression test will verify that the package manifest does not reintroduce `CoreAudioTapProbe`.

Documentation will remove supported CLI commands and rewrite current runtime notes around app usage and shared core behavior. Historical design and plan documents stay as history unless they block current usage; they are not active command docs.

## Test Plan

- Add a manifest regression test that fails while `CoreAudioTapProbe` remains in `Package.swift`.
- Run the focused manifest test and `TranscriptFileWriterTests`.
- Run `swift test`.
- Run `swift build --product MeetingAgentApp`.
