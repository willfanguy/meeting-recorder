// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetingRecorder",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "MeetingRecorder",
            path: "Sources",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/Info.plist",
                ]),
            ]
        ),
    ]
)
