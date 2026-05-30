// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniStore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniStore", targets: ["SenaniStore"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SenaniStore",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "SenaniStoreTests",
            dependencies: ["SenaniStore"]
        ),
    ]
)
