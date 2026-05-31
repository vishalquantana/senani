// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniDigest",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniDigest", targets: ["SenaniDigest"]),
        .library(name: "SenaniDigestUI", targets: ["SenaniDigestUI"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniAnalytics"),
        .package(path: "../SenaniDesign"),
    ],
    targets: [
        .target(
            name: "SenaniDigest",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniAnalytics", package: "SenaniAnalytics"),
            ]
        ),
        .target(
            name: "SenaniDigestUI",
            dependencies: [
                "SenaniDigest",
                .product(name: "SenaniDesign", package: "SenaniDesign"),
            ]
        ),
        .testTarget(
            name: "SenaniDigestTests",
            dependencies: [
                "SenaniDigest",
                "SenaniDigestUI",
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniAnalytics", package: "SenaniAnalytics"),
            ]
        ),
    ]
)
