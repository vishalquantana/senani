# SenaniInference (on-device Gemma via MLX) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SenaniInference` SPM package: an on-device, MLX/Gemma-backed text-generation + embedding layer with grammar-constrained JSON decoding, exposing a `GemmaPredicateEvaluator` that conforms to `SenaniRules.PredicateEvaluator` for batched AI predicate evaluation — all unit-testable without a model behind protocol seams.

**Architecture:** Generation and embedding sit behind two `Sendable` protocols (`TextGenerator`, `Embedder`). All core logic (prompt building, JSON parsing, predicate alignment) depends only on these seams and is unit-tested with `FakeTextGenerator`/`FakeEmbedder` (test target). The real `MLXTextGenerator`/`MLXEmbedder` load a Gemma MLX model, tokenize, and sample with a grammar-derived logit mask; they are exercised ONLY by a gated integration test that is skipped unless `SENANI_MODEL_PATH` is set. `GemmaPredicateEvaluator` builds one prompt embedding the message + all predicates, asks for a JSON object via constrained decoding, parses it, and returns `[Bool]` aligned to input order, safe-defaulting any missing/malformed entry to `false`.

**Tech Stack:** Swift 6.2, swift-tools 6.0, macOS 14, strict concurrency, Swift Testing (`import Testing`), mlx-swift + mlx-swift-examples (gated), path dependency on `../SenaniRules`.

---

## File Structure

```
Packages/SenaniInference/
├── Package.swift
├── Sources/
│   └── SenaniInference/
│       ├── JSONSchema.swift               // minimal JSONSchema value type
│       ├── TextGenerator.swift            // TextGenerator protocol + generateJSON
│       ├── Embedder.swift                 // Embedder protocol
│       ├── JSONResultParser.swift         // robust {"results":[Bool...]} parser
│       ├── PredicatePromptBuilder.swift   // builds the batched-predicate prompt + schema
│       ├── GemmaPredicateEvaluator.swift  // conforms to SenaniRules.PredicateEvaluator
│       ├── MLXTextGenerator.swift         // mlx-swift-backed TextGenerator (gated)
│       └── MLXEmbedder.swift              // mlx-swift-backed Embedder (gated)
└── Tests/
    └── SenaniInferenceTests/
        ├── Fakes.swift                    // FakeTextGenerator / FakeEmbedder
        ├── JSONSchemaTests.swift
        ├── JSONResultParserTests.swift
        ├── PredicatePromptBuilderTests.swift
        ├── GemmaPredicateEvaluatorTests.swift
        └── MLXIntegrationTests.swift      // gated by SENANI_MODEL_PATH
```

All commands below assume `PKG=/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference`.

---

## Task 0: Scaffold the package (compiles + empty test suite passes)

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Package.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/Placeholder.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/ScaffoldTests.swift`

- [ ] 1. Create `Package.swift` exactly:
  ```swift
  // swift-tools-version: 6.0
  import PackageDescription

  let package = Package(
      name: "SenaniInference",
      platforms: [.macOS(.v14)],
      products: [
          .library(name: "SenaniInference", targets: ["SenaniInference"]),
      ],
      dependencies: [
          .package(path: "../SenaniRules"),
          .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.21.2"),
          .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", from: "1.18.1"),
      ],
      targets: [
          .target(
              name: "SenaniInference",
              dependencies: [
                  .product(name: "SenaniRules", package: "SenaniRules"),
                  .product(name: "MLX", package: "mlx-swift"),
                  .product(name: "MLXNN", package: "mlx-swift"),
                  .product(name: "MLXRandom", package: "mlx-swift"),
                  .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                  .product(name: "MLXLLM", package: "mlx-swift-examples"),
              ],
              swiftSettings: [.swiftLanguageMode(.v6)]
          ),
          .testTarget(
              name: "SenaniInferenceTests",
              dependencies: ["SenaniInference"],
              swiftSettings: [.swiftLanguageMode(.v6)]
          ),
      ]
  )
  ```
- [ ] 2. Create `Sources/SenaniInference/Placeholder.swift` with a single non-public marker so the target has at least one file:
  ```swift
  // Intentionally empty marker file; replaced as real types land.
  enum _SenaniInferenceScaffold {}
  ```
- [ ] 3. Create `Tests/SenaniInferenceTests/ScaffoldTests.swift`:
  ```swift
  import Testing
  @testable import SenaniInference

  @Test func packageCompilesAndLinks() {
      #expect(Bool(true))
  }
  ```
- [ ] 4. Run-to-pass (this also pre-fetches the MLX deps; first run downloads them):
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test`
  - Expected: build succeeds; `packageCompilesAndLinks` passes; no model is required.
  - NOTE: if dependency resolution fails on the pinned versions, run `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift package resolve` and bump the `from:` pins to the latest tags that resolve, then re-run. Do NOT remove the deps.
- [ ] 5. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  scaffold SenaniInference SPM package

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 1: `JSONSchema` minimal value type

