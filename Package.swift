// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WeChatListener",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "WeChatListener", targets: ["WeChatListener"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .executableTarget(
            name: "WeChatListener",
            dependencies: ["CSQLite"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Network"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreImage"),
                .linkedFramework("ImageIO"),
                .linkedFramework("CoreServices"),
            ]
        ),
        .testTarget(name: "WeChatListenerTests", dependencies: ["WeChatListener"]),
        .testTarget(name: "WeChatListenerBenchmarks", dependencies: ["WeChatListener"]),
    ],
    // Preserve the existing concurrency behavior while separating the build and test targets.
    swiftLanguageModes: [.v5]
)
