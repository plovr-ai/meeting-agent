import Foundation
import MeetingAgentCore

@main
struct ProbeMain {
    static func main() async {
        do {
            try await run()
        } catch {
            fputs("\(error)\n", stderr)
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        let options = try ProbeOptions(arguments: Array(CommandLine.arguments.dropFirst()))

        if options.listOnly {
            printTargets()
            return
        }

        guard #available(macOS 14.2, *) else {
            throw ProbeError.coreAudio("Core Audio Process Tap requires macOS 14.2 or later")
        }

        let targets = RunningProcessDiscovery.currentTargets()
        let target: AudioCaptureTarget
        if let pid = options.pid {
            guard let requestedTarget = targets.first(where: { $0.processID == pid }) else {
                throw ProbeError.targetNotFound(pid)
            }
            target = requestedTarget
        } else if let automaticTarget = RunningProcessDiscovery.automaticTarget(from: targets) {
            target = automaticTarget
            log("Auto-selected capture target: \(target.displayName) pid=\(target.processID)")
        } else {
            printTargets(targets)
            throw ProbeError.invalidArguments("No preferred meeting or Google Meet browser process found; pass --pid <process-id> to start capture")
        }

        log("Starting capture for \(target.displayName) pid=\(target.processID)")

        let captureSession = AudioCaptureSession()
        let frameBuffer = captureSession.frameBuffer
        defer {
            captureSession.stop()
        }

        try captureSession.start(target: target)

        log("Capture started target=\(target.displayName)")

        let recordingOutput = try options.wavPath.map {
            try RecordingOutput.defaultOutput(forRequestedWavPath: $0)
        }
        let writer = try recordingOutput.map {
            try WavFileWriter(
                url: $0.wavURL,
                sampleRate: UInt32(captureSession.outputSampleRate.rounded()),
                channelCount: UInt16(captureSession.outputChannelCount)
            )
        }
        let transcriber: AudioFrameTranscriber?
        if let recordingOutput {
            do {
                let speechProvider = SpeechTranscriptionProviderFactory.provider(for: options.speechProvider)
                transcriber = try await speechProvider.start(
                    transcriptURL: recordingOutput.transcriptURL,
                    localeIdentifier: options.speechLocaleIdentifier
                )
                log("Speech recognition provider: \(options.speechProvider.rawValue)")
                log("Speech recognition locale: \(options.speechLocaleIdentifier)")
            } catch {
                let transcriptWriter = try TranscriptFileWriter(url: recordingOutput.transcriptURL)
                try transcriptWriter.replace(with: "Speech recognition unavailable: \(error)")
                try transcriptWriter.close()
                log("Speech recognition unavailable: \(error)")
                transcriber = nil
            }
        } else {
            transcriber = nil
        }

        if let recordingOutput {
            log("Recording audio to \(recordingOutput.wavURL.path)")
            log("Recording transcript to \(recordingOutput.transcriptURL.path)")
        }

        let end = Date().addingTimeInterval(TimeInterval(options.seconds))
        while Date() < end {
            try await Task.sleep(nanoseconds: 250_000_000)
            let frames = frameBuffer.drain()
            if frames.isEmpty {
                log("level=idle frames=0")
                continue
            }

            var totalBytes = 0
            var peak: UInt8 = 0
            for frame in frames {
                totalBytes += frame.pcm.count
                peak = max(peak, frame.pcm.max() ?? 0)
                try writer?.append(frame)
                try transcriber?.append(frame)
            }

            log("level_peak_byte=\(peak) frames=\(frames.count) bytes=\(totalBytes)")
        }

        try writer?.close()
        transcriber?.finish()
        log("Capture stopped")
    }

    private static func printTargets() {
        printTargets(RunningProcessDiscovery.currentTargets())
    }

    private static func printTargets(_ targets: [AudioCaptureTarget]) {
        log("Running capture targets:")
        for target in targets {
            let bundle = target.bundleIdentifier ?? "unknown-bundle"
            log("\(target.processID)\t\(target.displayName)\t\(bundle)")
        }
        log("")
        log("Usage: CoreAudioTapProbe [--pid <process-id>] [--seconds 10] [--wav [capture.wav]] [--stt-provider local|whisper] [--stt-locale en-US]")
        log("When --wav is provided, audio and transcript files are written to .record/")
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }
}
