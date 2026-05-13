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

    public static let hostedSummaryModelOptions: [ModelOption] = [
        ModelOption(id: "openai/gpt-4.1-mini", displayName: "GPT-4.1 Mini"),
        ModelOption(id: "google/gemini-2.5-flash", displayName: "Gemini 2.5 Flash")
    ]

    public static let builtInProviderDescriptors: [ProviderDescriptor] = [
        ProviderDescriptor(id: "whisper-local", displayName: "Whisper Local", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "macos-speech-local", displayName: "macOS Speech", capability: .audioTranscription, executionMode: .local, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: false, requiresAPIKey: false),
        ProviderDescriptor(id: "openrouter-transcribe", displayName: "OpenRouter Transcribe", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "deepgram-transcribe", displayName: "Deepgram Transcribe", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true),
        ProviderDescriptor(id: "openai-realtime-transcribe", displayName: "OpenAI Realtime Transcription", capability: .audioTranscription, executionMode: .hosted, supportedSourceLocales: ["*"], supportedTargetLocales: [], requiresNetwork: true, requiresAPIKey: true)
    ]

    public static let builtInProfiles: [BilingualPipelineProfile] = [
        BilingualPipelineProfile(id: "deepgram-stt", displayName: "Deepgram Nova-3", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("deepgram-transcribe"), fallbacks: [.provider("whisper-local")])
        ]),
        BilingualPipelineProfile(id: "local-whisper", displayName: "Local Whisper", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("whisper-local"), fallbacks: [.provider("macos-speech-local")])
        ]),
        BilingualPipelineProfile(id: "hosted-transcribe", displayName: "Hosted Transcribe", steps: [
            PipelineStep(capability: .audioTranscription, primary: .provider("openrouter-transcribe"), fallbacks: [.provider("whisper-local")])
        ])
    ]
}
