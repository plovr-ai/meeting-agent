import Foundation

public enum BilingualPipelineFactory {
    public static let builtInRegistry = ProviderRegistry(descriptors: builtInProviderDescriptors)

    public static let builtInProviderDescriptors: [ProviderDescriptor] = [
        ProviderDescriptor(id: "whisper-local", displayName: "Whisper Local", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "macos-speech-local", displayName: "macOS Speech", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "openai-transcribe", displayName: "OpenAI Transcribe", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "openai-translation", displayName: "OpenAI Translation", capability: .textTranslation, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "qwen-local-translation", displayName: "Qwen Local Translation", capability: .textTranslation, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "nllb-local", displayName: "NLLB Local", capability: .textTranslation, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: ["*"], requiresNetwork: false, requiresAPIKey: false)
    ]

    public static let builtInProfiles: [BilingualPipelineProfile] = [
        BilingualPipelineProfile(id: "local-whisper-hosted-translation", displayName: "Local Whisper + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("openai-transcribe")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openai-translation"), fallbacks: [.provider("qwen-local-translation"), .provider("nllb-local")])
        ]),
        BilingualPipelineProfile(id: "local-whisper-local-translation", displayName: "Local Whisper + Local Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("macos-speech-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("qwen-local-translation"), fallbacks: [.provider("nllb-local")])
        ]),
        BilingualPipelineProfile(id: "hosted-transcribe-hosted-translation", displayName: "Hosted Transcribe + Hosted Translation", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("openai-transcribe"), fallbacks: [.provider("whisper-local")]),
            PipelineStep(capability: .textTranslation, primary: .provider("openai-translation"))
        ])
    ]
}
