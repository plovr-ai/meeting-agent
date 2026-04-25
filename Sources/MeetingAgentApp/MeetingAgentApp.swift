import MeetingAgentCore
import SwiftUI

@main
struct MeetingAgentApp: App {
    @StateObject private var viewModel = MeetingAgentViewModel()

    var body: some Scene {
        WindowGroup("Meeting Agent") {
            MainWindowView(viewModel: viewModel)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    try? viewModel.loadMeetings()
                }
        }
    }
}
