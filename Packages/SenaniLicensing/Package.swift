// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniLicensing",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniLicensing", targets: ["SenaniLicensing"]),
    ],
    targets: [
        .target(name: "SenaniLicensing"),
        .testTarget(name: "SenaniLicensingTests", dependencies: ["SenaniLicensing"]),
    ]
)