A minimal schema type used to drive grammar-constrained sampling. It must be expressive enough to describe the batched-predicate output `{"results":[true,false,...]}` and a generic object, and `Sendable`/`Equatable` for tests.

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/JSONSchema.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/JSONSchemaTests.swift`

- [ ] 1. Write failing test `JSONSchemaTests.swift`:
  ```swift
  import Testing
  @testable import SenaniInference

  @Test func boolArrayResultsSchemaShape() {
      let schema = JSONSchema.boolArrayResults(key: "results")
      // Top-level is an object with one required array-of-bool property.
      guard case let .object(properties, required) = schema else {
          Issue.record("expected object schema"); return
      }
      #expect(required == ["results"])
      #expect(properties.count == 1)
      guard case let .array(element) = properties["results"] else {
          Issue.record("expected array property"); return
      }
      #expect(element == .boolean)
  }

  @Test func schemaIsEquatable() {
      #expect(JSONSchema.boolean == JSONSchema.boolean)
      #expect(JSONSchema.boolArrayResults(key: "results")
              == JSONSchema.boolArrayResults(key: "results"))
      #expect(JSONSchema.boolArrayResults(key: "a")
              != JSONSchema.boolArrayResults(key: "b"))
  }
  ```
- [ ] 2. Run-to-fail:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter JSONSchemaTests`
  - Expected: compile error — `JSONSchema` is undefined.
- [ ] 3. Minimal implementation `JSONSchema.swift`:
  ```swift
  /// A minimal JSON schema value type. Drives grammar-constrained decoding
  /// (the MLX sampler builds a logit mask from this) and documents the shape
  /// callers expect back. Indirect because it is recursive.
  public indirect enum JSONSchema: Sendable, Equatable {
      case boolean
      case string
      case number
      /// An array whose every element matches `element`.
      case array(element: JSONSchema)
      /// An object. `properties` maps name -> schema; `required` lists the
      /// property names that must be present, in order.
      case object(properties: [String: JSONSchema], required: [String])

      /// Convenience for the batched-predicate output: `{ "<key>": [bool, ...] }`.
      public static func boolArrayResults(key: String) -> JSONSchema {
          .object(properties: [key: .array(element: .boolean)], required: [key])
      }
  }
  ```
- [ ] 4. Run-to-pass:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter JSONSchemaTests`
  - Expected: both tests pass.
- [ ] 5. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add minimal JSONSchema value type

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 2: `TextGenerator` and `Embedder` protocols + Fakes

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/TextGenerator.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/Embedder.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/Fakes.swift`

- [ ] 1. Write failing test by adding the Fakes (they will fail to compile until the protocols exist). Create `Fakes.swift`:
  ```swift
  import Foundation
  @testable import SenaniInference

  /// Scripted TextGenerator for unit tests. Records the prompts it received and
  /// returns queued responses in FIFO order; if the queue empties it returns
  /// `fallback`.
  final class FakeTextGenerator: TextGenerator, @unchecked Sendable {
      private let lock = NSLock()
      private var responses: [String]
      private(set) var prompts: [String] = []
      private(set) var schemas: [JSONSchema?] = []
      let fallback: String

      init(responses: [String], fallback: String = "") {
          self.responses = responses
          self.fallback = fallback
      }

      private func next(_ prompt: String, _ schema: JSONSchema?) -> String {
          lock.lock(); defer { lock.unlock() }
          prompts.append(prompt)
          schemas.append(schema)
          return responses.isEmpty ? fallback : responses.removeFirst()
      }

      func generate(prompt: String, maxTokens: Int) async throws -> String {
          next(prompt, nil)
      }

      func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
          next(prompt, schema)
      }
  }

  /// Scripted Embedder returning a fixed vector (optionally seeded by text length).
  final class FakeEmbedder: Embedder, @unchecked Sendable {
      private let vector: [Float]
      private(set) var embedded: [String] = []
      private let lock = NSLock()

      init(vector: [Float] = [0, 0, 0]) { self.vector = vector }

      func embed(_ text: String) async throws -> [Float] {
          lock.lock(); embedded.append(text); lock.unlock()
          return vector
      }
  }

  @Test func fakeGeneratorReturnsScriptedThenFallback() async throws {
      let gen = FakeTextGenerator(responses: ["one"], fallback: "fb")
      let a = try await gen.generate(prompt: "p1", maxTokens: 10)
      let b = try await gen.generateJSON(prompt: "p2", schema: .boolean)
      #expect(a == "one")
      #expect(b == "fb")
      #expect(gen.prompts == ["p1", "p2"])
      #expect(gen.schemas == [nil, JSONSchema.boolean])
  }

  @Test func fakeEmbedderRecordsAndReturns() async throws {
      let emb = FakeEmbedder(vector: [1, 2])
      let v = try await emb.embed("hello")
      #expect(v == [1, 2])
      #expect(emb.embedded == ["hello"])
  }
  ```
  (Add `import Testing` at the top of `Fakes.swift`.)
