// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaConverter",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MediaCore", targets: ["MediaCore"]),
        .executable(name: "MediaConverter", targets: ["MediaConverter"])
    ],
    targets: [
        .target(name: "MediaCore", resources: [.copy("Resources/FFmpeg")]),
        .executableTarget(name: "MediaConverter", dependencies: ["MediaCore"]),
        .testTarget(name: "MediaCoreTests", dependencies: ["MediaCore"], resources: [.copy("Fixtures")])
    ]
)
