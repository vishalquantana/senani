# MLX Model Picker + Downloader Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Phase-0 "model running" slice: a `ModelCatalog` that fetches the live `mlx-community` Gemma 4-bit list from Hugging Face and recommends variants by the host's RAM tier (8 / 16 / 32 GB+), a resumable/idempotent `ModelDownloader` that caches weights under Application Support with progress, a SwiftUI picker screen, and the composition-root glue that constructs `MLXTextGenerator` from local weights and installs it as `AppEnvironment.generator` (replacing a `NotReadyTextGenerator` stub), persisting the chosen model id so it auto-loads next launch.

**Architecture:** A new pure/testable Swift package `Packages/SenaniModelCatalog` holds all logic behind protocol seams — `CatalogHTTPClient`, `ModelDownloading`, `ModelChoiceStore`, `GeneratorInstalling` — so every unit test runs with a fake HTTP client (canned HF JSON), a fake downloader (writes a dummy file), `UserDefaults(suiteName:)`, and a spy installer. NO real MLX, NO real HF network, NO multi-GB downloads in tests. The app target (`SenaniApp`) owns the composition root: it defines `AppEnvironment` with `generator: any TextGenerator` starting as `NotReadyTextGenerator`, the SwiftUI `ModelPickerView`, and the only `import SenaniInference` line that constructs `MLXTextGenerator(modelPath:)` — gated behind a host-only `MLXGeneratorInstaller` so the catalog package and its tests never link MLX.

**Tech Stack:** Swift 6.2 (strict concurrency, `swift-tools-version: 6.0`), Swift Package Manager, Swift Testing (`import Testing`), Foundation `URLSession`/`URLRequest`, SwiftUI (app target only), macOS 14. Real inference path: `SenaniInference.MLXTextGenerator` (Apple Silicon, host-only).

**Working directory:** Unless a step says otherwise, `swift` commands for the package run from `/Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog/`; app build commands run from `/Users/vishalkumar/Downloads/qmail/SenaniApp/`.

**Source docs:** Implements ROADMAP Phase 0 bullet "`mlx-swift` + Gemma loading, in-app model picker (by hardware)" and ARCHITECTURE "Local model strategy" (catalog reads live `mlx-community`, offers variants by RAM tier, weights download from HF and cache locally). Honors `2026-05-31-APP-PLANS-RECONCILIATION.md` §2 (real `SenaniInference` signatures), §3 (composition root owns `generator: any TextGenerator`, starts as a NotReady stub), §4 (composition root only; one safety path; live/preview parity; macOS 14 / Swift 6.2 / Swift Testing; TDD + frequent commits), and §5 (MLX/Gemma pin is an open item for the human).

**Out of scope (separate plans):** the full `AppEnvironment.live()` graph (Orchestrator/Scheduler/Gmail) — this plan adds ONLY the `generator`-related surface to the composition root and leaves the rest to the app-shell plan; the real `MLXTextGenerator` runtime behavior (gemma-inference-mlx plan owns it); the gold-glass DesignSystem polish (this screen uses plain SwiftUI controls the design-system plan can restyle later).

---

## Cross-package assumptions (real signatures — state to the human before coding)

This package + the app glue compile against contracts that already exist. Pin them; do not re-guess. Verified from source on 2026-05-31.

- **`SenaniInference` (frozen protocol; package under ACTIVE concurrent development — pin ONLY these):**
  ```swift
  public enum InferenceError: Error, Sendable, Equatable { case modelNotLoaded; case generationFailed(String); case decodingFailed(String) }
  public protocol TextGenerator: Sendable {
      func generate(prompt: String, maxTokens: Int) async throws -> String
      func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
  }
  public final class MLXTextGenerator: TextGenerator, @unchecked Sendable {
      public init(modelPath: String)        // ← weights-already-on-disk; the ONLY constructor we use
  }
  public indirect enum JSONSchema: Sendable, Equatable { /* .object(properties:required:) etc; init(json:) */ }
  ```
  **Do NOT** depend on any other `SenaniInference` type (an embedding-Gemma path is in flight). The catalog package does **not** import `SenaniInference` at all; only the app target does, in one file (`MLXGeneratorInstaller.swift`).

- **App scaffold (exists, NOT greenfield):** `SenaniApp/Package.swift` is a swift-tools 5.9 executable, macOS 14, already depending on all nine engine packages via `path:`. Current `SenaniApp.swift` defines an `@Observable final class AppState`. This plan **adds** a `path:` dep on `../Packages/SenaniModelCatalog`, introduces `AppEnvironment` (the §3 composition root, but with ONLY the generator-related members in this plan), and adds the picker UI. It does not delete `AppState`; `AppEnvironment` is additive and the picker wires through it.

- **`Foundation` `URLSession`:** the live `CatalogHTTPClient` uses `URLSession.shared.data(for:)`; the live downloader uses `URLSession.downloadTask`/`bytes(for:)`. Tests never touch the network.

---

## RAM-tier policy (single source of truth — used by Task 4 and the tests)

Detect physical RAM via `ProcessInfo.processInfo.physicalMemory` (bytes). Map to a tier, then recommend models whose estimated resident size leaves headroom:

| Tier | Physical RAM | Recommended max model on-disk size | Default model id |
|------|--------------|------------------------------------|------------------|
| `.gb8`  | `< 12 GiB`            | ≤ 3.0 GB  | `mlx-community/gemma-3-1b-it-4bit` |
| `.gb16` | `>= 12 and < 24 GiB` | ≤ 7.0 GB  | `mlx-community/gemma-3-4b-it-4bit` |
| `.gb32` | `>= 24 GiB`          | ≤ 20.0 GB | `mlx-community/gemma-3-12b-it-4bit` |

Rules (pure function `RAMTier.recommended(from:tier:)`):
1. Keep only models whose `sizeBytes <= tier.maxModelBytes`.
2. A model with **unknown** size (`sizeBytes == nil`) is included only for `.gb32` (assume large machine can try it).
3. Sort ascending by `sizeBytes` (nil sorts last), so the smallest fitting model is first ("recommended default").
4. `tier.defaultModelId` is returned as `RecommendationResult.suggestedDefault` IF present in the filtered list, else the first filtered model, else `nil`.

(1 GiB = 1024³ bytes; 1 GB on-disk size reported by HF is decimal 1000³ — keep sizes in raw bytes everywhere and only format for display.)

---

## File Structure

