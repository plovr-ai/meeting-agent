import Foundation

public struct AccurateTranslationSchedulerConfiguration: Equatable {
    public var timeoutNanoseconds: UInt64
    public var retryCount: Int

    public init(timeoutNanoseconds: UInt64 = 15_000_000_000, retryCount: Int = 1) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.retryCount = max(0, retryCount)
    }
}

public struct AccurateTranslationScheduler {
    private let provider: TextTranslationProvider
    private let configuration: AccurateTranslationSchedulerConfiguration
    private var translatedBlockIDs = Set<String>()
    private var now: () -> Date

    public init(
        provider: TextTranslationProvider,
        configuration: AccurateTranslationSchedulerConfiguration = AccurateTranslationSchedulerConfiguration(),
        now: @escaping () -> Date = Date.init
    ) {
        self.provider = provider
        self.configuration = configuration
        self.now = now
    }

    public mutating func translate(_ blocks: [StableTranslationBlock]) async -> [TranslationResult] {
        var results: [TranslationResult] = []

        for block in blocks where !translatedBlockIDs.contains(block.id) {
            let result = await translate(block)
            if result.displayState == .stableFinal {
                translatedBlockIDs.insert(block.id)
            }
            results.append(result)
        }

        return results
    }

    private func translate(_ block: StableTranslationBlock) async -> TranslationResult {
        var attempts = 0
        while attempts <= configuration.retryCount {
            attempts += 1
            do {
                let transcript = TranscriptDocument(segments: [
                    TranscriptSegment(
                        id: block.id,
                        text: block.sourceText,
                        language: block.laneID.sourceLocale,
                        isFinal: true,
                        createdAt: block.createdAt
                    )
                ])
                let translated = try await provider.translate(
                    transcript: transcript,
                    options: TranslationOptions(sourceLocale: block.laneID.sourceLocale, targetLocale: block.laneID.targetLocale)
                )
                return TranslationResult(
                    id: "\(block.id)-stable-result",
                    sourceID: block.id,
                    laneID: block.laneID,
                    sourceText: block.sourceText,
                    translatedText: translated.segments.first?.targetText ?? "",
                    displayState: .stableFinal,
                    createdAt: now(),
                    sourceCreatedAt: block.createdAt,
                    sourceSegmentIDs: block.sourceSegmentIDs
                )
            } catch where attempts <= configuration.retryCount {
                continue
            } catch {
                return TranslationResult(
                    id: "\(block.id)-stable-failed",
                    sourceID: block.id,
                    laneID: block.laneID,
                    sourceText: block.sourceText,
                    translatedText: "",
                    displayState: .failedRecoverable,
                    createdAt: now(),
                    sourceCreatedAt: block.createdAt,
                    sourceSegmentIDs: block.sourceSegmentIDs
                )
            }
        }

        return TranslationResult(
            id: "\(block.id)-stable-failed",
            sourceID: block.id,
            laneID: block.laneID,
            sourceText: block.sourceText,
            translatedText: "",
            displayState: .failedRecoverable,
            createdAt: now(),
            sourceCreatedAt: block.createdAt,
            sourceSegmentIDs: block.sourceSegmentIDs
        )
    }
}
