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
        let diagnosticsTracker = CaptureDiagnosticsTracker(target: target)
        defer {
            captureSession.stop()
        }

        do {
            try captureSession.start(target: target)
        } catch {
            diagnosticsTracker.finish(endedReason: .captureFailed)
            logDiagnostics(diagnosticsTracker.snapshot())
            throw error
        }
        diagnosticsTracker.markRecording(
            sampleRate: captureSession.outputSampleRate,
            channelCount: captureSession.outputChannelCount
        )

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
        let transcriptionFailureIsolator: TranscriptionFailureIsolator?
        if let recordingOutput {
            do {
                let speechProvider = SpeechTranscriptionProviderFactory.provider(for: options.speechProvider)
                let transcriber = try await speechProvider.start(
                    transcriptURL: recordingOutput.transcriptURL,
                    localeIdentifier: options.speechLocaleIdentifier
                )
                transcriptionFailureIsolator = TranscriptionFailureIsolator(
                    transcriber: transcriber,
                    transcriptURL: recordingOutput.transcriptURL
                )
                log("Speech recognition provider: \(options.speechProvider.rawValue)")
                log("Speech recognition locale: \(options.speechLocaleIdentifier)")
            } catch {
                let transcriptWriter = try TranscriptFileWriter(url: recordingOutput.transcriptURL)
                try transcriptWriter.replace(with: "Speech recognition unavailable: \(error)")
                try transcriptWriter.close()
                log("Speech recognition unavailable: \(error)")
                transcriptionFailureIsolator = nil
            }
        } else {
            transcriptionFailureIsolator = nil
        }

        if let recordingOutput {
            log("Recording audio to \(recordingOutput.wavURL.path)")
            log("Recording transcript to \(recordingOutput.transcriptURL.path)")
            log("Recording structured transcript to \(recordingOutput.transcriptJSONURL.path)")
            log("Recording diagnostics to \(recordingOutput.diagnosticsURL.path)")
        }

        let end = Date().addingTimeInterval(TimeInterval(options.seconds))
        let processMonitor = MeetingProcessMonitor()
        var endedReason = CaptureEndedReason.saved
        while Date() < end {
            try await Task.sleep(nanoseconds: 250_000_000)
            let currentTargets = RunningProcessDiscovery.currentTargets()
            let targetProcessEnded = processMonitor.hasProcessEnded(processID: target.processID, in: currentTargets)
            if targetProcessEnded {
                endedReason = .targetProcessEnded
            }
            let bufferBacklog = frameBuffer.count
            let droppedFrameCount = frameBuffer.droppedFrameCount
            let frames = frameBuffer.drain()
            diagnosticsTracker.record(
                frames: frames,
                bufferBacklog: bufferBacklog,
                droppedFrameCount: droppedFrameCount
            )
            if frames.isEmpty {
                log("level=idle frames=0")
                if targetProcessEnded {
                    log("Target process ended: \(target.displayName) pid=\(target.processID)")
                    break
                }
                continue
            }

            var totalBytes = 0
            var peak: UInt8 = 0
            for frame in frames {
                totalBytes += frame.pcm.count
                peak = max(peak, frame.pcm.max() ?? 0)
                try writer?.append(frame)
                if let transcriptionFailure = transcriptionFailureIsolator?.append(frame) {
                    log(transcriptionFailure)
                }
            }

            log("level_peak_byte=\(peak) frames=\(frames.count) bytes=\(totalBytes)")
            if targetProcessEnded {
                log("Target process ended: \(target.displayName) pid=\(target.processID)")
                break
            }
        }

        try writer?.close()
        transcriptionFailureIsolator?.finish()
        diagnosticsTracker.finish(endedReason: endedReason)
        let diagnostics = diagnosticsTracker.snapshot()
        if let recordingOutput {
            try diagnostics.write(to: recordingOutput.diagnosticsURL)
        }
        logDiagnostics(diagnostics)
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

    private static func logDiagnostics(_ diagnostics: CaptureDiagnostics) {
        log(
            "diagnostics status=\(diagnostics.status.rawValue) " +
                "framesCaptured=\(diagnostics.framesCaptured) " +
                "durationSeconds=\(String(format: "%.3f", diagnostics.durationSeconds)) " +
                "averageLevel=\(String(format: "%.4f", diagnostics.averageLevel)) " +
                "peakLevel=\(String(format: "%.4f", diagnostics.peakLevel)) " +
                "droppedFrameCount=\(diagnostics.droppedFrameCount)"
        )
    }
}
