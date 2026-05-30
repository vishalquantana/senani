// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniDocs",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SenaniDocs", targets: ["SenaniDocs"])],
    dependencies: [
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(
            name: "SenaniDocs",
            dependencies: [
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(name: "SenaniDocsTests", dependencies: ["SenaniDocs"], swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
