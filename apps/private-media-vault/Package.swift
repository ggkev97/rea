// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PrivateMediaVault",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "VaultCore", targets: ["VaultCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "5.0.3"),
    ],
    targets: [
        .target(
            name: "VaultCore",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "VaultCoreTests",
            dependencies: ["VaultCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
