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

var products: [Product] = [
    .library(name: "MiVoiceCore", targets: ["MiVoiceCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "MiVoice",
        dependencies: ["MiVoiceCore"],
        path: "Sources/MiVoice"
    )
)
products.append(.executable(name: "MiVoice", targets: ["MiVoice"]))
#endif

let package = Package(
    name: "MiVoice",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
