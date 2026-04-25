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

    public func append(_ frame: AudioFrame) throws {
        guard let transcriber else { return }

        do {
            try transcriber.append(frame)
        } catch {
            transcriber.finish()
            try TranscriptFileWriter(url: transcriptURL).replace(with: "Speech recognition failed: \(error)")
            self.transcriber = nil
        }
    }

    public func finish() {
        transcriber?.finish()
        transcriber = nil
    }
}
