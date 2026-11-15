// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenScribe",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "ScreenScribe", targets: ["ScreenScribe"])],
    targets: [
        .target(name: "ScreenScribeCore"),
        .executableTarget(name: "ScreenScribe", dependencies: ["ScreenScribeCore"]),
        .testTarget(name: "ScreenScribeCoreTests", dependencies: ["ScreenScribeCore"])
    ],
    swiftLanguageModes: [.v5]
)
