import Foundation

public final class MeetingProcessMonitor {
    private var promptedProcessIDs: Set<pid_t> = []
    private var ignoredProcessIDs: Set<pid_t> = []

    public init() {}

    public func detectNewCandidates(
        in targets: [AudioCaptureTarget],
        isRecording: Bool
    ) -> [AudioCaptureTarget] {
        guard !isRecording else { return [] }

        let candidates = targets.filter { target in
            let isPreferred = RunningProcessDiscovery.isPreferredMeetingTarget(target)
            guard isPreferred else { return false }
            guard target.isAudioOutputActive else { return false }
            guard !promptedProcessIDs.contains(target.processID) else { return false }
            guard !ignoredProcessIDs.contains(target.processID) else { return false }
            return true
        }

        for candidate in candidates {
            promptedProcessIDs.insert(candidate.processID)
        }

        return candidates
    }

    public func ignore(processID: pid_t) {
        ignoredProcessIDs.insert(processID)
    }

    public func allowReprompt(processID: pid_t) {
        promptedProcessIDs.remove(processID)
    }

    public func reconcileRunningProcessIDs(_ runningProcessIDs: Set<pid_t>) {
        promptedProcessIDs = promptedProcessIDs.intersection(runningProcessIDs)
        ignoredProcessIDs = ignoredProcessIDs.intersection(runningProcessIDs)
    }

    public func isProcessRunning(processID: pid_t, in targets: [AudioCaptureTarget]) -> Bool {
        targets.contains { $0.processID == processID }
    }

    public func hasProcessEnded(processID: pid_t, in targets: [AudioCaptureTarget]) -> Bool {
        !isProcessRunning(processID: processID, in: targets)
    }
}
