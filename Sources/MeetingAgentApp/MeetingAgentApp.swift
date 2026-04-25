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
                .onAppear {
                    appDelegate.viewModel = viewModel
                }
                .task {
                    try? viewModel.loadMeetings()
                }
        }
    }
}