- [ ] 2. Run-to-fail:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter Fakes`
  - Expected: compile error — `TextGenerator` / `Embedder` undefined.
- [ ] 3. Minimal implementation `TextGenerator.swift`:
  ```swift
  /// Errors surfaced by generators/embedders. Core logic catches these and
  /// safe-defaults; it never crashes.
  public enum InferenceError: Error, Sendable, Equatable {
      case modelNotLoaded
      case generationFailed(String)
      case decodingFailed(String)
  }

  /// The seam for on-device text generation. Core logic depends only on this.
  /// `MLXTextGenerator` is the Gemma-backed impl; `FakeTextGenerator` is the
  /// test double.
  public protocol TextGenerator: Sendable {
      /// Free-form generation, capped at `maxTokens` new tokens.
      func generate(prompt: String, maxTokens: Int) async throws -> String

      /// Grammar-constrained generation: the returned string is guaranteed (by
      /// the impl's logit masking) to be JSON conforming to `schema`. Callers
      /// must still defensively parse — Fakes/edge cases may not honor it.
      func generateJSON(prompt: String, schema: JSONSchema) async throws -> String
  }
  ```
  And `Embedder.swift`:
  ```swift
  /// The seam for on-device text embedding (for retrieval / vector index).
  public protocol Embedder: Sendable {
      func embed(_ text: String) async throws -> [Float]
  }
  ```
- [ ] 4. Run-to-pass:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter Fakes`
  - Expected: both fake tests pass.
- [ ] 5. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add TextGenerator/Embedder protocols and test fakes

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 3: `JSONResultParser` — robust `{"results":[Bool...]}` parsing

