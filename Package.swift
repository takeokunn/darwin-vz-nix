// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "darwin-vz-nix",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "darwin-vz-nix", targets: ["darwin-vz-nix"]),
        .library(name: "DarwinVZNixLib", targets: ["DarwinVZNixLib"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", "1.5.0"..<"2.0.0"),
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
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
