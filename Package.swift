// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MemoryTool",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "MemoryCore", targets: ["MemoryCore"]),
        .executable(name: "MemoryToolApp", targets: ["MemoryToolApp"]),
        .executable(name: "MemoryMCP", targets: ["MemoryMCP"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
        .package(url: "https://github.com/jkrukowski/swift-embeddings", from: "0.0.26"),
    ],
    targets: [
        // MARK: - Libraries
        .target(
            name: "MemoryCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Embeddings", package: "swift-embeddings"),
            ]
        ),

        // MARK: - Executables
        .executableTarget(
            name: "MemoryToolApp",
            dependencies: [
                "MemoryCore",
            ],
            resources: [
                .process("Assets.xcassets"),
            ]
        ),
        .executableTarget(
            name: "MemoryMCP",
            dependencies: [
                "MemoryCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // MARK: - Tests
        .testTarget(
            name: "MemoryCoreTests",
            dependencies: ["MemoryCore"]
        ),
        .testTarget(
            name: "MemoryMCPTests",
            dependencies: [
                "MemoryCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ]
)
