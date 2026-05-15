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
        .executableTarget(
            name: "ThreadKeep",
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
