// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniRules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniRules", targets: ["SenaniRules"]),
    ],
    targets: [
        .target(name: "SenaniRules"),
        .testTarget(name: "SenaniRulesTests", dependencies: ["SenaniRules"]),
    ]
)
