// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniDesign",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniDesign", targets: ["SenaniDesign"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
    ],
    targets: [
        .target(
            name: "SenaniDesign",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
            ]
        ),
        .testTarget(
            name: "SenaniDesignTests",
            dependencies: ["SenaniDesign"]
        ),
    ]
)
