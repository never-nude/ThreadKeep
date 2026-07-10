// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ThreadKeep",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThreadKeep", targets: ["ThreadKeep"])
    ],
    dependencies: [
        // The app's sole third-party dependency, deliberately: in-app updates.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
    ],
    targets: [
        // Tiny Objective-C shim so Swift can recover from NSUnarchiver's Obj-C
        // NSException on malformed legacy `attributedBody` archives (SPM has no
        // bridging-header mechanism, so this lives in its own target).
        .target(
            name: "TKArchiveDecode",
            path: "Sources/TKArchiveDecode"
        ),
        .executableTarget(
            name: "ThreadKeep",
            dependencies: [
                "TKArchiveDecode",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ThreadKeep",
            exclude: [
                "Support",
                "Resources/MarkDemo"
            ],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/ThreadKeep/Support/ThreadKeepInfo.plist",
                    // Sparkle.framework is embedded at Contents/Frameworks by
                    // scripts/build-notarized-dmg.sh; the loader needs this rpath.
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "ThreadKeepTests",
            dependencies: ["ThreadKeep"]
        )
    ]
)
