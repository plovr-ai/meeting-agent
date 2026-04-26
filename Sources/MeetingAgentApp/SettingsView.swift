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

            Section("Transcription Chain") {
                Picker("Transcription Mode", selection: $draft.transcriptionExecutionMode) {
                    Text("Local").tag(ProviderExecutionMode.local)
                    Text("Hosted").tag(ProviderExecutionMode.hosted)
                }

                if draft.transcriptionExecutionMode == .local {
                    Picker("Local Transcription Provider", selection: $draft.localTranscriptionProviderID) {
                        Text("Whisper Local").tag("whisper-local")
                        Text("macOS Speech").tag("macos-speech-local")
                    }

                    if draft.localTranscriptionProviderID == "whisper-local" {
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
                } else {
                    Picker("Hosted Transcription Provider", selection: $draft.hostedTranscriptionProviderID) {
                        Text("OpenRouter").tag("openrouter-transcribe")
                    }

                    Picker("Hosted Transcription Model", selection: $draft.hostedTranscriptionModelID) {
                        ForEach(BilingualPipelineFactory.hostedTranscriptionModelOptions) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
            }

            Section("Translation Chain") {
                Picker("Translation Mode", selection: $draft.translationExecutionMode) {
                    Text("Local").tag(ProviderExecutionMode.local)
                    Text("Hosted").tag(ProviderExecutionMode.hosted)
                }

                if draft.translationExecutionMode == .local {
                    Picker("Local Translation Provider", selection: $draft.localTranslationProviderID) {
                        Text("Qwen Local Translation").tag("qwen-local-translation")
                        Text("NLLB Local").tag("nllb-local")
                    }
                } else {
                    Picker("Hosted Translation Provider", selection: $draft.hostedTranslationProviderID) {
                        Text("OpenRouter").tag("openrouter-translation")
                    }

                    Picker("Hosted Translation Model", selection: $draft.hostedTranslationModelID) {
                        ForEach(BilingualPipelineFactory.hostedTranslationModelOptions) { model in
                            Text(model.displayName).tag(model.id)
                        }
                    }
                }
            }

            if usesOpenRouter {
                Section("OpenRouter") {
                    SecureField("OpenRouter API Key", text: openRouterAPIKeyBinding)
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
        .onChange(of: draft.localTranscriptionProviderID) { _, providerID in
            draft.provider = providerID == "macos-speech-local" ? .local : .whisper
        }
        .onChange(of: draft.transcriptionExecutionMode) { _, mode in
            if mode == .hosted {
                draft.hostedTranscriptionProviderID = "openrouter-transcribe"
                ensureHostedTranscriptionModel()
            } else {
                draft.provider = draft.localTranscriptionProviderID == "macos-speech-local" ? .local : .whisper
            }
        }
        .onChange(of: draft.translationExecutionMode) { _, mode in
            if mode == .hosted {
                draft.hostedTranslationProviderID = "openrouter-translation"
                ensureHostedTranslationModel()
            }
        }
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

    private var openRouterAPIKeyBinding: Binding<String> {
        Binding(
            get: { draft.openRouterAPIKey ?? "" },
            set: { draft.openRouterAPIKey = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var usesOpenRouter: Bool {
        draft.usesOpenRouter
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

    private func ensureHostedTranscriptionModel() {
        if BilingualPipelineFactory.hostedTranscriptionModelOptions.contains(where: { $0.id == draft.hostedTranscriptionModelID }) {
            return
        }
        draft.hostedTranscriptionModelID = BilingualPipelineFactory.hostedTranscriptionModelOptions.first?.id
            ?? SpeechTranscriptionConfiguration.defaultHostedTranscriptionModelID
    }

    private func ensureHostedTranslationModel() {
        if BilingualPipelineFactory.hostedTranslationModelOptions.contains(where: { $0.id == draft.hostedTranslationModelID }) {
            return
        }
        draft.hostedTranslationModelID = BilingualPipelineFactory.hostedTranslationModelOptions.first?.id
            ?? SpeechTranscriptionConfiguration.defaultHostedTranslationModelID
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
