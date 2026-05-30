// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniInference",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniInference", targets: ["SenaniInference"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
    ],
    targets: [
        .target(
            name: "SenaniInference",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
            ]
        ),
        .testTarget(
            name: "SenaniInferenceTests",
            dependencies: ["SenaniInference"]
        ),
    ]
)
