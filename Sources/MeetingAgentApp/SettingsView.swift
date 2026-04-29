import MeetingAgentCore
import SwiftUI

struct SettingsView: View {
    let configuration: SpeechTranscriptionConfiguration
    let profiles: [BilingualPipelineProfile]
    let localeIdentifiers: [String]
    let isRecording: Bool
    let status: SpeechConfigurationValidationStatus
    let primaryChainPreflightResult: PrimaryChainPreflightResult
    let save: (SpeechTranscriptionConfiguration) -> Void

    @State private var draft: SpeechTranscriptionConfiguration

    init(
        configuration: SpeechTranscriptionConfiguration,
        profiles: [BilingualPipelineProfile],
        localeIdentifiers: [String],
        isRecording: Bool,
        status: SpeechConfigurationValidationStatus,
        primaryChainPreflightResult: PrimaryChainPreflightResult,
        save: @escaping (SpeechTranscriptionConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.profiles = profiles
        self.localeIdentifiers = localeIdentifiers
        self.isRecording = isRecording
        self.status = status
        self.primaryChainPreflightResult = primaryChainPreflightResult
        self.save = save
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        CommandCenterScrollView(content: {
            VStack(alignment: .leading, spacing: 16) {
                CommandCenterPageHeader(title: "Settings", subtitle: "Speech, transcription chain, and provider credentials")

                SettingsCommandCenterPanel("Speech") {
                    Picker("Main Language", selection: $draft.targetLocaleIdentifier) {
                        ForEach(localeIdentifiers, id: \.self) { localeIdentifier in
                            Text(localeIdentifier).tag(localeIdentifier)
                        }
                    }
                }

                SettingsCommandCenterPanel("Transcription Chain") {
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
                            Text("Deepgram").tag("deepgram-transcribe")
                        }

                        if draft.hostedTranscriptionProviderID == "deepgram-transcribe" {
                            Picker("Hosted Transcription Model", selection: $draft.deepgramModelID) {
                                Text("Deepgram Nova 3").tag("nova-3")
                                Text("Deepgram Nova 2").tag("nova-2")
                            }
                        } else {
                            Picker("Hosted Transcription Model", selection: $draft.hostedTranscriptionModelID) {
                                ForEach(BilingualPipelineFactory.hostedTranscriptionModelOptions.filter { $0.id != "nova-3" }) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                        }
                    }
                }

                if usesOpenRouter {
                    SettingsCommandCenterPanel("OpenRouter") {
                        SecureField("OpenRouter API Key", text: openRouterAPIKeyBinding)

                        Picker("Hosted Translation Model", selection: $draft.hostedTranslationModelID) {
                            ForEach(BilingualPipelineFactory.hostedTranslationModelOptions) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }

                        Picker("Hosted Summary Model", selection: $draft.hostedSummaryModelID) {
                            ForEach(BilingualPipelineFactory.hostedSummaryModelOptions) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                    }
                }

                if usesDeepgram {
                    SettingsCommandCenterPanel("Deepgram") {
                        SecureField("Deepgram API Key", text: deepgramAPIKeyBinding)
                    }
                }

                SettingsCommandCenterPanel("Validation") {
                    Text(primaryChainPreflightText)
                        .commandCenterCaption(primaryChainPreflightColor)

                    Text(configurationStatusText)
                        .commandCenterCaption(configurationStatusColor)

                    HStack {
                        Button("Save") {
                            save(draft)
                        }
                        .buttonStyle(CommandCenterActionButtonStyle(variant: .primary))
                        .disabled(isRecording)

                        Button("Reset") {
                            draft = configuration
                        }
                        .buttonStyle(CommandCenterActionButtonStyle())
                    }
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(24)
            .foregroundStyle(CommandCenterPalette.text)
            .tint(CommandCenterPalette.primary)
        })
        .background(CommandCenterPalette.window)
        .foregroundStyle(CommandCenterPalette.text)
        .tint(CommandCenterPalette.primary)
        .disabled(isRecording)
        .onChange(of: draft.localTranscriptionProviderID) { _, providerID in
            draft.provider = providerID == "macos-speech-local" ? .local : .whisper
        }
        .onChange(of: draft.transcriptionExecutionMode) { _, mode in
            if mode == .hosted {
                if draft.hostedTranscriptionProviderID != "deepgram-transcribe" {
                    draft.hostedTranscriptionProviderID = "openrouter-transcribe"
                }
                ensureHostedTranscriptionModel()
            } else {
                draft.provider = draft.localTranscriptionProviderID == "macos-speech-local" ? .local : .whisper
            }
        }
        .onChange(of: draft.hostedTranscriptionProviderID) { _, _ in
            ensureHostedTranscriptionModel()
        }
        .onChange(of: draft.hostedTranslationProviderID) { _, _ in
            ensureHostedTranslationModel()
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

    private var deepgramAPIKeyBinding: Binding<String> {
        Binding(
            get: { draft.deepgramAPIKey ?? "" },
            set: { draft.deepgramAPIKey = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var usesOpenRouter: Bool {
        draft.usesOpenRouter
    }

    private var usesDeepgram: Bool {
        draft.usesDeepgram
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
            ProcessInfo.processInfo.environment["MEETING_AGENT_WHISPER_MODEL"]
        ] + WhisperConfigurationResolver.modelPathOptions())
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
        if draft.hostedTranscriptionProviderID == "deepgram-transcribe" {
            if ["nova-3", "nova-2"].contains(draft.deepgramModelID) {
                return
            }
            draft.deepgramModelID = SpeechTranscriptionConfiguration.defaultDeepgramModelID
            return
        }
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
            return CommandCenterPalette.secondaryText
        case .unavailable:
            return CommandCenterPalette.danger
        }
    }

    private var primaryChainPreflightText: String {
        switch primaryChainPreflightResult.status {
        case .available:
            return "Primary chain ready"
        case .unavailable:
            return primaryChainPreflightResult.messages.joined(separator: "; ")
        }
    }

    private var primaryChainPreflightColor: Color {
        switch primaryChainPreflightResult.status {
        case .available:
            return CommandCenterPalette.secondaryText
        case .unavailable:
            return CommandCenterPalette.danger
        }
    }
}
