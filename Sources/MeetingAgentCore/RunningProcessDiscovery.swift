import AppKit
import Foundation

public struct RunningProcessDiscovery {
    public static let preferredBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.larksuite.Lark",
        "com.electron.larkFeishu",
        "com.tencent.meeting"
    ]

    private static let preferredDisplayNamePrefixes = [
        "feishu",
        "飞书",
        "lark"
    ]

    public static func currentTargets() -> [AudioCaptureTarget] {
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningAppSnapshot(
                processID: $0.processIdentifier,
                displayName: $0.localizedName,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        return targets(from: apps, currentProcessID: ProcessInfo.processInfo.processIdentifier)
            .map { target in
                AudioCaptureTarget(
                    processID: target.processID,
                    displayName: target.displayName,
                    bundleIdentifier: target.bundleIdentifier,
                    isAudioOutputActive: CoreAudioHelpers.isAudioOutputActive(for: target)
                )
            }
    }

    public static func targets(from apps: [RunningAppSnapshot], currentProcessID: pid_t) -> [AudioCaptureTarget] {
        apps.compactMap { app in
            guard app.processID != currentProcessID else { return nil }
            guard let name = app.displayName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

            return AudioCaptureTarget(
                processID: app.processID,
                displayName: name,
                bundleIdentifier: app.bundleIdentifier
            )
        }
        .sorted { lhs, rhs in
            let lhsPreferred = isPreferredMeetingTarget(lhs)
            let rhsPreferred = isPreferredMeetingTarget(rhs)

            if lhsPreferred != rhsPreferred {
                return lhsPreferred && !rhsPreferred
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    public static func automaticTarget(from targets: [AudioCaptureTarget]) -> AudioCaptureTarget? {
        targets.first { target in
            isPreferredMeetingTarget(target) && target.isAudioOutputActive
        }
    }

    public static func isPreferredMeetingTarget(_ target: AudioCaptureTarget) -> Bool {
        if target.bundleIdentifier.map(preferredBundleIDs.contains) ?? false {
            return true
        }

        let displayName = target.displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return preferredDisplayNamePrefixes.contains { prefix in
            displayName == prefix || displayName.hasPrefix("\(prefix) ")
        }
    }
}
