// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ScreenshotApp",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UshotCore", targets: ["UshotCore"]),
        .executable(name: "UshotApp", targets: ["UshotApp"]),
        .executable(
            name: "AuthenticatedAppcastValidator",
            targets: ["AuthenticatedAppcastValidator"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/isCheneycc/Sparkle",
            exact: "2.9.5-ushot.4"
        )
    ],
    targets: [
        .target(
            name: "UshotCore",
            path: "UshotCore/Sources/UshotCore"
        ),
        .executableTarget(
            name: "UshotApp",
            dependencies: [
                "UshotCore",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "UshotApp",
            exclude: ["Info.plist"],
            sources: ["Sources"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "AuthenticatedAppcastValidator",
            dependencies: ["UshotCore"],
            path: "Tools/AuthenticatedAppcastValidator"
        ),
        .testTarget(
            name: "UshotCoreTests",
            dependencies: ["UshotCore"],
            path: "UshotCore/Tests/UshotCoreTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
