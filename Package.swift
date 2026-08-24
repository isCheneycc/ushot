// swift-tools-version: 6.0

import PackageDescription

// The macOS 26 SDK declares two ScreenCaptureKit classes without attaching
// availability to their Objective-C interface declarations. Keep every
// SwiftPM-linked host weak so package tests and command-line products can still
// launch on the package's supported macOS 14/15 deployment targets.
let screenCaptureKitWeakLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xlinker", "-weak_framework", "-Xlinker", "ScreenCaptureKit"],
        .when(platforms: [.macOS])
    )
]

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
            path: "UshotCore/Sources/UshotCore",
            linkerSettings: screenCaptureKitWeakLinkerSettings
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
