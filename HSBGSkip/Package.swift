// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HSBGSkip",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HSBGSkipKit", targets: ["HSBGSkipKit"])],
    targets: [
        .target(name: "HSBGSkipKit", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "hsbgskipd", dependencies: ["HSBGSkipKit"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "HSBGSkipKitTests", dependencies: ["HSBGSkipKit"]),
    ]
)
