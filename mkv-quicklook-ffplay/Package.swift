// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "mkvql",
    platforms: [.macOS(.v11)],
    products: [
        .executable(name: "mkvql", targets: ["mkvql"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
    ],
    targets: [
        .executableTarget(
            name: "mkvql",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/mkvql",
            resources: [
                // We can embed the embed script etc if needed
            ]
        )
    ]
)
