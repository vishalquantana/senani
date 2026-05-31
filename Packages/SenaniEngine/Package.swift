// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniEngine",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniEngine", targets: ["SenaniEngine"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
        .package(path: "../SenaniVoice"),
        .package(path: "../SenaniCalendar"),
    ],
    targets: [
        .target(
            name: "SenaniEngine",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                .product(name: "SenaniVoice", package: "SenaniVoice"),
                .product(name: "SenaniCalendar", package: "SenaniCalendar"),
            ]
        ),
        .testTarget(
            name: "SenaniEngineTests",
            dependencies: ["SenaniEngine"]
        ),
    ]
)
