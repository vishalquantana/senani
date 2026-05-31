// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniCalendar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniCalendar", targets: ["SenaniCalendar"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniGmail"),
    ],
    targets: [
        .target(
            name: "SenaniCalendar",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniGmail", package: "SenaniGmail"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniCalendarTests",
            dependencies: ["SenaniCalendar"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
