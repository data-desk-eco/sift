// swift-tools-version: 6.0
// Tools-version 6 lets SPM link the bundled `Testing` framework so
// tests run on Command Line Tools alone — no Xcode install required.
// We pin the language mode to Swift 5 so strict concurrency stays
// opt-in: the codebase predates it and the migration is a separate
// project from "make tests work without Xcode".
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .executable(name: "sift", targets: ["SiftCLI"]),
        .executable(name: "sift-menubar", targets: ["SiftMenuBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git",
                 from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-markdown.git",
                 from: "0.4.0"),
        // Pinned to the SPM package (rather than the toolchain-bundled
        // copy) so tests build on Command Line Tools alone — some CLT
        // releases ship a broken `_Testing_Foundation` cross-import
        // overlay (no Modules/), and the SPM dep brings its own. We
        // pin to 0.12.0 — the last release before the dep was marked
        // deprecated in favour of the bundled copy. Once every supported
        // CLT/Xcode ships the bundled module correctly, drop this dep.
        .package(url: "https://github.com/swiftlang/swift-testing.git",
                 exact: "0.12.0"),
    ],
    targets: [
        .target(
            name: "SiftCore",
            dependencies: [
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/SiftCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SiftCLI",
            dependencies: [
                "SiftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/SiftCLI",
            resources: [
                // .copy preserves the `sift/SKILL.md` subdirectory layout
                // pi requires (the --skill dir name must match the skill name).
                .copy("Resources"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SiftMenuBar",
            dependencies: ["SiftCore"],
            path: "Sources/SiftMenuBar",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SiftCoreTests",
            dependencies: [
                "SiftCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "Tests/SiftCoreTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
