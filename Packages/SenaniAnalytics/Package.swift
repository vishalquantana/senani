// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniAnalytics",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniAnalytics", targets: ["SenaniAnalytics"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SenaniAnalytics",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniAnalyticsTests",
            dependencies: ["SenaniAnalytics"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
