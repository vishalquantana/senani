// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniReplyZero",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniReplyZero", targets: ["SenaniReplyZero"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SenaniReplyZero",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniReplyZeroTests",
            dependencies: ["SenaniReplyZero"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
