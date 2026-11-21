// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "picoTranslator",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "picoTranslator"),
        // Headless checks of the text handling (`swift test`): no windows, screenshots or downloads.
        .testTarget(name: "picoTranslatorTests", dependencies: ["picoTranslator"]),
    ]
)
