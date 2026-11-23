// swift-tools-version: 5.9
import PackageDescription

var targets: [Target] = [
    .target(
        name: "MiVoiceCore",
        path: "Sources/MiVoiceCore"
    ),
    .testTarget(
        name: "MiVoiceCoreTests",
        dependencies: ["MiVoiceCore"],
        path: "Tests/MiVoiceCoreTests"
    ),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "MiVoice",
        dependencies: ["MiVoiceCore"],
        path: "Sources/MiVoice"
    )
)
#endif

var package = Package(
    name: "MiVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MiVoiceCore", targets: ["MiVoiceCore"]),
    ],
    targets: targets
)

#if os(macOS)
package.products.append(.executable(name: "MiVoice", targets: ["MiVoice"]))
#endif
