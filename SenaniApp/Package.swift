// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniApp",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SenaniApp", targets: ["SenaniApp"])
    ],
    dependencies: [
        .package(path: "../Packages/SenaniRules"),
        .package(path: "../Packages/SenaniStore"),
        .package(path: "../Packages/SenaniInference"),
        .package(path: "../Packages/SenaniGmail"),
        .package(path: "../Packages/SenaniVoice"),
        .package(path: "../Packages/SenaniDocs"),
        .package(path: "../Packages/SenaniReplyZero"),
        .package(path: "../Packages/SenaniAnalytics"),
        .package(path: "../Packages/SenaniAssistant"),
        .package(path: "../Packages/SenaniEngine"),
        .package(path: "../Packages/SenaniDesign"),
        .package(path: "../Packages/SenaniModelCatalog"),
        .package(path: "../Packages/SenaniLicensing"),
    ],
    targets: [
        .executableTarget(
            name: "SenaniApp",
            dependencies: [
                "SenaniRules", "SenaniStore", "SenaniInference", "SenaniGmail",
                "SenaniVoice", "SenaniDocs", "SenaniReplyZero", "SenaniAnalytics",
                "SenaniAssistant", "SenaniEngine", "SenaniDesign",
                "SenaniModelCatalog", "SenaniLicensing",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniAppTests",
            dependencies: [
                "SenaniApp", "SenaniLicensing",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
