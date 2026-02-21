// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "darwin-vz-nix",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.5.0"..<"1.6.0"),
        // Required: built-in Testing module has cross-import overlay issues
        // with CommandLineTools-only (no Xcode) setups.
        .package(url: "https://github.com/apple/swift-testing.git", from: "0.12.0"),
    ],
    targets: [
        .target(
            name: "DarwinVZNixLib",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "darwin-vz-nix",
            dependencies: [
                "DarwinVZNixLib",
            ]
        ),
        .testTarget(
            name: "darwin-vz-nix-tests",
            dependencies: [
                .target(name: "DarwinVZNixLib"),
                .product(name: "Testing", package: "swift-testing"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
