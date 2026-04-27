import Foundation

public enum BilingualPipelineFactory {
    public struct ModelOption: Codable, Equatable, Identifiable {
        public var id: String
        public var displayName: String

        public init(id: String, displayName: String) {
            self.id = id
            self.displayName = displayName
        }
    }

    public static let builtInRegistry = ProviderRegistry(descriptors: builtInProviderDescriptors)

    public static let hostedTranscriptionModelOptions: [ModelOption] = [
        ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash"),
        ModelOption(id: "openai/gpt-4o-mini-transcribe", displayName: "GPT-4o Mini Transcribe"),
        ModelOption(id: "nova-3", displayName: "Deepgram Nova 3")
    ]

    public static let hostedTranslationModelOptions: [ModelOption] = [
        ModelOption(id: "openai/gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
        ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash")
    ]

    public static let builtInProviderDescriptors: [ProviderDescriptor] = [
        ProviderDescriptor(id: "whisper-local", displayName: "Whisper Local", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "macos-speech-local", displayName: "macOS Speech", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "openrouter-transcribe", displayName: "OpenRouter Transcribe", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "deepgram-transcribe", displayName: "Deepgram Transcribe", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "openrouter-translation", displayName: "OpenRouter Translation", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "qwen-local-translation", displayName: "Qwen Local Translation", capability: .textTranslation, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "nllb-local", displayName: "NLLB Local", capability: .textTranslation, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
    ]

    public static let builtInProfiles: [BilingualPipelineProfile] = [
        BilingualPipelineProfile(id: "deepgram-stt-hosted-translation", displayName: "Deepgram Nova-3 + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("deepgram-transcribe"), fallbacks: [.provider("whisper-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openrouter-translation"))
        ]),
        BilingualPipelineProfile(id: "local-whisper-hosted-translation", displayName: "Local Whisper + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("openrouter-transcribe")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openrouter-translation"), fallbacks: [.provider("qwen-local-translation"), .provider("nllb-local")])
        ]),
        BilingualPipelineProfile(id: "local-whisper-local-translation", displayName: "Local Whisper + Local Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("macos-speech-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("qwen-local-translation"), fallbacks: [.provider("nllb-local")])
        ]),
        BilingualPipelineProfile(id: "hosted-transcribe-hosted-translation", displayName: "Hosted Transcribe + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("openrouter-transcribe"), fallbacks: [.provider("whisper-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openrouter-translation"))
        ])
    ]
}
