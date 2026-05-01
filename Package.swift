// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Sift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SiftCore", targets: ["SiftCore"]),
        .executable(name: "sift", targets: ["SiftCLI"]),
        .executable(name: "Sift", targets: ["SiftMenuBar"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git",
                 from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-markdown.git",
                 from: "0.4.0"),
    ],
    targets: [
        .target(
            name: "SiftCore",
            path: "Sources/SiftCore"
        ),
        .executableTarget(
            name: "SiftCLI",
            dependencies: [
                "SiftCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            path: "Sources/SiftCLI",
            resources: [
                .process("Resources"),
            ]
        ),
        .executableTarget(
            name: "SiftMenuBar",
            dependencies: ["SiftCore"],
            path: "Sources/SiftMenuBar"
        ),
    ]
)
