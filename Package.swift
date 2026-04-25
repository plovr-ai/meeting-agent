// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CoreAudioTapProbe", targets: ["CoreAudioTapProbe"])
    ],
    targets: [
        .executableTarget(
            name: "CoreAudioTapProbe",
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
            name: "CoreAudioTapProbeTests",
            dependencies: ["CoreAudioTapProbe"]
        )
    ]
)
