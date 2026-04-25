import Foundation

public final class TranscriptionFailureIsolator {
    private var transcriber: AudioFrameTranscriber?
    private let transcriptURL: URL

    public var isActive: Bool {
        transcriber != nil
    }

    public var failureReason: String? {
        transcriber?.failureReason
    }

    public init(transcriber: AudioFrameTranscriber?, transcriptURL: URL) {
        self.transcriber = transcriber
        self.transcriptURL = transcriptURL
    }

    @discardableResult
    public func append(_ frame: AudioFrame) -> String? {
        guard let transcriber else { return nil }

        do {
            try transcriber.append(frame)
            return nil
        } catch {
            let message = "Speech recognition failed: \(error)"
            transcriber.finish()
            self.transcriber = nil
            try? TranscriptFileWriter(url: transcriptURL).replace(with: message)
            return message
        }
    }

    public func finish() {
        transcriber?.finish()
        transcriber = nil
    }
}
