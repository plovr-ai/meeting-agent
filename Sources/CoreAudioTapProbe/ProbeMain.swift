import Foundation

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

        guard let pid = options.pid else {
            printTargets()
            throw ProbeError.invalidArguments("Pass --pid <process-id> to start capture")
        }

        guard let target = RunningProcessDiscovery.currentTargets().first(where: { $0.processID == pid }) else {
            throw ProbeError.targetNotFound(pid)
        }

        log("Starting capture for \(target.displayName) pid=\(target.processID)")

        let tapManager = AudioTapManager()
        let aggregateManager = AggregateDeviceManager()
        let frameBuffer = AudioFrameRingBuffer(capacity: 512)
        let reader = AudioIOReader(frameBuffer: frameBuffer)
        defer {
            reader.stop()
            aggregateManager.destroyAggregateDevice()
            tapManager.destroyTap()
        }

        let tapID = try tapManager.createTap(for: target)
        let tapUID = try tapManager.tapUID()
        let aggregateID = try aggregateManager.createAggregateDevice(named: "MeetingAgent Probe Aggregate", tapUID: tapUID)
        try reader.start(deviceID: aggregateID)

        log("Capture started tapID=\(tapID) aggregateID=\(aggregateID) tappedProcesses=\(tapManager.tappedProcessCount)")

        let writer = try options.wavPath.map {
            try WavFileWriter(
                url: URL(fileURLWithPath: $0),
                sampleRate: UInt32(reader.outputSampleRate.rounded()),
                channelCount: UInt16(reader.outputChannelCount)
            )
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
            }

            log("level_peak_byte=\(peak) frames=\(frames.count) bytes=\(totalBytes)")
        }

        try writer?.close()
        log("Capture stopped")
    }

    private static func printTargets() {
        log("Running capture targets:")
        for target in RunningProcessDiscovery.currentTargets() {
            let bundle = target.bundleIdentifier ?? "unknown-bundle"
            log("\(target.processID)\t\(target.displayName)\t\(bundle)")
        }
        log("")
        log("Usage: CoreAudioTapProbe --pid <process-id> [--seconds 10] [--wav /tmp/capture.wav]")
    }

    private static func log(_ message: String) {
        print(message)
        fflush(stdout)
    }
}

struct ProbeOptions {
    let listOnly: Bool
    let pid: pid_t?
    let seconds: Int
    let wavPath: String?

    init(arguments: [String]) throws {
        listOnly = arguments.isEmpty || arguments.contains("--list")

        var parsedPID: pid_t?
        var parsedSeconds = 10
        var parsedWavPath: String?

        var index = 0
        while index < arguments.count {
            let arg = arguments[index]
            switch arg {
            case "--list":
                index += 1
            case "--pid":
                guard index + 1 < arguments.count, let value = Int32(arguments[index + 1]) else {
                    throw ProbeError.invalidArguments("--pid requires an integer process id")
                }
                parsedPID = value
                index += 2
            case "--seconds":
                guard index + 1 < arguments.count, let value = Int(arguments[index + 1]), value > 0 else {
                    throw ProbeError.invalidArguments("--seconds requires a positive integer")
                }
                parsedSeconds = value
                index += 2
            case "--wav":
                guard index + 1 < arguments.count else {
                    throw ProbeError.invalidArguments("--wav requires a file path")
                }
                parsedWavPath = arguments[index + 1]
                index += 2
            default:
                throw ProbeError.invalidArguments("Unknown argument \(arg)")
            }
        }

        pid = parsedPID
        seconds = parsedSeconds
        wavPath = parsedWavPath
    }
}
