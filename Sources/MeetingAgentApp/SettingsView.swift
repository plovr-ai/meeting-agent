import MeetingAgentCore
import SwiftUI

struct SettingsView: View {
    let configuration: SpeechTranscriptionConfiguration
    let profiles: [BilingualPipelineProfile]
    let localeIdentifiers: [String]
    let isRecording: Bool
    let status: SpeechConfigurationValidationStatus
    let save: (SpeechTranscriptionConfiguration) -> Void

    @State private var draft: SpeechTranscriptionConfiguration

    init(
        configuration: SpeechTranscriptionConfiguration,
        profiles: [BilingualPipelineProfile],
        localeIdentifiers: [String],
        isRecording: Bool,
        status: SpeechConfigurationValidationStatus,
        save: @escaping (SpeechTranscriptionConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.profiles = profiles
        self.localeIdentifiers = localeIdentifiers
        self.isRecording = isRecording
        self.status = status
        self.save = save
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        Form {
            Section("Speech") {
                Picker("STT Provider", selection: $draft.provider) {
                    ForEach(SpeechProvider.allCases, id: \.self) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }

                Picker("Source Locale", selection: $draft.localeIdentifier) {
                    ForEach(localeIdentifiers, id: \.self) { localeIdentifier in
                        Text(localeIdentifier).tag(localeIdentifier)
                    }
                }

                Picker("Target Locale", selection: $draft.targetLocaleIdentifier) {
                    ForEach(localeIdentifiers, id: \.self) { localeIdentifier in
                        Text(localeIdentifier).tag(localeIdentifier)
                    }
                }
            }

            Section("Bilingual Pipeline") {
                Picker("Bilingual Pipeline Profile", selection: $draft.bilingualPipelineProfileID) {
                    ForEach(profiles, id: \.id) { profile in
                        Text(profile.displayName).tag(profile.id)
                    }
                }
            }

            Section("Whisper") {
                Picker("Whisper Binary Path", selection: whisperBinaryPathBinding) {
                    ForEach(whisperBinaryPathOptions, id: \.self) { path in
                        Text(path).tag(path)
                    }
                }

                Picker("Whisper Model Path", selection: whisperModelPathBinding) {
                    ForEach(whisperModelPathOptions, id: \.self) { path in
                        Text(path).tag(path)
                    }
                }
            }

            Section {
                Text(configurationStatusText)
                    .font(.caption)
                    .foregroundStyle(configurationStatusColor)

                HStack {
                    Button("Save") {
                        save(draft)
                    }
                    .disabled(isRecording)

                    Button("Reset") {
                        draft = configuration
                    }
                }
            }
        }
        .disabled(isRecording)
        .padding(20)
        .navigationTitle("Settings")
    }

    private var whisperBinaryPathBinding: Binding<String> {
        Binding(
            get: { draft.whisperBinaryPath ?? "" },
            set: { draft.whisperBinaryPath = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var whisperModelPathBinding: Binding<String> {
        Binding(
            get: { draft.whisperModelPath ?? "" },
            set: { draft.whisperModelPath = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var whisperBinaryPathOptions: [String] {
        uniqueNonBlank([
            draft.whisperBinaryPath,
            configuration.whisperBinaryPath,
            ProcessInfo.processInfo.environment["MEETING_AGENT_WHISPER_BIN"],
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli"
        ])
    }

    private var whisperModelPathOptions: [String] {
        uniqueNonBlank([
            draft.whisperModelPath,
            configuration.whisperModelPath,
            ProcessInfo.processInfo.environment["MEETING_AGENT_WHISPER_MODEL"],
            "/Users/allan/models/ggml-small.bin",
            "/Users/allan/models/ggml-medium.bin"
        ])
    }

    private func uniqueNonBlank(_ values: [String?]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { value in
            guard let normalized = SpeechTranscriptionConfiguration.normalized(value), !seen.contains(normalized) else {
                return nil
            }
            seen.insert(normalized)
            return normalized
        }
    }

    private var configurationStatusText: String {
        switch status {
        case .available:
            return "Configuration available"
        case .unavailable(let reason):
            return reason
        }
    }

    private var configurationStatusColor: Color {
        switch status {
        case .available:
            return .secondary
        case .unavailable:
            return .red
        }
    }
}