```
Packages/SenaniModelCatalog/
  Package.swift
  Sources/SenaniModelCatalog/
    RAMTier.swift              # RAMTier enum + detect(physicalMemory:) + maxModelBytes/defaultModelId + recommended(from:tier:)
    ModelInfo.swift            # ModelInfo (id, sizeBytes?, downloadURL, files) + ByteFormatter helper
    CatalogHTTPClient.swift    # CatalogHTTPClient protocol + URLSessionCatalogClient (live) + CatalogError
    ModelCatalog.swift         # ModelCatalog: fetch(...) -> [ModelInfo] (parse HF JSON) + recommend(...) -> RecommendationResult
    ModelDownloading.swift     # ModelDownloading protocol + DownloadProgress + DownloadError
    FileModelDownloader.swift  # FileModelDownloader: caches under a base dir; idempotent; resumable; reports progress
    ModelChoiceStore.swift     # ModelChoiceStore protocol + UserDefaultsModelChoiceStore (persist chosen model id + local path)
    GeneratorInstalling.swift  # GeneratorInstalling protocol (the seam the composition root implements)
    ModelManager.swift         # orchestrates: choose -> (download if needed) -> install -> persist ; loadPersistedOnLaunch()
  Tests/SenaniModelCatalogTests/
    RAMTierTests.swift
    ModelCatalogParseTests.swift
    ModelCatalogRecommendTests.swift
    FileModelDownloaderTests.swift
    ModelChoiceStoreTests.swift
    ModelManagerTests.swift
    TestSupport.swift          # FakeCatalogHTTPClient, FakeDownloader, SpyInstaller, canned HF JSON, temp-dir helper

SenaniApp/
  Package.swift                                  # MODIFIED: add path dep + product
  Sources/SenaniApp/
    Inference/NotReadyTextGenerator.swift        # NEW: TextGenerator stub used until a model is chosen
    Inference/MLXGeneratorInstaller.swift        # NEW: the ONLY file importing SenaniInference to build MLXTextGenerator
    AppEnvironment.swift                         # NEW: @MainActor composition root holding `generator` + ModelManager
    UI/ModelPickerView.swift                     # NEW: SwiftUI picker screen
```

Each file has one responsibility. The catalog package depends on nothing but `Foundation`. The app target is the only place MLX/SwiftUI live.

---

## Task 1: Package scaffold + RAMTier detection

**Files:**
- Create: `Packages/SenaniModelCatalog/Package.swift`
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/RAMTier.swift`
- Test: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/RAMTierTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/RAMTierTests.swift`:

```swift
import Testing
@testable import SenaniModelCatalog

private let giB: UInt64 = 1024 * 1024 * 1024

@Test func detectsEightGigTier() {
    #expect(RAMTier.detect(physicalMemory: 8 * giB) == .gb8)
    #expect(RAMTier.detect(physicalMemory: 11 * giB) == .gb8)
}

@Test func detectsSixteenGigTier() {
    #expect(RAMTier.detect(physicalMemory: 16 * giB) == .gb16)
    #expect(RAMTier.detect(physicalMemory: 12 * giB) == .gb16)
    #expect(RAMTier.detect(physicalMemory: 23 * giB) == .gb16)
}

@Test func detectsThirtyTwoGigTier() {
    #expect(RAMTier.detect(physicalMemory: 24 * giB) == .gb32)
    #expect(RAMTier.detect(physicalMemory: 64 * giB) == .gb32)
}

@Test func tierExposesBudgetAndDefault() {
    #expect(RAMTier.gb8.maxModelBytes == 3_000_000_000)
    #expect(RAMTier.gb16.maxModelBytes == 7_000_000_000)
    #expect(RAMTier.gb32.maxModelBytes == 20_000_000_000)
    #expect(RAMTier.gb8.defaultModelId == "mlx-community/gemma-3-1b-it-4bit")
    #expect(RAMTier.gb16.defaultModelId == "mlx-community/gemma-3-4b-it-4bit")
    #expect(RAMTier.gb32.defaultModelId == "mlx-community/gemma-3-12b-it-4bit")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test`
Expected: FAIL — no `Package.swift` / no `SenaniModelCatalog` module ("manifest not found" / "no such module").

- [ ] **Step 3: Create the manifest**

Create `Packages/SenaniModelCatalog/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniModelCatalog",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniModelCatalog", targets: ["SenaniModelCatalog"]),
    ],
    targets: [
        .target(
            name: "SenaniModelCatalog",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SenaniModelCatalogTests",
            dependencies: ["SenaniModelCatalog"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```

- [ ] **Step 4: Implement `RAMTier`**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/RAMTier.swift`:

```swift
import Foundation

/// Host RAM tier used to recommend Gemma 4-bit variants (ARCHITECTURE "Local model strategy").
public enum RAMTier: String, Sendable, CaseIterable, Equatable {
    case gb8
    case gb16
    case gb32

    private static let giB: UInt64 = 1024 * 1024 * 1024

    /// Detect the tier from `ProcessInfo.processInfo.physicalMemory` (bytes).
    public static func detect(physicalMemory: UInt64) -> RAMTier {
        if physicalMemory < 12 * giB { return .gb8 }
        if physicalMemory < 24 * giB { return .gb16 }
        return .gb32
    }

