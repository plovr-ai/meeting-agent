import MeetingAgentCore
import SwiftUI

struct SettingsView: View {
    let configuration: SpeechTranscriptionConfiguration
    let localeIdentifiers: [String]
    let isRecording: Bool
    let status: SpeechConfigurationValidationStatus
    let primaryChainPreflightResult: PrimaryChainPreflightResult
    let save: (SpeechTranscriptionConfiguration) -> Void
    @Binding var karpathyWikiEnabled: Bool
    @Binding var karpathyWikiRootPath: String

    @State private var draft: SpeechTranscriptionConfiguration

    init(
        configuration: SpeechTranscriptionConfiguration,
        localeIdentifiers: [String],
        isRecording: Bool,
        status: SpeechConfigurationValidationStatus,
        primaryChainPreflightResult: PrimaryChainPreflightResult,
        karpathyWikiEnabled: Binding<Bool>,
        karpathyWikiRootPath: Binding<String>,
        save: @escaping (SpeechTranscriptionConfiguration) -> Void
    ) {
        self.configuration = configuration
        self.localeIdentifiers = localeIdentifiers
        self.isRecording = isRecording
        self.status = status
        self.primaryChainPreflightResult = primaryChainPreflightResult
        self.save = save
        _karpathyWikiEnabled = karpathyWikiEnabled
        _karpathyWikiRootPath = karpathyWikiRootPath
        _draft = State(initialValue: configuration)
    }

    var body: some View {
        CommandCenterScrollView(content: {
            VStack(alignment: .leading, spacing: 16) {
                CommandCenterPageHeader(title: "Settings", subtitle: "Speech, transcription chain, and provider credentials")

                SettingsCommandCenterPanel("Speech") {
                    Picker("Main Language", selection: $draft.localeIdentifier) {
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
                            Text("Aliyun Paraformer").tag("aliyun-paraformer-realtime-transcribe")
                        }

                        if draft.hostedTranscriptionProviderID == "deepgram-transcribe" {
                            Picker("Hosted Transcription Model", selection: $draft.deepgramModelID) {
                                Text("Deepgram Nova 3").tag("nova-3")
                                Text("Deepgram Nova 2").tag("nova-2")
                            }
                        } else if draft.hostedTranscriptionProviderID == "aliyun-paraformer-realtime-transcribe" {
                            Picker("Hosted Transcription Model", selection: $draft.aliyunRealtimeModelID) {
                                Text("Aliyun Paraformer Realtime v2").tag("paraformer-realtime-v2")
                            }
                        } else {
                            Picker("Hosted Transcription Model", selection: $draft.hostedTranscriptionModelID) {
                                ForEach(openRouterTranscriptionModelOptions) { model in
                                    Text(model.displayName).tag(model.id)
                                }
                            }
                        }
                    }
                }

                if usesOpenRouter {
                    SettingsCommandCenterPanel("OpenRouter") {
                        SecureField("OpenRouter API Key", text: openRouterAPIKeyBinding)

                        Picker("Hosted Summary Model", selection: $draft.hostedSummaryModelID) {
                            ForEach(SpeechProviderCatalog.hostedSummaryModelOptions) { model in
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

                if usesAliyunRealtime {
                    SettingsCommandCenterPanel("Aliyun") {
                        SecureField("DashScope API Key", text: dashScopeAPIKeyBinding)
                    }
                }

                SettingsCommandCenterPanel("Knowledge Destinations") {
                    Toggle("Export to Karpathy Wiki", isOn: $karpathyWikiEnabled)
                        .toggleStyle(.checkbox)

                    CommandCenterTextEditor(text: $karpathyWikiRootPath)
                        .frame(minHeight: 44, maxHeight: 44)
                        .disabled(!karpathyWikiEnabled)
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
                let hostedProviders = [
                    "openrouter-transcribe",
                    "deepgram-transcribe",
                    "aliyun-paraformer-realtime-transcribe"
                ]
                if !hostedProviders.contains(draft.hostedTranscriptionProviderID) {
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

    private var dashScopeAPIKeyBinding: Binding<String> {
        Binding(
            get: { draft.dashScopeAPIKey ?? "" },
            set: { draft.dashScopeAPIKey = SpeechTranscriptionConfiguration.normalized($0) }
        )
    }

    private var usesOpenRouter: Bool {
        draft.usesOpenRouter
    }

    private var usesDeepgram: Bool {
        draft.usesDeepgram
    }

    private var usesAliyunRealtime: Bool {
        draft.usesAliyunRealtime
    }

    private var openRouterTranscriptionModelOptions: [SpeechProviderCatalog.ModelOption] {
        SpeechProviderCatalog.hostedTranscriptionModelOptions.filter {
            !["nova-3", "paraformer-realtime-v2"].contains($0.id)
        }
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
        if draft.hostedTranscriptionProviderID == "aliyun-paraformer-realtime-transcribe" {
            if draft.aliyunRealtimeModelID == "paraformer-realtime-v2" {
                return
            }
            draft.aliyunRealtimeModelID = SpeechTranscriptionConfiguration.defaultAliyunRealtimeTranscriptionModelID
            return
        }
        if SpeechProviderCatalog.hostedTranscriptionModelOptions.contains(where: { $0.id == draft.hostedTranscriptionModelID }) {
            return
        }
        draft.hostedTranscriptionModelID = SpeechProviderCatalog.hostedTranscriptionModelOptions.first?.id
            ?? SpeechTranscriptionConfiguration.defaultHostedTranscriptionModelID
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
