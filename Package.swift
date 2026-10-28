// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Bubbles",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Bubbles", targets: ["Bubbles"]),
    ],
    targets: [
        // Pure logic: models, storage, parsing, ranking, physics, ladder, settings. No AppKit/SwiftUI.
        .target(name: "BubblesCore"),
        // The built-in speech engine: whisper.cpp's official prebuilt framework (MIT), downloaded into Vendor/
        // by scripts/fetch-whisper.sh (`make check` and `make app` run it).
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        // The menu bar app: windows, views, speech, keychain.
        .executableTarget(
            name: "Bubbles",
            dependencies: ["BubblesCore", "whisper"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(
            name: "BubblesCoreTests",
            dependencies: ["BubblesCore"]
        ),
    ]
)
