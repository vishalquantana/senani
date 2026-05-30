// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniGmail",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniGmail", targets: ["SenaniGmail"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
    ],
    targets: [
        .target(
            name: "SenaniGmail",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniGmailTests",
            dependencies: ["SenaniGmail"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
