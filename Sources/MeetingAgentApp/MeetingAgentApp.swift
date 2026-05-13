import AppKit
import MeetingAgentCore
import SwiftUI

@main
struct MeetingAgentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MeetingAgentViewModel()

    private var defaultWindowSize: CGSize {
        DefaultWindowSizing.mainWindowSize()
    }

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
        .defaultSize(width: defaultWindowSize.width, height: defaultWindowSize.height)
    }
}

enum DefaultWindowSizing {
    private static let fallbackSize = CGSize(width: 1_200, height: 800)

    static func mainWindowSize(screenSize: CGSize? = NSScreen.main?.visibleFrame.size) -> CGSize {
        guard let screenSize else { return fallbackSize }

        return CGSize(
            width: min(screenSize.width, 1_400),
            height: screenSize.height
        )
    }
}
