// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniAssistant",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SenaniAssistant", targets: ["SenaniAssistant"])],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SenaniAssistant",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "SenaniAssistantTests", dependencies: ["SenaniAssistant"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
