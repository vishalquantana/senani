import Foundation

/// Fetches and filters the live `mlx-community` Gemma 4-bit model list from Hugging Face.
public struct ModelCatalog: Sendable {
    private let http: CatalogHTTPClient

    public init(http: CatalogHTTPClient) { self.http = http }

    /// HF Hub models API, scoped to mlx-community + gemma, with sibling file details.
    public static let endpoint = URL(string:
        "https://huggingface.co/api/models?author=mlx-community&search=gemma&full=true")!

    public func fetch() async throws -> [ModelInfo] {
        let data = try await http.get(Self.endpoint)
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [ModelInfo] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CatalogError.malformedResponse
        }
        var models: [ModelInfo] = []
        for entry in array {
            guard let id = entry["id"] as? String else { continue }
            let lower = id.lowercased()
            guard lower.contains("gemma"), lower.contains("4bit") else { continue }
            let siblings = (entry["siblings"] as? [[String: Any]]) ?? []
            var files: [String] = []
            var total: Int64 = 0
            var sawSize = false
            for sibling in siblings {
                if let name = sibling["rfilename"] as? String { files.append(name) }
                if let size = sibling["size"] as? Int64 { total += size; sawSize = true }
                else if let size = sibling["size"] as? Int { total += Int64(size); sawSize = true }
            }
            models.append(ModelInfo(id: id, sizeBytes: sawSize ? total : nil, files: files))
        }
        return models
    }
}

/// The picker payload: models that fit a tier (smallest first) + the suggested default.
public struct RecommendationResult: Sendable, Equatable {
    public let tier: RAMTier
    public let models: [ModelInfo]
    public let suggestedDefault: ModelInfo?
    public init(tier: RAMTier, models: [ModelInfo], suggestedDefault: ModelInfo?) {
        self.tier = tier
        self.models = models
        self.suggestedDefault = suggestedDefault
    }
}

extension ModelCatalog {
    /// Pure RAM-tier policy (see plan \"RAM-tier policy\" table). No I/O.
    public static func recommend(from models: [ModelInfo], tier: RAMTier) -> RecommendationResult {
        let fitting = models.filter { model in
            if let size = model.sizeBytes { return size <= tier.maxModelBytes }
            return tier == .gb32          // unknown size only offered to the biggest tier
        }
        let sorted = fitting.sorted { lhs, rhs in
            switch (lhs.sizeBytes, rhs.sizeBytes) {
            case let (l?, r?): return l < r
            case (nil, _?): return false   // nil sorts last
            case (_?, nil): return true
            case (nil, nil): return lhs.id < rhs.id
            }
        }
        let preferred = sorted.first { $0.id == tier.defaultModelId }
        let suggested = preferred ?? sorted.first
        return RecommendationResult(tier: tier, models: sorted, suggestedDefault: suggested)
    }

    /// Fetch + recommend for the host tier in one call.
    public func recommended(tier: RAMTier = .detectHost()) async throws -> RecommendationResult {
        let models = try await fetch()
        return Self.recommend(from: models, tier: tier)
    }
}
