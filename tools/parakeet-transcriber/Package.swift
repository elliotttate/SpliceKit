// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "parakeet-transcriber",
    platforms: [.macOS(.v14)],
    dependencies: [
        // FluidAudio is pre-1.0, so minor releases carry breaking API changes. The old
        // floating `from: "0.12.0"` resolved to whatever 0.x was latest, silently breaking
        // the build (e.g. 0.13+ replaced AsrManager.transcribe(_:source:) with
        // transcribe(_:decoderState:language:)). Pin to a known-compatible 0.15.x line.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", .upToNextMinor(from: "0.15.6")),
    ],
    targets: [
        .executableTarget(
            name: "parakeet-transcriber",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources"
        ),
    ]
)
