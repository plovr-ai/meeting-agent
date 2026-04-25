// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "MeetingAgentCore", targets: ["MeetingAgentCore"]),
        .executable(name: "MeetingAgentApp", targets: ["MeetingAgentApp"]),
        .executable(name: "CoreAudioTapProbe", targets: ["CoreAudioTapProbe"])
    ],
    targets: [
        .target(
            name: "MeetingAgentCore"
        ),
        .executableTarget(
            name: "MeetingAgentApp",
            dependencies: ["MeetingAgentCore"]
        ),
        .executableTarget(
            name: "CoreAudioTapProbe",
            dependencies: ["MeetingAgentCore"],
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CoreAudioTapProbe/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "MeetingAgentCoreTests",
            dependencies: ["MeetingAgentCore"]
        )
    ]
)
