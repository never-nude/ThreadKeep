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
            dependencies: ["TKArchiveDecode"],
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
                    "-Xlinker", "Sources/ThreadKeep/Support/ThreadKeepInfo.plist"
                ], .when(platforms: [.macOS]))
            ]
        ),
        .testTarget(
            name: "ThreadKeepTests",
            dependencies: ["ThreadKeep"]
        )
    ]
)