    /// Convenience for the live host.
    public static func detectHost() -> RAMTier {
        detect(physicalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    /// Largest on-disk model size (bytes) we recommend for this tier.
    public var maxModelBytes: Int64 {
        switch self {
        case .gb8: return 3_000_000_000
        case .gb16: return 7_000_000_000
        case .gb32: return 20_000_000_000
        }
    }

    /// The preferred default model id for this tier.
    public var defaultModelId: String {
        switch self {
        case .gb8: return "mlx-community/gemma-3-1b-it-4bit"
        case .gb16: return "mlx-community/gemma-3-4b-it-4bit"
        case .gb32: return "mlx-community/gemma-3-12b-it-4bit"
        }
    }

    public var displayName: String {
        switch self {
        case .gb8: return "8 GB"
        case .gb16: return "16 GB"
        case .gb32: return "32 GB+"
        }
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test`
Expected: PASS — 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: scaffold package + RAMTier detection by physical memory

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

Use this exact commit trailer on EVERY commit in this plan.

---

## Task 2: ModelInfo value type + byte formatting

**Files:**
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelInfo.swift`
- Test: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelCatalogParseTests.swift` (construction-only test here; parsing added in Task 3)

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelCatalogParseTests.swift`:

```swift
import Testing
@testable import SenaniModelCatalog

@Test func modelInfoHoldsIdSizeAndFiles() {
    let m = ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit",
                      sizeBytes: 2_400_000_000,
                      files: ["config.json", "model.safetensors"])
    #expect(m.id == "mlx-community/gemma-3-4b-it-4bit")
    #expect(m.sizeBytes == 2_400_000_000)
    #expect(m.files.contains("model.safetensors"))
    #expect(m.shortName == "gemma-3-4b-it-4bit")
}

@Test func formatsBytesForDisplay() {
    #expect(ModelInfo.formatBytes(2_400_000_000).contains("2.4"))
    #expect(ModelInfo.formatBytes(nil) == "unknown size")
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelCatalogParseTests`
Expected: FAIL — `ModelInfo` undefined.

- [ ] **Step 3: Implement `ModelInfo`**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelInfo.swift`:

```swift
import Foundation

/// One Hugging Face `mlx-community` Gemma model the picker can offer.
public struct ModelInfo: Sendable, Equatable, Identifiable {
    public let id: String                 // full HF repo id, e.g. "mlx-community/gemma-3-4b-it-4bit"
    public let sizeBytes: Int64?          // total on-disk size; nil if HF did not report it
    public let files: [String]            // sibling file names to download

    public init(id: String, sizeBytes: Int64?, files: [String]) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.files = files
    }

    /// Repo id without the "mlx-community/" owner prefix.
    public var shortName: String {
        id.split(separator: "/").last.map(String.init) ?? id
    }

    /// Human-readable size for the picker UI.
    public static func formatBytes(_ bytes: Int64?) -> String {
        guard let bytes else { return "unknown size" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB]
        fmt.countStyle = .decimal
        return fmt.string(fromByteCount: bytes)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelCatalogParseTests`
Expected: PASS. (If `ByteCountFormatter` localizes the decimal separator and the `"2.4"` substring check fails on a non-`.` locale, the CI host is `en_US`; keep the assertion — it documents the expected format.)

- [ ] **Step 5: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: ModelInfo value type + byte formatting

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 3: CatalogHTTPClient seam + ModelCatalog.fetch (parse HF JSON)

**Files:**
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/CatalogHTTPClient.swift`
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelCatalog.swift`
- Create: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/TestSupport.swift`
- Test: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelCatalogParseTests.swift` (extend)

The live catalog calls the HF Hub models API: `GET https://huggingface.co/api/models?author=mlx-community&search=gemma&full=true`. Each element looks like:
```json
{ "id": "mlx-community/gemma-3-4b-it-4bit",
  "siblings": [ { "rfilename": "model.safetensors", "size": 2400000000 },
                { "rfilename": "config.json", "size": 1200 } ] }
```
`sizeBytes` is the sum of sibling `size` fields (nil if no sibling reports a size). We additionally filter to ids that look like Gemma 4-bit (`contains "gemma"` AND `contains "4bit"`), case-insensitive.

- [ ] **Step 1: Write the failing test (add to ModelCatalogParseTests.swift)**

Append to `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelCatalogParseTests.swift`:

```swift
import Foundation

@Test func parsesHuggingFaceListSummingSiblingSizes() async throws {
    let client = FakeCatalogHTTPClient(cannedJSON: CannedHF.gemmaList)
    let catalog = ModelCatalog(http: client)
    let models = try await catalog.fetch()
    // CannedHF.gemmaList has 3 gemma-4bit repos + 1 non-gemma repo that must be filtered out.
    #expect(models.count == 3)
    let m4b = try #require(models.first { $0.id == "mlx-community/gemma-3-4b-it-4bit" })
    #expect(m4b.sizeBytes == 2_400_001_200)         // 2_400_000_000 + 1_200
    #expect(m4b.files.contains("model.safetensors"))
    #expect(models.allSatisfy { $0.id.lowercased().contains("gemma") })
    #expect(models.allSatisfy { $0.id.lowercased().contains("4bit") })
}

@Test func missingSiblingSizesYieldNilSize() async throws {
    let client = FakeCatalogHTTPClient(cannedJSON: CannedHF.noSizes)
    let catalog = ModelCatalog(http: client)
    let models = try await catalog.fetch()
    #expect(models.count == 1)
    #expect(models[0].sizeBytes == nil)
}

@Test func malformedJSONThrowsCatalogError() async {
    let client = FakeCatalogHTTPClient(cannedJSON: "{ not json")
    let catalog = ModelCatalog(http: client)
    await #expect(throws: CatalogError.self) { _ = try await catalog.fetch() }
}

@Test func httpFailurePropagatesAsCatalogError() async {
    let client = FakeCatalogHTTPClient(error: CatalogError.network("offline"))
    let catalog = ModelCatalog(http: client)
    await #expect(throws: CatalogError.self) { _ = try await catalog.fetch() }
}
```

- [ ] **Step 2: Create TestSupport with the fake client + canned JSON**

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/TestSupport.swift`:

```swift
import Foundation
@testable import SenaniModelCatalog

/// HTTP client double: returns canned bytes or throws a canned error. NEVER touches the network.
final class FakeCatalogHTTPClient: CatalogHTTPClient, @unchecked Sendable {
    let data: Data?
    let error: Error?
    private(set) var requestedURLs: [URL] = []

    init(cannedJSON: String) { self.data = Data(cannedJSON.utf8); self.error = nil }
    init(error: Error) { self.data = nil; self.error = error }

    func get(_ url: URL) async throws -> Data {
        requestedURLs.append(url)
        if let error { throw error }
        return data ?? Data()
    }
}

enum CannedHF {
    /// 3 gemma-4bit repos + 1 unrelated repo (must be filtered out by ModelCatalog.fetch).
    static let gemmaList = """
    [
      { "id": "mlx-community/gemma-3-1b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 800000000 },
                      { "rfilename": "config.json", "size": 900 },
                      { "rfilename": "tokenizer.json", "size": 100 } ] },
      { "id": "mlx-community/gemma-3-4b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 2400000000 },
                      { "rfilename": "config.json", "size": 1200 } ] },
      { "id": "mlx-community/gemma-3-12b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 7000000000 } ] },
      { "id": "mlx-community/Qwen2.5-7B-Instruct-4bit",
        "siblings": [ { "rfilename": "model.safetensors", "size": 4000000000 } ] }
    ]
    """

    /// One gemma-4bit repo whose siblings report no size.
    static let noSizes = """
    [
      { "id": "mlx-community/gemma-3-4b-it-4bit",
        "siblings": [ { "rfilename": "model.safetensors" },
                      { "rfilename": "config.json" } ] }
    ]
    """
}

/// Create a fresh temporary directory and return its URL; caller removes it.
func makeTempDir() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("senani-catalog-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelCatalogParseTests`
Expected: FAIL — `CatalogHTTPClient`, `ModelCatalog`, `CatalogError` undefined.

- [ ] **Step 4: Implement the HTTP seam**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/CatalogHTTPClient.swift`:

```swift
import Foundation

public enum CatalogError: Error, Sendable, Equatable {
    case network(String)
    case badStatus(Int)
    case malformedResponse
}

/// Minimal seam over an HTTP GET so the catalog is testable without the network.
public protocol CatalogHTTPClient: Sendable {
    func get(_ url: URL) async throws -> Data
}

/// Live client over URLSession.
public struct URLSessionCatalogClient: CatalogHTTPClient {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func get(_ url: URL) async throws -> Data {
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw CatalogError.badStatus(http.statusCode)
            }
            return data
        } catch let error as CatalogError {
            throw error
        } catch {
            throw CatalogError.network(error.localizedDescription)
        }
    }
}
```

- [ ] **Step 5: Implement `ModelCatalog.fetch`**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelCatalog.swift`:

```swift
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
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelCatalogParseTests`
Expected: PASS — all 6 tests in the file pass.

- [ ] **Step 7: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: CatalogHTTPClient seam + ModelCatalog.fetch parses mlx-community gemma list

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 4: ModelCatalog.recommend (RAM-tier filtering)

**Files:**
- Modify: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelCatalog.swift`
- Create: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelCatalogRecommendTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelCatalogRecommendTests.swift`:

```swift
import Testing
@testable import SenaniModelCatalog

private let all: [ModelInfo] = [
    ModelInfo(id: "mlx-community/gemma-3-1b-it-4bit",  sizeBytes: 800_000_000,   files: []),
    ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit",  sizeBytes: 2_400_000_000, files: []),
    ModelInfo(id: "mlx-community/gemma-3-12b-it-4bit", sizeBytes: 7_000_000_000, files: []),
    ModelInfo(id: "mlx-community/gemma-3-27b-it-4bit", sizeBytes: 15_000_000_000, files: []),
    ModelInfo(id: "mlx-community/gemma-mystery-4bit",  sizeBytes: nil,           files: []),
]

@Test func eightGigKeepsOnlySmallModels() {
    let r = ModelCatalog.recommend(from: all, tier: .gb8)
    #expect(r.models.map(\.id) == ["mlx-community/gemma-3-1b-it-4bit", "mlx-community/gemma-3-4b-it-4bit"])
    #expect(r.suggestedDefault?.id == "mlx-community/gemma-3-1b-it-4bit")
}

@Test func sixteenGigAddsTwelveB() {
    let r = ModelCatalog.recommend(from: all, tier: .gb16)
    #expect(r.models.map(\.id) == [
        "mlx-community/gemma-3-1b-it-4bit",
        "mlx-community/gemma-3-4b-it-4bit",
        "mlx-community/gemma-3-12b-it-4bit",
    ])
    #expect(r.suggestedDefault?.id == "mlx-community/gemma-3-4b-it-4bit")
}

@Test func thirtyTwoGigIncludesUnknownSizeSortedLast() {
    let r = ModelCatalog.recommend(from: all, tier: .gb32)
    #expect(r.models.map(\.id) == [
        "mlx-community/gemma-3-1b-it-4bit",
        "mlx-community/gemma-3-4b-it-4bit",
        "mlx-community/gemma-3-12b-it-4bit",
        "mlx-community/gemma-3-27b-it-4bit",
        "mlx-community/gemma-mystery-4bit",   // nil size sorts last, included only at gb32
    ])
    #expect(r.suggestedDefault?.id == "mlx-community/gemma-3-12b-it-4bit")
}

@Test func defaultFallsBackToFirstWhenPreferredAbsent() {
    let onlyLarge = [ModelInfo(id: "mlx-community/gemma-3-12b-it-4bit", sizeBytes: 7_000_000_000, files: [])]
    let r = ModelCatalog.recommend(from: onlyLarge, tier: .gb8)
    #expect(r.models.isEmpty)            // 7GB exceeds the 3GB gb8 budget
    #expect(r.suggestedDefault == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelCatalogRecommendTests`
Expected: FAIL — `ModelCatalog.recommend` / `RecommendationResult` undefined.

- [ ] **Step 3: Implement `recommend` + `RecommendationResult`**

Append to `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelCatalog.swift`:

```swift
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
    /// Pure RAM-tier policy (see plan "RAM-tier policy" table). No I/O.
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelCatalogRecommendTests`
Expected: PASS — 4 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: RAM-tier recommendation (filter + sort + suggested default)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 5: ModelDownloading seam + FileModelDownloader (cache + idempotent + progress)

**Files:**
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelDownloading.swift`
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/FileModelDownloader.swift`
- Create: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/FileModelDownloaderTests.swift`

The downloader is responsible for: choosing a cache directory under a configurable base (production passes Application Support), downloading every file of a `ModelInfo` from `https://huggingface.co/<id>/resolve/main/<file>`, reporting progress, being idempotent (a fully-cached model re-"downloads" instantly and reports complete), and returning the local model directory path. To keep tests off the network, the byte transfer goes through an injected `fileFetcher` closure (live = URLSession; test = canned bytes).

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/FileModelDownloaderTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniModelCatalog

private func model(_ files: [String] = ["config.json", "model.safetensors"]) -> ModelInfo {
    ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit", sizeBytes: 1000, files: files)
}

@Test func downloadsEachFileIntoCacheDirAndReportsComplete() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    var progress: [Double] = []
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in Data("weights".utf8) })

    let path = try await downloader.download(model()) { p in progress.append(p.fraction) }

    let dir = URL(fileURLWithPath: path)
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("config.json").path))
    #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path))
    #expect(progress.last == 1.0)
    #expect(progress.first ?? 1.0 < 1.0)        // progressed from <1 to 1
}

