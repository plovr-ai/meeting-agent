// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "MeetingAgentCore", targets: ["MeetingAgentCore"]),
        .executable(name: "MeetingAgentApp", targets: ["MeetingAgentApp"])
    ],
    targets: [
        .target(
            name: "MeetingAgentCore"
        ),
        .executableTarget(
            name: "MeetingAgentApp",
            dependencies: ["MeetingAgentCore"],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "MeetingAgentCoreTests",
            dependencies: ["MeetingAgentCore"],
            exclude: ["Fixtures"]
        )
    ]
)
