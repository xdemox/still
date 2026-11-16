// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "StillSpeech",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "parakeet-helper", targets: ["ParakeetHelper"]),
        .executable(name: "prepare-parakeet", targets: ["PrepareModel"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "16780f04d2ece24f67d0fc00efccd0296491c1a8", traits: []),
    ],
    targets: [
        .executableTarget(name: "ParakeetHelper", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "PrepareModel", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
    ]
)