@Test func isIdempotentWhenAlreadyCached() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    var fetchCount = 0
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in
        fetchCount += 1; return Data("weights".utf8)
    })

    _ = try await downloader.download(model()) { _ in }
    #expect(fetchCount == 2)                     // two files fetched first time

    let secondPath = try await downloader.download(model()) { _ in }
    #expect(fetchCount == 2)                      // no re-fetch: fully cached
    #expect(downloader.isCached(model()) == true)
    #expect(FileManager.default.fileExists(atPath: secondPath))
}

@Test func partialCacheResumesOnlyMissingFiles() async throws {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    // Pre-create the model dir with ONE of the two files present.
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in Data("weights".utf8) })
    let dir = URL(fileURLWithPath: downloader.localPath(for: model()))
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try Data("present".utf8).write(to: dir.appendingPathComponent("config.json"))

    var fetched: [URL] = []
    let resuming = FileModelDownloader(baseDirectory: base, fileFetcher: { url in fetched.append(url); return Data("w".utf8) })
    _ = try await resuming.download(model()) { _ in }
    #expect(fetched.count == 1)                   // only the missing model.safetensors
    #expect(fetched.first?.absoluteString.hasSuffix("model.safetensors") == true)
}

@Test func fetcherErrorSurfacesAsDownloadError() async {
    let base = makeTempDir()
    defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FileModelDownloader(baseDirectory: base, fileFetcher: { _ in
        throw DownloadError.transport("boom")
    })
    await #expect(throws: DownloadError.self) {
        _ = try await downloader.download(model()) { _ in }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter FileModelDownloaderTests`
Expected: FAIL — `ModelDownloading`, `FileModelDownloader`, `DownloadError`, `DownloadProgress` undefined.

- [ ] **Step 3: Implement the seam**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelDownloading.swift`:

```swift
import Foundation

public enum DownloadError: Error, Sendable, Equatable {
    case transport(String)
    case writeFailed(String)
}

/// Progress for one model download.
public struct DownloadProgress: Sendable, Equatable {
    public let filesCompleted: Int
    public let filesTotal: Int
    public var fraction: Double {
        filesTotal == 0 ? 1.0 : Double(filesCompleted) / Double(filesTotal)
    }
    public init(filesCompleted: Int, filesTotal: Int) {
        self.filesCompleted = filesCompleted
        self.filesTotal = filesTotal
    }
}

/// Seam the ModelManager and UI depend on. The live impl is FileModelDownloader.
public protocol ModelDownloading: Sendable {
    /// Returns the local directory path holding the model's files.
    func download(_ model: ModelInfo, onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String
    func isCached(_ model: ModelInfo) -> Bool
    func localPath(for model: ModelInfo) -> String
}
```

- [ ] **Step 4: Implement `FileModelDownloader`**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/FileModelDownloader.swift`:

```swift
import Foundation

/// Downloads each file of a model from Hugging Face `resolve/main` into a per-model
/// cache directory. Idempotent (skips files already on disk), resumable (only fetches
/// missing files), and progress-reporting. Byte transfer is injected so tests stay offline.
public struct FileModelDownloader: ModelDownloading {
    private let baseDirectory: URL
    private let fileFetcher: @Sendable (URL) async throws -> Data

    /// `baseDirectory` is the cache root (production: Application Support/Senani/models).
    /// `fileFetcher` performs the actual byte transfer for a single file URL.
    public init(baseDirectory: URL,
                fileFetcher: @escaping @Sendable (URL) async throws -> Data = FileModelDownloader.liveFetcher) {
        self.baseDirectory = baseDirectory
        self.fileFetcher = fileFetcher
    }

    /// Live transfer over URLSession.
    public static let liveFetcher: @Sendable (URL) async throws -> Data = { url in
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw DownloadError.transport("HTTP \(http.statusCode)")
            }
            return data
        } catch let error as DownloadError {
            throw error
        } catch {
            throw DownloadError.transport(error.localizedDescription)
        }
    }

    public func localPath(for model: ModelInfo) -> String {
        // Replace "/" so the repo id becomes a single safe directory name.
        let safe = model.id.replacingOccurrences(of: "/", with: "__")
        return baseDirectory.appendingPathComponent(safe, isDirectory: true).path
    }

    public func isCached(_ model: ModelInfo) -> Bool {
        guard !model.files.isEmpty else { return false }
        let dir = URL(fileURLWithPath: localPath(for: model))
        return model.files.allSatisfy {
            FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
        }
    }

    public func download(_ model: ModelInfo,
                         onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String {
        let dir = URL(fileURLWithPath: localPath(for: model))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw DownloadError.writeFailed(error.localizedDescription)
        }

        let total = model.files.count
        var completed = 0
        onProgress(DownloadProgress(filesCompleted: 0, filesTotal: total))

        for file in model.files {
            let dest = dir.appendingPathComponent(file)
            if FileManager.default.fileExists(atPath: dest.path) {
                completed += 1
                onProgress(DownloadProgress(filesCompleted: completed, filesTotal: total))
                continue
            }
            guard let url = Self.remoteURL(modelId: model.id, file: file) else {
                throw DownloadError.transport("bad file name: \(file)")
            }
            let data = try await fileFetcher(url)
            do {
                try data.write(to: dest, options: .atomic)
            } catch {
                throw DownloadError.writeFailed(error.localizedDescription)
            }
            completed += 1
            onProgress(DownloadProgress(filesCompleted: completed, filesTotal: total))
        }
        return dir.path
    }

    static func remoteURL(modelId: String, file: String) -> URL? {
        URL(string: "https://huggingface.co/\(modelId)/resolve/main/\(file)")
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter FileModelDownloaderTests`
Expected: PASS — 4 tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: FileModelDownloader caches HF weights, idempotent + resumable + progress

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 6: ModelChoiceStore (persist chosen model id + local path)

**Files:**
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelChoiceStore.swift`
- Create: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelChoiceStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelChoiceStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniModelCatalog

private func freshDefaults() -> UserDefaults {
    let suite = "senani-choice-tests-\(UUID().uuidString)"
    return UserDefaults(suiteName: suite)!
}

@Test func savesAndLoadsChosenModel() throws {
    let store = UserDefaultsModelChoiceStore(defaults: freshDefaults())
    #expect(store.load() == nil)
    let choice = ModelChoice(modelId: "mlx-community/gemma-3-4b-it-4bit",
                             localPath: "/tmp/models/gemma")
    store.save(choice)
    let loaded = store.load()
    #expect(loaded == choice)
    #expect(loaded?.modelId == "mlx-community/gemma-3-4b-it-4bit")
    #expect(loaded?.localPath == "/tmp/models/gemma")
}

@Test func clearRemovesTheChoice() throws {
    let store = UserDefaultsModelChoiceStore(defaults: freshDefaults())
    store.save(ModelChoice(modelId: "a", localPath: "/p"))
    store.clear()
    #expect(store.load() == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelChoiceStoreTests`
Expected: FAIL — `ModelChoice`, `ModelChoiceStore`, `UserDefaultsModelChoiceStore` undefined.

- [ ] **Step 3: Implement the store**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelChoiceStore.swift`:

```swift
import Foundation

/// The persisted selection: which model, and where its weights live on disk.
public struct ModelChoice: Sendable, Equatable, Codable {
    public let modelId: String
    public let localPath: String
    public init(modelId: String, localPath: String) {
        self.modelId = modelId
        self.localPath = localPath
    }
}

/// Persistence seam so the chosen model auto-loads next launch.
public protocol ModelChoiceStore: Sendable {
    func save(_ choice: ModelChoice)
    func load() -> ModelChoice?
    func clear()
}

/// UserDefaults-backed implementation (production: `.standard`; tests: a throwaway suite).
public struct UserDefaultsModelChoiceStore: ModelChoiceStore {
    private let defaults: UserDefaults
    private let key = "senani.selectedModelChoice"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func save(_ choice: ModelChoice) {
        guard let data = try? JSONEncoder().encode(choice) else { return }
        defaults.set(data, forKey: key)
    }

    public func load() -> ModelChoice? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ModelChoice.self, from: data)
    }

    public func clear() { defaults.removeObject(forKey: key) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelChoiceStoreTests`
Expected: PASS — 2 tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: UserDefaults-backed ModelChoiceStore for chosen-model persistence

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 7: GeneratorInstalling seam + ModelManager (download → install → persist)

**Files:**
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/GeneratorInstalling.swift`
- Create: `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelManager.swift`
- Create: `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelManagerTests.swift`

`ModelManager` is the orchestration the UI calls. `chooseAndActivate(_:onProgress:)`: download (idempotent) → build the local path → call `installer.install(modelPath:)` (the composition-root swap) → persist the choice. `loadPersistedOnLaunch()`: if a choice exists AND its path is still present, install it (no download). The MLX construction lives behind `GeneratorInstalling` so the catalog package and its tests never link MLX — tests use a `SpyInstaller`.

- [ ] **Step 1: Write the failing test (extend TestSupport, then assertions)**

Append to `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/TestSupport.swift`:

```swift
// ---- doubles for ModelManager ----

final class FakeDownloader: ModelDownloading, @unchecked Sendable {
    var base: URL
    private(set) var downloadedIds: [String] = []
    init(base: URL) { self.base = base }
    func localPath(for model: ModelInfo) -> String {
        base.appendingPathComponent(model.id.replacingOccurrences(of: "/", with: "__")).path
    }
    func isCached(_ model: ModelInfo) -> Bool {
        FileManager.default.fileExists(atPath: localPath(for: model))
    }
    func download(_ model: ModelInfo, onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String {
        downloadedIds.append(model.id)
        let dir = URL(fileURLWithPath: localPath(for: model))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("dummy".utf8).write(to: dir.appendingPathComponent("model.safetensors"))
        onProgress(DownloadProgress(filesCompleted: 1, filesTotal: 1))
        return dir.path
    }
}

final class SpyInstaller: GeneratorInstalling, @unchecked Sendable {
    private(set) var installedPaths: [String] = []
    func install(modelPath: String) throws { installedPaths.append(modelPath) }
}
```

Create `Packages/SenaniModelCatalog/Tests/SenaniModelCatalogTests/ModelManagerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniModelCatalog

private func gemma4b() -> ModelInfo {
    ModelInfo(id: "mlx-community/gemma-3-4b-it-4bit", sizeBytes: 1000, files: ["model.safetensors"])
}

@Test func chooseDownloadsInstallsAndPersists() async throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FakeDownloader(base: base)
    let installer = SpyInstaller()
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    let manager = ModelManager(downloader: downloader, installer: installer, choices: choices)

    var sawProgress = false
    try await manager.chooseAndActivate(gemma4b()) { _ in sawProgress = true }

    #expect(downloader.downloadedIds == ["mlx-community/gemma-3-4b-it-4bit"])
    #expect(installer.installedPaths.count == 1)                       // the generator swap was invoked
    #expect(installer.installedPaths[0] == downloader.localPath(for: gemma4b()))
    #expect(sawProgress == true)
    #expect(choices.load()?.modelId == "mlx-community/gemma-3-4b-it-4bit")
}

@Test func choosingAlreadyCachedSkipsDownloadButStillInstalls() async throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FakeDownloader(base: base)
    // Pre-cache by running once.
    let installer1 = SpyInstaller()
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    let m1 = ModelManager(downloader: downloader, installer: installer1, choices: choices)
    try await m1.chooseAndActivate(gemma4b()) { _ in }
    #expect(downloader.downloadedIds.count == 1)

    // Choose again: FakeDownloader.download is still called but is itself idempotent on disk;
    // ModelManager always installs the resulting path. Assert install happened and choice persisted.
    let installer2 = SpyInstaller()
    let m2 = ModelManager(downloader: downloader, installer: installer2, choices: choices)
    try await m2.chooseAndActivate(gemma4b()) { _ in }
    #expect(installer2.installedPaths.count == 1)
    #expect(choices.load()?.modelId == "mlx-community/gemma-3-4b-it-4bit")
}

@Test func loadPersistedInstallsWhenPathPresent() async throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let downloader = FakeDownloader(base: base)
    let path = downloader.localPath(for: gemma4b())
    try FileManager.default.createDirectory(at: URL(fileURLWithPath: path), withIntermediateDirectories: true)
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    choices.save(ModelChoice(modelId: gemma4b().id, localPath: path))
    let installer = SpyInstaller()
    let manager = ModelManager(downloader: downloader, installer: installer, choices: choices)

    let installed = try manager.loadPersistedOnLaunch()
    #expect(installed == true)
    #expect(installer.installedPaths == [path])
    #expect(downloader.downloadedIds.isEmpty)            // no download on auto-load
}

@Test func loadPersistedReturnsFalseWhenNothingSaved() throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    let installer = SpyInstaller()
    let manager = ModelManager(downloader: FakeDownloader(base: base), installer: installer, choices: choices)
    #expect(try manager.loadPersistedOnLaunch() == false)
    #expect(installer.installedPaths.isEmpty)
}

@Test func loadPersistedReturnsFalseWhenPathMissing() throws {
    let base = makeTempDir(); defer { try? FileManager.default.removeItem(at: base) }
    let choices = UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "mm-\(UUID())")!)
    choices.save(ModelChoice(modelId: "x", localPath: base.appendingPathComponent("gone").path))
    let installer = SpyInstaller()
    let manager = ModelManager(downloader: FakeDownloader(base: base), installer: installer, choices: choices)
    #expect(try manager.loadPersistedOnLaunch() == false)
    #expect(installer.installedPaths.isEmpty)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelManagerTests`
Expected: FAIL — `GeneratorInstalling`, `ModelManager` undefined.

- [ ] **Step 3: Implement the installer seam**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/GeneratorInstalling.swift`:

```swift
/// The composition-root swap point. The app implements this by constructing
/// `SenaniInference.MLXTextGenerator(modelPath:)` and assigning it to
/// `AppEnvironment.generator` (replacing the NotReadyTextGenerator stub).
/// Kept as a seam so this package — and its tests — never link MLX.
public protocol GeneratorInstalling: Sendable {
    func install(modelPath: String) throws
}
```

- [ ] **Step 4: Implement `ModelManager`**

Create `Packages/SenaniModelCatalog/Sources/SenaniModelCatalog/ModelManager.swift`:

```swift
import Foundation

/// Orchestrates the picker flow: download (idempotent) → install the generator → persist the choice;
/// and re-installs the persisted choice on launch without re-downloading.
public struct ModelManager: Sendable {
    private let downloader: ModelDownloading
    private let installer: GeneratorInstalling
    private let choices: ModelChoiceStore

    public init(downloader: ModelDownloading, installer: GeneratorInstalling, choices: ModelChoiceStore) {
        self.downloader = downloader
        self.installer = installer
        self.choices = choices
    }

    /// Download (or reuse cached) weights, install the live generator, persist the selection.
    public func chooseAndActivate(_ model: ModelInfo,
                                  onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws {
        let path = try await downloader.download(model, onProgress: onProgress)
        try installer.install(modelPath: path)
        choices.save(ModelChoice(modelId: model.id, localPath: path))
    }

    /// On launch: if a prior choice's weights are still on disk, install it (no download).
    /// Returns true if a generator was installed.
    @discardableResult
    public func loadPersistedOnLaunch() throws -> Bool {
        guard let choice = choices.load() else { return false }
        guard FileManager.default.fileExists(atPath: choice.localPath) else { return false }
        try installer.install(modelPath: choice.localPath)
        return true
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test --filter ModelManagerTests`
Expected: PASS — 5 tests pass.

- [ ] **Step 6: Run the whole package suite**

Run: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && swift test`
Expected: PASS — all tests across all files green; no MLX, no network.

- [ ] **Step 7: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniModelCatalog && git add -A && git commit -m "$(cat <<'EOF'
SenaniModelCatalog: ModelManager orchestrates download/install/persist + launch auto-load via GeneratorInstalling seam

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 8: App wiring — NotReadyTextGenerator + MLXGeneratorInstaller + AppEnvironment

**Files:**
- Modify: `SenaniApp/Package.swift`
- Create: `SenaniApp/Sources/SenaniApp/Inference/NotReadyTextGenerator.swift`
- Create: `SenaniApp/Sources/SenaniApp/Inference/MLXGeneratorInstaller.swift`
- Create: `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`

This task introduces the §3 composition-root surface needed for the generator swap. Per §4, the composition root OWNS `generator`; the installer mutates it. The app is a 5.9 executable with no test target, so verification here is `swift build` (the package tests in Tasks 1–7 already cover the logic).

- [ ] **Step 1: Add the catalog dependency to the app manifest**

Edit `SenaniApp/Package.swift` — add the path dependency and product. Apply both edits:

Add to the `dependencies` array (after the `SenaniAssistant` line):
```swift
        .package(path: "../Packages/SenaniModelCatalog"),
```
Add to the executable target's `dependencies` array (after `"SenaniAssistant",`):
```swift
                "SenaniModelCatalog",
```

- [ ] **Step 2: Add the NotReady stub**

Create `SenaniApp/Sources/SenaniApp/Inference/NotReadyTextGenerator.swift`:

```swift
import SenaniInference
import SenaniRules

/// The generator the app starts with, before a model is chosen/downloaded.
/// Every call fails loudly so UI can prompt the user to pick a model — it never
/// silently returns empty text. Replaced by MLXTextGenerator once a model is installed.
public struct NotReadyTextGenerator: TextGenerator {
    public init() {}

    public func generate(prompt: String, maxTokens: Int) async throws -> String {
        throw InferenceError.modelNotLoaded
    }

    public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
        throw InferenceError.modelNotLoaded
    }
}
```

- [ ] **Step 3: Add the MLX installer (the ONLY file constructing MLXTextGenerator)**

Create `SenaniApp/Sources/SenaniApp/Inference/MLXGeneratorInstaller.swift`:

```swift
import Foundation
import SenaniInference
import SenaniModelCatalog

/// Bridges the catalog's `GeneratorInstalling` seam to the live MLX path.
/// On install, constructs `MLXTextGenerator(modelPath:)` and hands it to the
/// composition root via the injected setter. This is the ONE place the app
/// links the concrete MLX generator (§3: composition root owns `generator`).
///
/// Construction is host-only by contract: MLXTextGenerator assumes Apple-Silicon
/// MLX weights on disk. We do NOT run it in tests — the catalog package tests
/// use SpyInstaller instead, so nothing here needs MLX to be linked at test time.
public struct MLXGeneratorInstaller: GeneratorInstalling {
    private let setGenerator: @Sendable (any TextGenerator) -> Void

    public init(setGenerator: @escaping @Sendable (any TextGenerator) -> Void) {
        self.setGenerator = setGenerator
    }

    public func install(modelPath: String) throws {
        let generator = MLXTextGenerator(modelPath: modelPath)
        setGenerator(generator)
    }
}
```

- [ ] **Step 4: Add the composition root**

Create `SenaniApp/Sources/SenaniApp/AppEnvironment.swift`:

```swift
import Foundation
import Observation
import SenaniInference
import SenaniModelCatalog

/// The composition root for the generator slice (APP-PLANS-RECONCILIATION §3).
/// Holds `generator` starting as a NotReadyTextGenerator stub; the model picker
/// swaps it to a live MLXTextGenerator via the ModelManager + MLXGeneratorInstaller.
///
/// NOTE: the full live() graph (Orchestrator/Scheduler/Gmail/stores) is owned by the
/// app-shell plan. This type ships ONLY the generator-related members so the picker
/// can compile and run; the app-shell plan extends it.
@MainActor
@Observable
public final class AppEnvironment {
    /// The active generator. NotReady until a model is installed, then MLXTextGenerator.
    public private(set) var generator: any TextGenerator

    /// True once a real (non-stub) generator is installed — drives UI gating.
    public private(set) var hasModel: Bool = false

    public let catalog: ModelCatalog
    public let downloader: ModelDownloading
    public let choices: ModelChoiceStore
    public let tier: RAMTier

    /// Lazily built so it can capture `self` for the generator setter.
    public private(set) lazy var modelManager: ModelManager = ModelManager(
        downloader: downloader,
        installer: MLXGeneratorInstaller(setGenerator: { [weak self] gen in
            Task { @MainActor in self?.applyGenerator(gen) }
        }),
        choices: choices
    )

    public init(catalog: ModelCatalog,
                downloader: ModelDownloading,
                choices: ModelChoiceStore,
                tier: RAMTier) {
        self.generator = NotReadyTextGenerator()
        self.catalog = catalog
        self.downloader = downloader
        self.choices = choices
        self.tier = tier
    }

    private func applyGenerator(_ gen: any TextGenerator) {
        self.generator = gen
        self.hasModel = true
    }

    /// Production graph for the generator slice. Application Support cache + UserDefaults.
    public static func liveGeneratorSlice() -> AppEnvironment {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let modelsDir = appSupport
            .appendingPathComponent("Senani", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        return AppEnvironment(
            catalog: ModelCatalog(http: URLSessionCatalogClient()),
            downloader: FileModelDownloader(baseDirectory: modelsDir),
            choices: UserDefaultsModelChoiceStore(),
            tier: .detectHost()
        )
    }

    /// Auto-load a previously chosen model on launch (no download). Call once at startup.
    public func bootstrapPersistedModel() {
        do { _ = try modelManager.loadPersistedOnLaunch() }
        catch { /* leave NotReady; the picker lets the user re-select */ }
    }
}
```

- [ ] **Step 5: Build the app to verify it compiles**

Run: `cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build`
Expected: build succeeds. (First build resolves the new `SenaniModelCatalog` path dep and the existing MLX deps under `SenaniInference`; if MLX-dep resolution is slow, that is expected on a cold checkout — it is not a code error. If `@Observable` requires `import Observation` and the toolchain already re-exports it via SwiftUI, the explicit import is harmless.)

- [ ] **Step 6: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail && git add SenaniApp && git commit -m "$(cat <<'EOF'
SenaniApp: composition root generator slice — NotReadyTextGenerator stub + MLXGeneratorInstaller + AppEnvironment

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Task 9: SwiftUI ModelPickerView

**Files:**
- Create: `SenaniApp/Sources/SenaniApp/UI/ModelPickerView.swift`

The screen: detect tier (from `env.tier`), fetch + recommend on appear, list each recommended model with size and "fits your N GB" hint, show per-model download progress, and a "Use this model" button that calls `env.modelManager.chooseAndActivate`. On success, `env.hasModel` flips true. Plain SwiftUI controls (the DesignSystem plan can restyle later).

- [ ] **Step 1: Implement the view**

Create `SenaniApp/Sources/SenaniApp/UI/ModelPickerView.swift`:

```swift
import SwiftUI
import SenaniModelCatalog

@MainActor
struct ModelPickerView: View {
    let env: AppEnvironment

    @State private var loading = true
    @State private var loadError: String?
    @State private var recommendation: RecommendationResult?
    @State private var activeDownloadId: String?
    @State private var progress: Double = 0
    @State private var activatedId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 420)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose your local model")
                .font(.title2).bold()
            Text("Recommended for this Mac (\(env.tier.displayName) RAM). Runs fully on-device.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView("Fetching mlx-community catalog…")
        } else if let loadError {
            VStack(alignment: .leading, spacing: 8) {
                Text("Couldn't load the model list.").bold()
                Text(loadError).font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await load() } }
            }
        } else if let rec = recommendation {
            if rec.models.isEmpty {
                Text("No compatible Gemma 4-bit models found for this tier.")
                    .foregroundStyle(.secondary)
            } else {
                List(rec.models) { model in
                    row(for: model, isSuggested: model.id == rec.suggestedDefault?.id)
                }
            }
        }
    }

    private func row(for model: ModelInfo, isSuggested: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.shortName).font(.headline)
                    if isSuggested {
                        Text("Recommended")
                            .font(.caption2).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(.tint.opacity(0.2)))
                    }
                }
                Text("\(ModelInfo.formatBytes(model.sizeBytes)) · fits your \(env.tier.displayName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if activatedId == model.id {
                Label("Active", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if activeDownloadId == model.id {
                ProgressView(value: progress).frame(width: 120)
            } else {
                Button("Use this model") { Task { await use(model) } }
                    .disabled(activeDownloadId != nil)
            }
        }
        .padding(.vertical, 4)
    }

    private func load() async {
        loading = true; loadError = nil
        do {
            recommendation = try await env.catalog.recommended(tier: env.tier)
        } catch {
            loadError = String(describing: error)
        }
        loading = false
    }

    private func use(_ model: ModelInfo) async {
        activeDownloadId = model.id; progress = 0
        do {
            try await env.modelManager.chooseAndActivate(model) { p in
                Task { @MainActor in self.progress = p.fraction }
            }
            activatedId = model.id
        } catch {
            loadError = "Download/activation failed: \(error)"
        }
        activeDownloadId = nil
    }
}

#Preview {
    // Preview-only environment: canned catalog client + a no-network downloader.
    let previewEnv = AppEnvironment(
        catalog: ModelCatalog(http: PreviewCatalogClient()),
        downloader: PreviewDownloader(),
        choices: UserDefaultsModelChoiceStore(defaults: UserDefaults(suiteName: "preview")!),
        tier: .gb16
    )
    return ModelPickerView(env: previewEnv)
}

/// Preview/UI double: returns a canned mlx-community gemma list, no network.
private struct PreviewCatalogClient: CatalogHTTPClient {
    func get(_ url: URL) async throws -> Data {
        Data("""
        [ { "id": "mlx-community/gemma-3-1b-it-4bit",
            "siblings": [ { "rfilename": "model.safetensors", "size": 800000000 } ] },
          { "id": "mlx-community/gemma-3-4b-it-4bit",
            "siblings": [ { "rfilename": "model.safetensors", "size": 2400000000 } ] } ]
        """.utf8)
    }
}

/// Preview/UI double: pretends to download instantly, writes nothing real.
private struct PreviewDownloader: ModelDownloading {
    func localPath(for model: ModelInfo) -> String { "/tmp/preview/" + model.shortName }
    func isCached(_ model: ModelInfo) -> Bool { false }
    func download(_ model: ModelInfo, onProgress: @Sendable @escaping (DownloadProgress) -> Void) async throws -> String {
        onProgress(DownloadProgress(filesCompleted: 1, filesTotal: 1))
        return localPath(for: model)
    }
}
```

> Note: `PreviewDownloader` returns a fake path; in a real preview the `MLXGeneratorInstaller` would try to construct `MLXTextGenerator` on that path. Since `MLXTextGenerator.init` only stores the path (it does not load weights until `generate` is called), `chooseAndActivate` succeeds in preview and flips `hasModel` true without touching MLX runtime — the install is lazy by the verified `MLXTextGenerator` contract.

- [ ] **Step 2: Build the app to verify it compiles**

Run: `cd /Users/vishalkumar/Downloads/qmail/SenaniApp && swift build`
Expected: build succeeds. (SwiftUI `#Preview` macro compiles; the view is not yet routed into navigation — the app-shell plan adds a "no model yet → show ModelPickerView" gate. Routing is intentionally out of scope here to avoid colliding with the concurrently-developed app shell.)

- [ ] **Step 3: Commit**

```bash
cd /Users/vishalkumar/Downloads/qmail && git add SenaniApp && git commit -m "$(cat <<'EOF'
SenaniApp: ModelPickerView — recommended-by-tier list, download progress, Use-this-model action

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"`
```

---

## Self-Review

- [ ] **Scope coverage vs the brief.** ModelCatalog fetch+filter+recommend (Tasks 3–4); ModelDownloader cache/resumable/idempotent/progress (Task 5); SwiftUI picker with size/RAM-fit/progress/"Use this model" (Task 9); model switching via `MLXTextGenerator` install into `AppEnvironment.generator` replacing NotReady stub (Tasks 7–8); chosen-model persistence + auto-load (Tasks 6–7). Every brief bullet maps to a task.

- [ ] **Tests honor the constraints.** Fake HTTP client with canned HF JSON (Task 3 `FakeCatalogHTTPClient`/`CannedHF`); fake downloader writing a dummy file (Task 7 `FakeDownloader`); RAM-tier filtering picks the right variants (Task 4, three tiers + fallback); catalog parse incl. malformed/HTTP-error (Task 3); downloader caches + idempotent + resumable (Task 5); choice persistence round-trips (Task 6); the generator swap is invoked after a successful download via the `SpyInstaller` spy (Task 7 `chooseDownloadsInstallsAndPersists` asserts `installer.installedPaths`). NO real MLX, NO real HF network, NO multi-GB downloads in any test.

- [ ] **MLX gated/host-only.** `MLXTextGenerator` is constructed in exactly one app-target file (`MLXGeneratorInstaller.swift`) behind the `GeneratorInstalling` seam; the catalog package never imports `SenaniInference`, so `swift test` for the package passes with no Apple-Silicon MLX. Tests use `SpyInstaller`.

- [ ] **SenaniInference coupling minimal.** Only the frozen `TextGenerator` protocol, `InferenceError`, `JSONSchema`, and `MLXTextGenerator(modelPath:)` are used (verified signatures). No internal/in-flight types referenced. The catalog defines its own `GeneratorInstalling`; the app defines its own `NotReadyTextGenerator`.

- [ ] **Composition root discipline (§3/§4).** `AppEnvironment` owns `generator` (starts NotReady), exposes `hasModel`, and the picker swaps it through the manager → installer → `applyGenerator`. No screen constructs a store/backend; the view reads everything through `env`. `AppEnvironment` adds ONLY the generator slice and explicitly defers the full `live()` graph to the app-shell plan, avoiding a collision.

- [ ] **Type consistency.** Names match across tasks: `RAMTier` (`detect`/`maxModelBytes`/`defaultModelId`/`displayName`), `ModelInfo`(`id`/`sizeBytes?`/`files`/`shortName`/`formatBytes`), `ModelCatalog`(`fetch`/`recommend`/`recommended`), `RecommendationResult`(`models`/`suggestedDefault`), `DownloadProgress.fraction`, `ModelDownloading`(`download`/`isCached`/`localPath`), `ModelChoice`(`modelId`/`localPath`), `ModelChoiceStore`(`save`/`load`/`clear`), `GeneratorInstalling.install(modelPath:)`, `ModelManager`(`chooseAndActivate`/`loadPersistedOnLaunch`). The picker calls only these.

- [ ] **No placeholders.** Every code step has complete Swift; every run step has an exact `cd … && swift test`/`swift build` command with expected output; every commit step has the full trailer.

- [ ] **Open item flagged (§5).** The exact `mlx-community/gemma-*-4bit` repo ids in `RAMTier.defaultModelId` and that `MLXTextGenerator` loads them on the target Apple-Silicon tier are an open item for the human; the catalog's live `fetch()` self-corrects ids at runtime (it lists whatever `mlx-community` actually publishes), so a stale default id degrades to "no suggested default," never a crash.
```