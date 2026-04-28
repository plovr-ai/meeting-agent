import MeetingAgentCore
import SwiftUI

@main
struct MeetingAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MeetingAgentViewModel()

    var body: some Scene {
        WindowGroup("Meeting Agent") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 600)
                .commandCenterAppTheme()
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
                .task {
                    try? viewModel.loadMeetings()
                    var lastProcessPoll = Date.distantPast
                    while !Task.isCancelled {
                        if Date().timeIntervalSince(lastProcessPoll) >= 3,
                           let candidate = viewModel.pollForMeetingCandidates() {
                            lastProcessPoll = Date()
                            appDelegate.notifyMeetingDetected(candidate)
                        }
                        viewModel.drainRecordingFrames()
                        try? await Task.sleep(nanoseconds: 250_000_000)
                    }
                }
        }
    }
}
