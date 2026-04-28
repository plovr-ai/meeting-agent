# Installable App Package Design

## Issue

GitHub issue #38 asks for a complete app project adaptation so other people can install and use Meeting Agent. The current project is a Swift Package with a `MeetingAgentApp` executable target. That supports `swift run` and `swift build`, but it does not produce a standard macOS `.app` bundle that someone can drag into `/Applications`.

## Scope

This issue adds a reproducible local packaging path that produces `dist/MeetingAgent.app` from the existing SwiftPM app target.

In scope:

- Build `MeetingAgentApp` in release mode.
- Assemble a standard macOS app bundle under `dist/MeetingAgent.app`.
- Add app bundle metadata in an `Info.plist`.
- Preserve required macOS permission usage strings for audio capture, speech recognition, and notifications.
- Add a stable `make package-app` entrypoint.
- Add regression tests for packaging script and bundle metadata structure.

Out of scope:

- Developer ID signing.
- Apple notarization.
- DMG or PKG installer generation.
- CI release publishing.
- Bundling external Whisper binaries or models.

The generated app is locally installable and can be shared for prototype testing, but because it is not Developer ID signed or notarized, Gatekeeper may require users to right-click Open or approve the app in System Settings on first launch.

## Options Considered

1. Keep SwiftPM and add a packaging script.
   - Pros: small change, matches the current package structure, produces a usable `.app` immediately, and keeps future signing/notarization as a separate layer.
   - Cons: installer polish and notarized distribution remain follow-up work.

2. Convert the project to an Xcode app project.
   - Pros: closer to conventional macOS distribution and future signing workflows.
   - Cons: adds generated project-file complexity and duplicates build configuration that SwiftPM already owns.

3. Implement a SwiftPM command plugin for packaging.
   - Pros: more SwiftPM-native command surface.
   - Cons: higher implementation and maintenance cost without clear benefit for this repository today.

Selected approach: option 1. The repository already treats SwiftPM as the source of truth, and issue #38 only needs an installable app artifact for others to use.

## Design

Add `Sources/MeetingAgentApp/Resources/Info.plist` as the bundle metadata template. It will declare:

- `CFBundleName` and `CFBundleDisplayName` as `Meeting Agent`.
- `CFBundleExecutable` as `MeetingAgentApp`.
- A stable bundle identifier, `ai.plovr.MeetingAgent`.
- `CFBundlePackageType` as `APPL`.
- `LSMinimumSystemVersion` as `14.2`.
- Version fields for the prototype bundle.
- Permission usage descriptions for microphone access, speech recognition, and user notifications.

Add `scripts/package-app.sh`. The script will:

1. Resolve the repository root from its own location.
2. Run `swift build -c release --product MeetingAgentApp`.
3. Recreate `dist/MeetingAgent.app/Contents/MacOS` and `dist/MeetingAgent.app/Contents/Resources`.
4. Copy the release executable to `Contents/MacOS/MeetingAgentApp`.
5. Copy the app `Info.plist` to `Contents/Info.plist`.
6. Add a `PkgInfo` file with `APPL????`.
7. Optionally run ad-hoc codesigning when `codesign` is available, using `codesign --force --sign -`.
8. Print the generated app path.

Ad-hoc signing is not treated as a substitute for Developer ID signing. It only makes the local bundle more coherent for prototype testing. If ad-hoc signing fails, the script should fail clearly rather than silently producing a misleading artifact.

Add `package-app` to `Makefile` so the supported commands become:

- `make test`
- `make package-app`
- `swift build --product MeetingAgentApp`
- `swift run MeetingAgentApp`

Update `AGENTS.md` with the packaging command and distribution limitation: the artifact is locally installable but unsigned and unnotarized.

## Testing

Add source-level scaffold tests instead of launching the GUI app. The tests should verify:

- `scripts/package-app.sh` exists.
- The script builds `MeetingAgentApp` in release mode.
- The script creates `dist/MeetingAgent.app/Contents/MacOS` and `Contents/Resources`.
- The script copies `Sources/MeetingAgentApp/Resources/Info.plist`.
- The `Info.plist` contains the expected bundle executable, package type, minimum macOS version, and permission usage keys.
- `Makefile` exposes `package-app`.

Local verification will run:

- `make test`
- `swift build --product MeetingAgentApp`
- `make package-app`

