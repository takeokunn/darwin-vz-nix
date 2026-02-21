// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "darwin-vz-nix",
    platforms: [.macOS(.v13)],
    dependencies: [
        // Pin to 1.5.x: 1.6+ requires Swift 6.0 (AccessLevelOnImport)
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.5.0"..<"1.6.0"),
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "darwin-vz-nix",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .testTarget(
            name: "darwin-vz-nix-tests",
            dependencies: [
                .target(name: "darwin-vz-nix"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
    ]
)
