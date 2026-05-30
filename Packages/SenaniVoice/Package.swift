// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniVoice",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SenaniVoice", targets: ["SenaniVoice"])],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SenaniVoice",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "SenaniVoiceTests", dependencies: ["SenaniVoice"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
