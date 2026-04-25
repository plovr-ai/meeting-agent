import Foundation

@main
struct ProbeMain {
    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())

        if arguments.contains("--list") || arguments.isEmpty {
            print("Running capture targets:")
            for target in RunningProcessDiscovery.currentTargets() {
                let bundle = target.bundleIdentifier ?? "unknown-bundle"
                print("\(target.processID)\t\(target.displayName)\t\(bundle)")
            }
            print("")
            print("Usage: CoreAudioTapProbe --pid <process-id> [--seconds 10] [--wav /tmp/capture.wav]")
            return
        }

        print("Capture arguments accepted later: \(arguments.joined(separator: " "))")
    }
}
