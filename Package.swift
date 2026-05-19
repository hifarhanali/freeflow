// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FreeFlow",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "FreeFlow",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit")
            ],
            path: "Sources"
        )
    ]
)
