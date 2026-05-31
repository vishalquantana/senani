// swift-tools-version: 6.0
import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let embeddingGemmaMLXPackagePath = packageDirectory
    .appendingPathComponent("Vendor/EmbeddingGemma-MLX/mlx-swift-examples", isDirectory: true)
    .path
let hasEmbeddingGemmaMLXPackage = FileManager.default.fileExists(
    atPath: "\(embeddingGemmaMLXPackagePath)/Package.swift"
)

var products: [Product] = [
    .library(name: "SenaniInference", targets: ["SenaniInference"]),
]

var dependencies: [Package.Dependency] = [
    .package(path: "../SenaniRules"),
]

var targets: [Target] = [
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

if hasEmbeddingGemmaMLXPackage {
    products.append(
        .library(
            name: "SenaniInferenceEmbeddingGemmaMLX",
            targets: ["SenaniInferenceEmbeddingGemmaMLX"]
        )
    )
    dependencies.append(.package(path: embeddingGemmaMLXPackagePath))
    dependencies.append(
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.29.1"))
    )
    targets.append(
        .target(
            name: "SenaniInferenceEmbeddingGemmaMLX",
            dependencies: [
                "SenaniInference",
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXEmbedders", package: "mlx-swift-examples"),
            ]
        )
    )
    targets.append(
        .testTarget(
            name: "SenaniInferenceEmbeddingGemmaMLXTests",
            dependencies: ["SenaniInferenceEmbeddingGemmaMLX"]
        )
    )
}

let package = Package(
    name: "SenaniInference",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
