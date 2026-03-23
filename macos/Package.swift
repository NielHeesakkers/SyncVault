// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SyncVault",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "SyncVault",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift"),
            ],
        ),
        .testTarget(
            name: "SyncVaultTests",
            dependencies: ["SyncVault"]
        ),
    ]
)
