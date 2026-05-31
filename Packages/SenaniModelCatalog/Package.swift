// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniModelCatalog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniModelCatalog", targets: ["SenaniModelCatalog"]),
    ],
    targets: [
        .target(
            name: "SenaniModelCatalog",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniModelCatalogTests",
            dependencies: ["SenaniModelCatalog"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
