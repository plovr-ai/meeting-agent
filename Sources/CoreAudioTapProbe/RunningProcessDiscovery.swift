import AppKit
import Foundation

struct RunningProcessDiscovery {
    static let preferredBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "company.thebrowser.Browser",
        "com.apple.Safari",
        "com.larksuite.Lark",
        "com.tencent.meeting"
    ]

    static func currentTargets() -> [AudioCaptureTarget] {
        let apps = NSWorkspace.shared.runningApplications.map {
            RunningAppSnapshot(
                processID: $0.processIdentifier,
                displayName: $0.localizedName,
                bundleIdentifier: $0.bundleIdentifier
            )
        }
        return targets(from: apps, currentProcessID: ProcessInfo.processInfo.processIdentifier)
    }

    static func targets(from apps: [RunningAppSnapshot], currentProcessID: pid_t) -> [AudioCaptureTarget] {
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
            let lhsPreferred = lhs.bundleIdentifier.map(preferredBundleIDs.contains) ?? false
            let rhsPreferred = rhs.bundleIdentifier.map(preferredBundleIDs.contains) ?? false

            if lhsPreferred != rhsPreferred {
                return lhsPreferred && !rhsPreferred
            }

            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func automaticTarget(from targets: [AudioCaptureTarget]) -> AudioCaptureTarget? {
        targets.first { target in
            target.bundleIdentifier.map(preferredBundleIDs.contains) ?? false
        }
    }
}
