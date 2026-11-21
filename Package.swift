// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Frames",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "FramesCore", targets: ["FramesCore"]),
        .executable(name: "frames", targets: ["FramesCLI"]),
        .executable(name: "frames-pack", targets: ["FramesPack"]),
    ],
    targets: [
        .target(name: "FramesCore", resources: [.process("Resources")]),
        .executableTarget(name: "FramesCLI", dependencies: ["FramesCore"]),
        .executableTarget(name: "FramesPack"),
        .testTarget(name: "FramesCoreTests", dependencies: ["FramesCore", "FramesCLI"]),
        .testTarget(name: "FramesPackTests", dependencies: ["FramesPack"]),
    ]
)