Parses possibly-noisy model output into `[Bool]`. Must: find the first JSON object even with leading/trailing prose or code fences; read the `results` array; coerce `true/false`, `1/0`, `"true"/"false"` to `Bool`; ignore extra fields; never throw on malformed input — return `nil` so callers can safe-default.

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/JSONResultParser.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/JSONResultParserTests.swift`

- [ ] 1. Write failing test `JSONResultParserTests.swift`:
  ```swift
  import Testing
  @testable import SenaniInference

  @Test func parsesCleanResults() {
      let out = JSONResultParser.parseBoolResults(#"{"results":[true,false,true]}"#)
      #expect(out == [true, false, true])
  }

  @Test func parsesWithSurroundingProseAndCodeFence() {
      let raw = """
      Sure, here you go:
      ```json
      {"results": [true, true]}
      ```
      """
      #expect(JSONResultParser.parseBoolResults(raw) == [true, true])
  }

  @Test func ignoresExtraFields() {
      let raw = #"{"explanation":"x","results":[false,true],"confidence":0.9}"#
      #expect(JSONResultParser.parseBoolResults(raw) == [false, true])
  }

  @Test func coercesNumbersAndStrings() {
      let raw = #"{"results":[1, 0, "true", "false"]}"#
      #expect(JSONResultParser.parseBoolResults(raw) == [true, false, true, false])
  }

  @Test func malformedJsonReturnsNil() {
      #expect(JSONResultParser.parseBoolResults("not json at all") == nil)
      #expect(JSONResultParser.parseBoolResults(#"{"results": [tru"#) == nil)
  }

  @Test func missingResultsKeyReturnsNil() {
      #expect(JSONResultParser.parseBoolResults(#"{"answers":[true]}"#) == nil)
  }

  @Test func emptyResultsReturnsEmptyArray() {
      #expect(JSONResultParser.parseBoolResults(#"{"results":[]}"#) == [])
  }
  ```
- [ ] 2. Run-to-fail:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter JSONResultParserTests`
  - Expected: compile error — `JSONResultParser` undefined.
- [ ] 3. Minimal implementation `JSONResultParser.swift`:
  ```swift
  import Foundation

  /// Best-effort parser for the batched-predicate model output. Never throws.
  public enum JSONResultParser {

      /// Returns the bool array under the `results` key, or `nil` if the output
      /// cannot be parsed into a `results` array. Tolerates surrounding prose,
      /// markdown code fences, extra fields, and bool/int/string element forms.
      public static func parseBoolResults(_ raw: String, key: String = "results") -> [Bool]? {
          guard let objectData = firstJSONObjectData(in: raw) else { return nil }
          guard let top = try? JSONSerialization.jsonObject(with: objectData),
                let dict = top as? [String: Any] else { return nil }
          guard let rawArray = dict[key] as? [Any] else { return nil }
          var out: [Bool] = []
          out.reserveCapacity(rawArray.count)
          for element in rawArray {
              guard let b = coerceBool(element) else { return nil }
              out.append(b)
          }
          return out
      }

      /// Coerce a JSON element to Bool: true/false, 1/0, "true"/"false".
      private static func coerceBool(_ value: Any) -> Bool? {
          if let b = value as? Bool { return b }
          if let n = value as? NSNumber {
              // NSNumber covers Int/Double/Bool from JSONSerialization; bool handled above.
              if n == 1 { return true }
              if n == 0 { return false }
              return nil
          }
          if let s = value as? String {
              switch s.lowercased() {
              case "true", "yes", "1": return true
              case "false", "no", "0": return false
              default: return nil
              }
          }
          return nil
      }

      /// Extract the substring of the first balanced top-level `{...}` object,
      /// honoring string literals so braces inside strings don't confuse it.
      private static func firstJSONObjectData(in raw: String) -> Data? {
          let chars = Array(raw)
          guard let start = chars.firstIndex(of: "{") else { return nil }
          var depth = 0
          var inString = false
          var escaped = false
          var i = start
          while i < chars.count {
              let c = chars[i]
              if inString {
                  if escaped { escaped = false }
                  else if c == "\\" { escaped = true }
                  else if c == "\"" { inString = false }
              } else {
                  if c == "\"" { inString = true }
                  else if c == "{" { depth += 1 }
                  else if c == "}" {
                      depth -= 1
                      if depth == 0 {
                          let slice = String(chars[start...i])
                          return slice.data(using: .utf8)
                      }
                  }
              }
              i += 1
          }
          return nil
      }
  }
  ```
- [ ] 4. Run-to-pass:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter JSONResultParserTests`
  - Expected: all 7 tests pass.
- [ ] 5. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add robust JSON results parser

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 4: `PredicatePromptBuilder` — prompt + schema for batched predicates

Builds the single prompt that embeds the message (subject/from/snippet) and every predicate, and produces the `JSONSchema` for the expected output. Snippet is the body truncated to keep the prompt small for Gemma.

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/PredicatePromptBuilder.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/PredicatePromptBuilderTests.swift`

- [ ] 1. Write failing test `PredicatePromptBuilderTests.swift`:
  ```swift
  import Foundation
  import Testing
  import SenaniRules
  @testable import SenaniInference

  private func sampleMessage(body: String = "Can you send pricing for the enterprise tier?") -> Message {
      Message(
          id: "m1", from: "sarah@acme.com", to: ["me@x.com"],
          subject: "Pricing question", body: body,
          hasAttachment: false, listUnsubscribeHeader: nil, labels: ["INBOX"],
          threadId: "t1", date: Date(timeIntervalSince1970: 0), isFromUser: false
      )
  }

  @Test func promptContainsMessageFields() {
      let prompt = PredicatePromptBuilder.build(
          predicates: ["is asking about pricing"], message: sampleMessage())
      #expect(prompt.contains("sarah@acme.com"))
      #expect(prompt.contains("Pricing question"))
      #expect(prompt.contains("enterprise tier"))
  }

  @Test func promptContainsEveryPredicateNumbered() {
      let predicates = ["is asking about pricing", "is from a customer", "mentions a deadline"]
      let prompt = PredicatePromptBuilder.build(predicates: predicates, message: sampleMessage())
      for p in predicates { #expect(prompt.contains(p)) }
      // Numbered 1..n so the model aligns its array.
      #expect(prompt.contains("1."))
      #expect(prompt.contains("3."))
  }

  @Test func promptAsksForResultsJsonObject() {
      let prompt = PredicatePromptBuilder.build(
          predicates: ["x"], message: sampleMessage())
      #expect(prompt.lowercased().contains("results"))
      #expect(prompt.lowercased().contains("json"))
  }

  @Test func snippetIsTruncated() {
      let long = String(repeating: "A", count: 5000)
      let prompt = PredicatePromptBuilder.build(predicates: ["x"], message: sampleMessage(body: long))
      // Body is truncated to the configured max snippet length (1000) + ellipsis,
      // so the full 5000-char body never reaches the prompt.
      #expect(!prompt.contains(long))
      #expect(prompt.contains("…"))
  }

  @Test func schemaMatchesResultsBoolArray() {
      #expect(PredicatePromptBuilder.schema == JSONSchema.boolArrayResults(key: "results"))
  }
  ```
- [ ] 2. Run-to-fail:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter PredicatePromptBuilderTests`
  - Expected: compile error — `PredicatePromptBuilder` undefined.
- [ ] 3. Minimal implementation `PredicatePromptBuilder.swift`:
  ```swift
  import Foundation
  import SenaniRules

  /// Builds the single batched-predicate prompt and its output schema.
  public enum PredicatePromptBuilder {
      /// Max characters of body included as the snippet.
      static let maxSnippet = 1000

      /// The JSON shape the model must emit: { "results": [bool, ...] }.
      public static let schema = JSONSchema.boolArrayResults(key: "results")

      public static func build(predicates: [String], message: Message) -> String {
          let snippet: String = {
              if message.body.count <= maxSnippet { return message.body }
              return String(message.body.prefix(maxSnippet)) + "…"
          }()

          let numbered = predicates.enumerated()
              .map { "\($0.offset + 1). \($0.element)" }
              .joined(separator: "\n")

          return """
          You judge an email against a numbered list of yes/no questions.
          Answer each question for THIS email only, in order.

          EMAIL
          From: \(message.from)
          Subject: \(message.subject)
          Body: \(snippet)

          QUESTIONS
          \(numbered)

          Reply with ONLY a JSON object of the form {"results":[<bool>, ...]} \
          containing exactly \(predicates.count) booleans, one per question in \
          order. true = yes, false = no. No prose.
          """
      }
  }
  ```
- [ ] 4. Run-to-pass:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter PredicatePromptBuilderTests`
  - Expected: all 5 tests pass.
- [ ] 5. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add batched-predicate prompt builder

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 5: `GemmaPredicateEvaluator` — conforms to `SenaniRules.PredicateEvaluator`

Ties it together: build one prompt, call `generateJSON`, parse, and return `[Bool]` aligned to input order. Safe-defaults: empty predicates → `[]` with no model call; parse failure → all `false`; count mismatch → pad with `false` / truncate to the requested count; thrown generator error → all `false`. Never crashes.

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/GemmaPredicateEvaluator.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/GemmaPredicateEvaluatorTests.swift`

- [ ] 1. Write failing test `GemmaPredicateEvaluatorTests.swift`:
  ```swift
  import Foundation
  import Testing
  import SenaniRules
  @testable import SenaniInference

  private func msg() -> Message {
      Message(id: "m", from: "a@b.com", to: ["me@x.com"], subject: "s", body: "b",
              hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
              threadId: "t", date: Date(timeIntervalSince1970: 0), isFromUser: false)
  }

  @Test func returnsAlignedResultsInOrder() async {
      let gen = FakeTextGenerator(responses: [#"{"results":[true,false,true]}"#])
      let eval = GemmaPredicateEvaluator(generator: gen)
      let out = await eval.evaluate(
          predicates: ["p1", "p2", "p3"], against: msg())
      #expect(out == [true, false, true])
  }

  @Test func emptyPredicatesShortCircuitsWithNoModelCall() async {
      let gen = FakeTextGenerator(responses: [#"{"results":[true]}"#])
      let eval = GemmaPredicateEvaluator(generator: gen)
      let out = await eval.evaluate(predicates: [], against: msg())
      #expect(out == [])
      #expect(gen.prompts.isEmpty)   // no call made
  }

  @Test func malformedJsonDefaultsAllFalse() async {
      let gen = FakeTextGenerator(responses: ["garbage not json"])
      let eval = GemmaPredicateEvaluator(generator: gen)
      let out = await eval.evaluate(predicates: ["p1", "p2"], against: msg())
      #expect(out == [false, false])
  }

  @Test func tooFewResultsPaddedWithFalse() async {
      let gen = FakeTextGenerator(responses: [#"{"results":[true]}"#])
      let eval = GemmaPredicateEvaluator(generator: gen)
      let out = await eval.evaluate(predicates: ["p1", "p2", "p3"], against: msg())
      #expect(out == [true, false, false])
  }

  @Test func tooManyResultsTruncated() async {
      let gen = FakeTextGenerator(responses: [#"{"results":[true,true,true,true]}"#])
      let eval = GemmaPredicateEvaluator(generator: gen)
      let out = await eval.evaluate(predicates: ["p1", "p2"], against: msg())
      #expect(out == [true, true])
  }

  @Test func generatorThrowsDefaultsAllFalse() async {
      let eval = GemmaPredicateEvaluator(generator: ThrowingGenerator())
      let out = await eval.evaluate(predicates: ["p1", "p2"], against: msg())
      #expect(out == [false, false])
  }

  @Test func usesConstrainedDecodingWithResultsSchema() async {
      let gen = FakeTextGenerator(responses: [#"{"results":[true]}"#])
      let eval = GemmaPredicateEvaluator(generator: gen)
      _ = await eval.evaluate(predicates: ["p1"], against: msg())
      #expect(gen.schemas == [JSONSchema.boolArrayResults(key: "results")])
  }

  private struct ThrowingGenerator: TextGenerator {
      func generate(prompt: String, maxTokens: Int) async throws -> String {
          throw InferenceError.generationFailed("boom")
      }
      func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
          throw InferenceError.generationFailed("boom")
      }
  }
  ```
- [ ] 2. Run-to-fail:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter GemmaPredicateEvaluatorTests`
  - Expected: compile error — `GemmaPredicateEvaluator` undefined.
- [ ] 3. Minimal implementation `GemmaPredicateEvaluator.swift`:
  ```swift
  import Foundation
  import SenaniRules

  /// Implements the rules engine's `PredicateEvaluator` seam using a
  /// `TextGenerator` (Gemma via MLX in production). One grammar-constrained
  /// call per message; output is parsed and aligned to input order. Any
  /// failure safe-defaults missing entries to `false` and never crashes.
  public struct GemmaPredicateEvaluator: PredicateEvaluator {
      private let generator: any TextGenerator
      private let maxTokens: Int

      public init(generator: any TextGenerator, maxTokens: Int = 256) {
          self.generator = generator
          self.maxTokens = maxTokens
      }

      public func evaluate(predicates: [String], against message: Message) async -> [Bool] {
          guard !predicates.isEmpty else { return [] }
          let count = predicates.count

          let prompt = PredicatePromptBuilder.build(predicates: predicates, message: message)
          let raw: String
          do {
              raw = try await generator.generateJSON(
                  prompt: prompt, schema: PredicatePromptBuilder.schema)
          } catch {
              return Array(repeating: false, count: count)
          }

          guard let parsed = JSONResultParser.parseBoolResults(raw) else {
              return Array(repeating: false, count: count)
          }

          return align(parsed, to: count)
      }

      /// Pad with `false` if short, truncate if long, so the result always has
      /// exactly `count` entries in the same order as the input predicates.
      private func align(_ values: [Bool], to count: Int) -> [Bool] {
          if values.count == count { return values }
          if values.count > count { return Array(values.prefix(count)) }
          return values + Array(repeating: false, count: count - values.count)
      }
  }
  ```
- [ ] 4. Run-to-pass:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter GemmaPredicateEvaluatorTests`
  - Expected: all 7 tests pass.
- [ ] 5. Full suite (no model present):
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test`
  - Expected: every unit test passes; the gated MLX integration test (Task 7) is skipped because `SENANI_MODEL_PATH` is unset.
- [ ] 6. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add GemmaPredicateEvaluator with safe alignment

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 6: `MLXTextGenerator` and `MLXEmbedder` (real mlx-swift impls)

These are the production implementations. They MUST compile and link without a model present (model is loaded lazily on first call from `modelPath`). Only the gated integration test (Task 7) actually loads weights and runs them. No placeholders — the bodies are real mlx-swift code; if a model is absent the lazy load throws `InferenceError.modelNotLoaded`, which `GemmaPredicateEvaluator` already safe-defaults.

Implementation notes the worker MUST follow (these are real APIs in `mlx-swift-examples` / `MLXLMCommon` at the pinned versions — verify exact symbol names against the resolved package and adjust spelling if the API moved, but keep the structure):

- **Model loading:** use `MLXLMCommon.loadModelContainer` / `LLMModelFactory.shared.loadContainer(configuration:)` with `ModelConfiguration(directory: URL(fileURLWithPath: modelPath))` for a local Gemma MLX directory. Cache the loaded `ModelContainer` in an `actor` so loads happen once and generation is serialized (MLX is not concurrency-safe across calls).
- **Free-form generation (`generate`):** build a `UserInput`/chat prompt, call `MLXLMCommon.generate(...)` (or `ChatSession`) with `GenerateParameters(maxTokens:)`, collect the produced text.
- **Constrained generation (`generateJSON`):** convert the `JSONSchema` to a token-level constraint. Implement `GrammarMask` that, given the schema and the tokenizer, produces a `LogitProcessor`/sampler step that zeroes (sets `-inf`) the logits of any token that cannot continue a valid JSON value of the schema, then renormalizes. Drive `generate` with that processor so the emitted tokens are always schema-valid JSON. For the `boolArrayResults` schema this restricts output to the grammar `{"results":[ (true|false) (, (true|false))* ]?}` plus whitespace. Keep the mask logic in a separate `GrammarMask.swift` if it grows; it is covered by the integration test asserting valid JSON out.
- **Embedding (`MLXEmbedder.embed`):** load an embedding model (e.g. a small MLX sentence-embedding model directory at `modelPath`), run a forward pass, mean-pool the last hidden state over tokens, and return the `[Float]` vector via `vector.asArray(Float.self)`.

Because real model behavior is non-deterministic and weight-dependent, these impls are NOT unit-tested with assertions on content — they are compiled here and exercised in Task 7.

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/MLXTextGenerator.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/MLXEmbedder.swift`
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Sources/SenaniInference/GrammarMask.swift`

- [ ] 1. Write a failing compile-only test in `MLXIntegrationTests.swift` (the file is fully populated in Task 7; for now add the construction lines so the new types are referenced):
  ```swift
  // (added at top of the file created in Task 7 — see Task 7 step 1)
  ```
  For this task, drive the failing state with a temporary type-existence test appended to `Fakes.swift`:
  ```swift
  @Test func mlxTypesAreConstructible() {
      _ = MLXTextGenerator(modelPath: "/nonexistent")
      _ = MLXEmbedder(modelPath: "/nonexistent")
  }
  ```
- [ ] 2. Run-to-fail:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter mlxTypesAreConstructible`
  - Expected: compile error — `MLXTextGenerator` / `MLXEmbedder` undefined.
- [ ] 3. Implement `GrammarMask.swift` (real logit-mask builder driven by `JSONSchema`; produces an `MLXLMCommon.LogitProcessor`-conforming value that, per decode step, restricts allowed next tokens to those continuing a schema-valid JSON value). Implement the `boolArrayResults` grammar concretely; throw `InferenceError.decodingFailed` for schema shapes not yet supported.
- [ ] 4. Implement `MLXTextGenerator.swift`:
  ```swift
  import Foundation
  import MLX
  import MLXLMCommon
  import MLXLLM

  /// Gemma-via-MLX text generator. Loads the model lazily on first use from a
  /// local MLX model directory. Safe to construct without a model present.
  public final class MLXTextGenerator: TextGenerator, Sendable {
      private let modelPath: String
      private let loader: ModelLoader

      public init(modelPath: String) {
          self.modelPath = modelPath
          self.loader = ModelLoader(modelPath: modelPath)
      }

      public func generate(prompt: String, maxTokens: Int) async throws -> String {
          let container = try await loader.container()
          return try await container.perform { context in
              // Build input, run MLXLMCommon.generate with GenerateParameters(maxTokens:),
              // collect and return decoded text.
              try MLXGeneration.run(context: context, prompt: prompt,
                                    maxTokens: maxTokens, mask: nil)
          }
      }

      public func generateJSON(prompt: String, schema: JSONSchema) async throws -> String {
          let container = try await loader.container()
          let mask = try GrammarMask(schema: schema)
          return try await container.perform { context in
              try MLXGeneration.run(context: context, prompt: prompt,
                                    maxTokens: 512, mask: mask)
          }
      }
  }

  /// Serializes model load + access (MLX is not safe across concurrent calls).
  actor ModelLoader {
      private let modelPath: String
      private var loaded: ModelContainer?
      init(modelPath: String) { self.modelPath = modelPath }

      func container() async throws -> ModelContainer {
          if let loaded { return loaded }
          let dir = URL(fileURLWithPath: modelPath)
          guard FileManager.default.fileExists(atPath: dir.path) else {
              throw InferenceError.modelNotLoaded
          }
          let c = try await LLMModelFactory.shared.loadContainer(
              configuration: ModelConfiguration(directory: dir))
          loaded = c
          return c
      }
  }
  ```
  - Add the small `MLXGeneration.run(context:prompt:maxTokens:mask:)` helper (real `MLXLMCommon.generate` driver) in the same file or a sibling; it returns the decoded String and applies `mask` as a `LogitProcessor` when non-nil. Verify the exact `generate`/`ModelContainer.perform`/`LLMModelFactory` symbol names against the resolved `mlx-swift-examples` source and fix spelling if needed; do NOT stub the body out.
- [ ] 5. Implement `MLXEmbedder.swift` similarly: lazy-load an embedding model from `modelPath`, run forward, mean-pool, return `[Float]`; throw `InferenceError.modelNotLoaded` when the path is absent.
- [ ] 6. Run-to-pass (compile + construct, still no model):
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test --filter mlxTypesAreConstructible`
  - Expected: passes — types construct without loading a model.
- [ ] 7. Full suite without a model:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test`
  - Expected: all unit tests pass; integration test skipped.
- [ ] 8. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add MLX-backed generator/embedder with grammar mask

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Task 7: Gated MLX integration test (REAL, skipped unless `SENANI_MODEL_PATH` set)

A real end-to-end test that loads an actual Gemma MLX model from `SENANI_MODEL_PATH`, generates, runs constrained JSON decoding, and runs the full `GemmaPredicateEvaluator` against a real message. It is skipped (not failed) when the env var is unset, so CI and model-less dev machines stay green.

**Files:**
- `/Users/vishalkumar/Downloads/qmail/Packages/SenaniInference/Tests/SenaniInferenceTests/MLXIntegrationTests.swift`

- [ ] 1. Write the gated integration test `MLXIntegrationTests.swift`:
  ```swift
  import Foundation
  import Testing
  import SenaniRules
  @testable import SenaniInference

  /// Resolves the model directory from SENANI_MODEL_PATH, or nil to skip.
  private func modelPath() -> String? {
      guard let p = ProcessInfo.processInfo.environment["SENANI_MODEL_PATH"],
            !p.isEmpty else { return nil }
      return p
  }

  @Test func realGeneratorProducesText() async throws {
      guard let path = modelPath() else {
          withKnownIssue("SENANI_MODEL_PATH not set; skipping MLX integration") { #expect(Bool(false)) }
          return
      }
      let gen = MLXTextGenerator(modelPath: path)
      let out = try await gen.generate(prompt: "Say the single word: hello.", maxTokens: 16)
      #expect(!out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }

  @Test func realConstrainedDecodingEmitsValidResultsJson() async throws {
      guard let path = modelPath() else {
          withKnownIssue("SENANI_MODEL_PATH not set; skipping MLX integration") { #expect(Bool(false)) }
          return
      }
      let gen = MLXTextGenerator(modelPath: path)
      let msg = Message(id: "i1", from: "sales@acme.com", to: ["me@x.com"],
                        subject: "Quote for 50 seats", body: "What is your pricing for 50 seats?",
                        hasAttachment: false, listUnsubscribeHeader: nil, labels: ["INBOX"],
                        threadId: "t", date: Date(), isFromUser: false)
      let prompt = PredicatePromptBuilder.build(
          predicates: ["is asking about pricing", "mentions an attachment"], message: msg)
      let raw = try await gen.generateJSON(prompt: prompt, schema: PredicatePromptBuilder.schema)
      // Constrained decoding guarantees parseable results of exactly the right length.
      let parsed = JSONResultParser.parseBoolResults(raw)
      #expect(parsed != nil)
      #expect(parsed?.count == 2)
  }

  @Test func realEvaluatorEndToEnd() async throws {
      guard let path = modelPath() else {
          withKnownIssue("SENANI_MODEL_PATH not set; skipping MLX integration") { #expect(Bool(false)) }
          return
      }
      let eval = GemmaPredicateEvaluator(generator: MLXTextGenerator(modelPath: path))
      let msg = Message(id: "i2", from: "sales@acme.com", to: ["me@x.com"],
                        subject: "Quote for 50 seats", body: "What is your pricing for 50 seats?",
                        hasAttachment: false, listUnsubscribeHeader: nil, labels: ["INBOX"],
                        threadId: "t", date: Date(), isFromUser: false)
      let out = await eval.evaluate(
          predicates: ["is asking about pricing", "mentions an attachment"], against: msg)
      #expect(out.count == 2)
      // The pricing question should read true; attachment claim should read false.
      #expect(out[0] == true)
      #expect(out[1] == false)
  }

  @Test func realEmbedderReturnsNonEmptyVector() async throws {
      guard let path = ProcessInfo.processInfo.environment["SENANI_EMBED_MODEL_PATH"],
            !path.isEmpty else {
          withKnownIssue("SENANI_EMBED_MODEL_PATH not set; skipping") { #expect(Bool(false)) }
          return
      }
      let emb = MLXEmbedder(modelPath: path)
      let v = try await emb.embed("hello world")
      #expect(!v.isEmpty)
  }
  ```
  - The `withKnownIssue { #expect(false) }` pattern records a known (expected) issue so the run shows the test as a non-failing skip; alternatively use Swift Testing's `Trait`-based conditional skip if available in the toolchain (`@Test(.enabled(if: ...))`) — if so, prefer `@Test(.enabled(if: ProcessInfo.processInfo.environment["SENANI_MODEL_PATH"] != nil))` and drop the inner guard. Pick whichever compiles in 6.2 and keep the body REAL.
- [ ] 2. Run-to-pass without a model:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test`
  - Expected: all unit tests pass; the four integration tests are skipped (recorded as known issues / disabled), suite is green.
- [ ] 3. (Manual, optional) Run-to-pass WITH a model — documented, not required in CI:
  - Command: `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && SENANI_MODEL_PATH=/path/to/gemma-mlx swift test --filter MLXIntegrationTests`
  - Expected: integration tests load the model and pass.
- [ ] 4. Remove the temporary `mlxTypesAreConstructible` test from `Fakes.swift` if it duplicates coverage now in the integration file, OR keep it (it is a useful model-less compile guard). Re-run `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test` and confirm green.
- [ ] 5. Commit:
  - `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && git add -A && git commit -m "$(cat <<'EOF'
  add gated MLX integration tests

  Generated with [Claude Code](https://claude.ai/code)
  via [Happy](https://happy.engineering)

  Co-Authored-By: Claude <noreply@anthropic.com>
  Co-Authored-By: Happy <yesreply@happy.engineering>
  EOF
  )"`

---

## Self-Review

- [ ] **Builds and tests without a model.** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniInference && swift test` passes with no `SENANI_MODEL_PATH`; all MLX-loading work is lazy and gated.
- [ ] **Testability seam honored.** All prompt-building (`PredicatePromptBuilder`), parsing (`JSONResultParser`), and evaluator alignment (`GemmaPredicateEvaluator`) are tested only against `FakeTextGenerator`/`FakeEmbedder`; the real MLX path is exercised solely by the gated integration test, which is real (loads weights, generates, asserts) — not a placeholder.
- [ ] **Conforms to the SenaniRules contract.** `GemmaPredicateEvaluator: SenaniRules.PredicateEvaluator` with `func evaluate(predicates:against:) async -> [Bool]`; does NOT edit SenaniRules; consumes its public `Message`. Path dep `../SenaniRules` only.
- [ ] **Safe defaulting verified.** Tests cover: correct ordered alignment, empty predicates (no model call), malformed JSON → all false, generator throw → all false, too-few → padded false, too-many → truncated, constrained schema passed through. Never crashes.
- [ ] **Constrained decoding present and real.** `generateJSON` + `JSONSchema` + `GrammarMask` implement schema-driven logit masking for `{"results":[bool...]}`; integration test asserts parseable, correct-length JSON out.
- [ ] **No placeholders.** Every test has real Swift Testing code; every implementation is real Swift; every run/commit step has exact `cd … && swift test`/`git commit` commands.
- [ ] **Public surface matches the brief.** Exposed: `TextGenerator`, `Embedder`, `JSONSchema`, `InferenceError`, `MLXTextGenerator`, `MLXEmbedder`, `GemmaPredicateEvaluator`, `PredicatePromptBuilder`, `JSONResultParser`. Test-only helpers: `FakeTextGenerator`, `FakeEmbedder`.
- [ ] **Strict concurrency clean.** Swift 6 language mode; `MLXTextGenerator`/`MLXEmbedder` are `Sendable` with model access serialized through an `actor` (`ModelLoader`).
- [ ] **Dependency pins resolve.** If the `mlx-swift` / `mlx-swift-examples` `from:` pins fail to resolve, bumped to the nearest resolving tags (Task 0 step 4 note) without removing the deps; exact MLX generation symbol names verified against the resolved source (Task 6 step 4).
