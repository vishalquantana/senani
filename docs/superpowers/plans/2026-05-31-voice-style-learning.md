# SenaniVoice — Voice / Style Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SenaniVoice` package that learns a user's writing voice from their Sent mail (heuristic profile + per-domain variation), persists it, indexes exemplar sent messages in the vector store, and assembles a conditioning prompt prefix that makes a local model draft in the user's voice — all on-device, fully unit-tested with fakes.

**Architecture:** Pure-Swift heuristics (`VoiceProfileBuilder`) turn `[Message]` (sent mail only) into a `VoiceProfile` with `perDomainOverrides`. `VoiceProfileStore` round-trips the profile as JSON through SenaniStore's `voice_profile` table. `VoiceExemplarIndexer` embeds selected sent messages via an `Embedder` and inserts them into a `VectorIndex` with `{domain, messageId}` metadata. `VoiceConditioner` selects the right profile (domain override or base), retrieves nearest exemplars from the index, and emits a conditioning **prompt prefix** string — the actual draft generation belongs to the Reply Drafter / Assistant, not this package. `VoiceOverride` models chat-issued profile edits applied via `applyOverride(_:to:)`. All logic is testable with `FakeTextGenerator`, `FakeEmbedder`, and `InMemoryVectorIndex`; no real model is required.

**Tech Stack:** Swift 6.2, swift-tools 6.0, macOS 14, strict concurrency, Swift Testing (`import Testing`). Path dependencies on `../SenaniRules`, `../SenaniStore`, `../SenaniInference`.

---

## Cross-Package Assumptions

These sibling packages are **not yet on disk** (only `SenaniRules` exists). This plan depends on the PUBLIC contracts stated in the brief. If any differ at implementation time, adjust the thin adapter code (storage + embedding calls only); the heuristics and prompt-assembly logic do not depend on them.

- **SenaniRules** (real, verified on disk): `public struct Message: Sendable, Equatable, Identifiable` with `id, from, to:[String], subject, body, hasAttachment, listUnsubscribeHeader, labels, threadId, date, isFromUser` and computed `var senderDomain: String` (lowercased host after last `@`, or `""`). Used as-is; **not edited**.
- **SenaniStore**: provides `SenaniDatabase`, a `VectorIndex` protocol with `insert(id: String, vector: [Float], metadata: [String: String])` and `search(vector: [Float], k: Int) -> [(id: String, distance: Float)]`, and a concrete `InMemoryVectorIndex` (used in tests). A `voice_profile` table already exists in migrations.
  - **ASSUMPTION (storage):** `SenaniDatabase` exposes a way to execute parameterized SQL with an upsert and a single-row read against `voice_profile`. To avoid coupling the plan to an exact SQL API we are unsure of, `VoiceProfileStore` is written against a **narrow internal protocol `VoiceProfilePersistence`** with two methods (`saveProfileJSON(_:) throws` / `loadProfileJSON() throws -> Data?`). We ship a `SenaniDatabaseVoiceProfilePersistence` adapter that wraps `SenaniDatabase`, and an in-memory `InMemoryVoiceProfilePersistence` for round-trip unit tests. **This is the single point to reconcile with SenaniStore's real DB API.** If `SenaniDatabase` has an in-memory constructor, the adapter can be exercised directly in an integration test later; unit tests here use the in-memory persistence.
  - **ASSUMPTION (VectorIndex):** `VectorIndex` is a protocol (per brief) so `VoiceExemplarIndexer` and `VoiceConditioner` accept `any VectorIndex`. `search` returns ids ordered nearest-first.
- **SenaniInference**: provides `TextGenerator` (`generate(prompt:maxTokens:) async throws -> String`), `Embedder` (`embed(_:) async throws -> [Float]`), and test fakes `FakeTextGenerator` / `FakeEmbedder`.
  - **ASSUMPTION:** `FakeEmbedder` returns deterministic vectors (so two distinct strings yield distinct vectors, and `search` is meaningfully orderable). If the real `FakeEmbedder` returns a constant vector, our exemplar/retrieval tests will instead assert on **inserted count + metadata + that a search returns the inserted ids** rather than on ordering — see Task 6 notes.

> **Note on dependencies:** `SenaniVoice` cannot `swift build`/`swift test` until `SenaniStore` and `SenaniInference` exist at the sibling paths with the contracts above. **First execution step (Task 0)** verifies the dependency packages resolve. If they are absent, STOP and surface the blocker rather than stubbing them inside `SenaniVoice`.

---

## File Structure

```
Packages/SenaniVoice/
├── Package.swift
├── Sources/
│   └── SenaniVoice/
│       ├── VoiceProfile.swift            // VoiceProfile (Codable), DomainProfile traits
│       ├── VoiceProfileBuilder.swift     // pure heuristics: [Message] -> VoiceProfile
│       ├── VoiceTextStats.swift          // small pure helpers: sentences, words, emoji, n-grams
│       ├── VoiceProfileStore.swift       // VoiceProfilePersistence + adapters + VoiceProfileStore
│       ├── VoiceExemplarIndexer.swift    // embeds sent mail -> VectorIndex
│       ├── VoiceConditioner.swift        // profile selection + retrieval + prompt prefix
│       └── VoiceOverride.swift           // VoiceOverride enum + applyOverride(_:to:)
└── Tests/
    └── SenaniVoiceTests/
        ├── Fixtures.swift                // sample sent Messages
        ├── VoiceTextStatsTests.swift
        ├── VoiceProfileBuilderTests.swift
        ├── VoiceProfileStoreTests.swift
        ├── VoiceExemplarIndexerTests.swift
        ├── VoiceConditionerTests.swift
        └── VoiceOverrideTests.swift
```

---

## Task 0 — Package scaffold & dependency resolution

**Files:** `Packages/SenaniVoice/Package.swift`, `Packages/SenaniVoice/Sources/SenaniVoice/VoiceProfile.swift` (placeholder type only)

- [ ] Create `Packages/SenaniVoice/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniVoice",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniVoice", targets: ["SenaniVoice"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
    ],
    targets: [
        .target(
            name: "SenaniVoice",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
            ]
        ),
        .testTarget(
            name: "SenaniVoiceTests",
            dependencies: ["SenaniVoice"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] Create a minimal `VoiceProfile.swift` so the target compiles:

```swift
public struct VoiceProfile: Codable, Sendable, Equatable {
    public init() {}
}
```

- [ ] **Run-to-resolve:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift build`
  - **Expected if deps present:** builds clean.
  - **Expected if deps absent:** `error: the package ... cannot be edited / no such module 'SenaniStore'`. **STOP and report the missing sibling packages.** Do not fake them.
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git init -q 2>/dev/null; git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: package scaffold with path deps

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 1 — VoiceProfile model

**Files:** `Sources/SenaniVoice/VoiceProfile.swift`, `Tests/SenaniVoiceTests/VoiceProfileBuilderTests.swift` (start the suite with a model test)

- [ ] **Write failing test** in `VoiceProfileBuilderTests.swift` (Codable round-trip + default value semantics):

```swift
import Testing
import Foundation
@testable import SenaniVoice

@Suite struct VoiceProfileModelTests {
    @Test func codableRoundTripPreservesAllFieldsIncludingOverrides() throws {
        var base = VoiceProfile(
            greeting: "Hi",
            signoff: "Best,",
            formalityScore: 0.4,
            avgSentenceLength: 12.5,
            avgWordsPerMessage: 60.0,
            emojiRate: 0.25,
            commonPhrases: ["let me know", "happy to help"]
        )
        base.perDomainOverrides["client.com"] = VoiceProfile(
            greeting: "Dear", signoff: "Kind regards,", formalityScore: 0.8,
            avgSentenceLength: 18, avgWordsPerMessage: 90, emojiRate: 0.0, commonPhrases: ["per our discussion"]
        )

        let data = try JSONEncoder().encode(base)
        let decoded = try JSONDecoder().decode(VoiceProfile.self, from: data)

        #expect(decoded == base)
        #expect(decoded.perDomainOverrides["client.com"]?.signoff == "Kind regards,")
    }

    @Test func emptyProfileHasSafeDefaults() {
        let p = VoiceProfile()
        #expect(p.greeting == "")
        #expect(p.signoff == "")
        #expect(p.formalityScore == 0.5)
        #expect(p.commonPhrases.isEmpty)
        #expect(p.perDomainOverrides.isEmpty)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceProfileModelTests`
  - **Expected:** compile error — `VoiceProfile` has no such initializer / members.
- [ ] **Implement** `VoiceProfile.swift` (replace the placeholder):

```swift
import Foundation

/// A compact, learned model of how the user writes. Codable so it persists as JSON
/// in the `voice_profile` table. Per-domain overrides capture the client-vs-teammate
/// variation called out in the design (§9).
public struct VoiceProfile: Codable, Sendable, Equatable {
    public var greeting: String              // e.g. "Hi", "Dear", "Hey"
    public var signoff: String               // e.g. "Best,", "Thanks,", "Cheers,"
    public var formalityScore: Double        // 0 (casual) ... 1 (formal)
    public var avgSentenceLength: Double     // words per sentence
    public var avgWordsPerMessage: Double
    public var emojiRate: Double             // emoji glyphs per message
    public var commonPhrases: [String]
    /// Recipient-domain → a sub-profile that overrides the base for that audience.
    public var perDomainOverrides: [String: VoiceProfile]

    public init(
        greeting: String = "",
        signoff: String = "",
        formalityScore: Double = 0.5,
        avgSentenceLength: Double = 0,
        avgWordsPerMessage: Double = 0,
        emojiRate: Double = 0,
        commonPhrases: [String] = [],
        perDomainOverrides: [String: VoiceProfile] = [:]
    ) {
        self.greeting = greeting
        self.signoff = signoff
        self.formalityScore = formalityScore
        self.avgSentenceLength = avgSentenceLength
        self.avgWordsPerMessage = avgWordsPerMessage
        self.emojiRate = emojiRate
        self.commonPhrases = commonPhrases
        self.perDomainOverrides = perDomainOverrides
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceProfileModelTests`
  - **Expected:** 2 tests pass.
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: VoiceProfile Codable model with per-domain overrides

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 2 — Text stats helpers (sentences, words, emoji, n-grams)

**Files:** `Sources/SenaniVoice/VoiceTextStats.swift`, `Tests/SenaniVoiceTests/VoiceTextStatsTests.swift`

These pure functions are the substrate for the builder. Keep them as `enum VoiceTextStats` (namespace of static funcs).

- [ ] **Write failing test** `VoiceTextStatsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniVoice

@Suite struct VoiceTextStatsTests {
    @Test func wordCountSplitsOnWhitespace() {
        #expect(VoiceTextStats.wordCount("Hello there, friend") == 3)
        #expect(VoiceTextStats.wordCount("   ") == 0)
    }

    @Test func sentenceCountSplitsOnTerminators() {
        #expect(VoiceTextStats.sentenceCount("Hi. How are you? Great!") == 3)
        #expect(VoiceTextStats.sentenceCount("No terminator here") == 1)
        #expect(VoiceTextStats.sentenceCount("") == 0)
    }

    @Test func emojiCountCountsEmojiScalars() {
        #expect(VoiceTextStats.emojiCount("nice 👍 work 🎉🎉") == 3)
        #expect(VoiceTextStats.emojiCount("plain text") == 0)
    }

    @Test func containsContractionDetectsApostropheForms() {
        #expect(VoiceTextStats.containsContraction("I can't make it") == true)
        #expect(VoiceTextStats.containsContraction("I cannot make it") == false)
    }

    @Test func topNgramsRanksByFrequencyThenLexically() {
        let texts = [
            "let me know if you need anything",
            "let me know when you are free",
            "let me know your thoughts",
        ]
        let phrases = VoiceTextStats.topNgrams(texts, n: 3, limit: 2)
        #expect(phrases.first == "let me know")
        #expect(phrases.count <= 2)
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceTextStatsTests`
  - **Expected:** `no type named 'VoiceTextStats'`.
- [ ] **Implement** `VoiceTextStats.swift`:

```swift
import Foundation

/// Pure, deterministic text statistics used by the profile builder.
public enum VoiceTextStats {
    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
    }

    public static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        let parts = trimmed.split(whereSeparator: { $0 == "." || $0 == "!" || $0 == "?" })
        let nonEmpty = parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return max(nonEmpty.count, 1)
    }

    public static func emojiCount(_ text: String) -> Int {
        text.unicodeScalars.filter { $0.properties.isEmojiPresentation || $0.properties.isEmoji && $0.value > 0x238C }.count
    }

    public static func containsContraction(_ text: String) -> Bool {
        // An apostrophe sitting between two letters (can't, I'm, you're, we'll).
        let lower = text.lowercased()
        let chars = Array(lower)
        for i in chars.indices where chars[i] == "'" || chars[i] == "\u{2019}" {
            let prevIsLetter = i > 0 && chars[i - 1].isLetter
            let nextIsLetter = i + 1 < chars.count && chars[i + 1].isLetter
            if prevIsLetter && nextIsLetter { return true }
        }
        return false
    }

    /// Top contiguous n-word phrases across `texts`, ranked by frequency then lexically.
    public static func topNgrams(_ texts: [String], n: Int, limit: Int) -> [String] {
        guard n > 0, limit > 0 else { return [] }
        var counts: [String: Int] = [:]
        for text in texts {
            let words = text.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
            guard words.count >= n else { continue }
            for start in 0...(words.count - n) {
                let gram = words[start..<(start + n)].joined(separator: " ")
                counts[gram, default: 0] += 1
            }
        }
        return counts
            .filter { $0.value > 1 }                       // only phrases that recur
            .sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .prefix(limit)
            .map(\.key)
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceTextStatsTests`
  - **Expected:** all pass. (If `emojiCount` over/under-counts a fixture, narrow the predicate — keep the test as the contract.)
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: pure text-stats helpers (words, sentences, emoji, n-grams)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 3 — Fixtures (sample sent mail)

**Files:** `Tests/SenaniVoiceTests/Fixtures.swift`

- [ ] **Create** `Fixtures.swift` (no test here; shared helpers used by later suites). Builds `SenaniRules.Message` values for sent mail with distinct greetings/signoffs/domains.

```swift
import Foundation
import SenaniRules

enum Fixtures {
    static let userAddr = "ramesh@quantana.in"

    static func sent(
        _ id: String,
        to: [String],
        subject: String = "re: work",
        body: String,
        date: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> Message {
        Message(
            id: id, from: userAddr, to: to, subject: subject, body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: ["SENT"],
            threadId: "t-\(id)", date: date, isFromUser: true
        )
    }

    static func received(_ id: String, from: String, body: String = "incoming") -> Message {
        Message(
            id: id, from: from, to: [userAddr], subject: "in", body: body,
            hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
            threadId: "t-\(id)", date: Date(timeIntervalSince1970: 1_700_000_000), isFromUser: false
        )
    }

    /// Casual mail to teammates @quantana.in.
    static var teammateSent: [Message] {
        [
            sent("a", to: ["dev@quantana.in"],
                 body: "Hey Dev,\n\nCan't wait to ship this. Let me know if you need anything 👍\n\nCheers,\nRamesh"),
            sent("b", to: ["ops@quantana.in"],
                 body: "Hey team,\n\nQuick one — I'll push the fix tonight. Let me know your thoughts.\n\nCheers,\nRamesh"),
        ]
    }

    /// Formal mail to a client domain.
    static var clientSent: [Message] {
        [
            sent("c", to: ["cfo@client.com"],
                 body: "Dear Mr. Rao,\n\nThank you for your time. Please find the proposal attached. I look forward to your response.\n\nBest regards,\nRamesh"),
            sent("d", to: ["cfo@client.com"],
                 body: "Dear Mr. Rao,\n\nFollowing up on the proposal. I would appreciate your feedback at your convenience.\n\nBest regards,\nRamesh"),
        ]
    }

    static var allSent: [Message] { teammateSent + clientSent }
}
```

- [ ] **Run-to-build:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift build --build-tests`
  - **Expected:** compiles (fixtures reference only `SenaniRules.Message`).
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: test fixtures for sent mail (teammate vs client)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 4 — VoiceProfileBuilder (heuristics + per-domain sub-profiles)

**Files:** `Sources/SenaniVoice/VoiceProfileBuilder.swift`, `Tests/SenaniVoiceTests/VoiceProfileBuilderTests.swift`

The builder filters to `isFromUser == true`, extracts greeting/signoff/formality/lengths/emoji/phrases, and builds a base profile plus a sub-profile per recipient domain.

- [ ] **Append failing tests** to `VoiceProfileBuilderTests.swift`:

```swift
@Suite struct VoiceProfileBuilderTests {
    @Test func ignoresReceivedMailAndUsesOnlySent() {
        let builder = VoiceProfileBuilder()
        let messages = Fixtures.teammateSent + [Fixtures.received("r1", from: "x@client.com", body: "Dear Sir, formal note.")]
        let profile = builder.build(from: messages)
        // The received "Dear Sir" must not leak into the casual teammate profile.
        #expect(profile.greeting == "Hey")
    }

    @Test func extractsGreetingAndSignoffFromFirstAndLastLines() {
        let builder = VoiceProfileBuilder()
        let profile = builder.build(from: Fixtures.clientSent)
        #expect(profile.greeting == "Dear")
        #expect(profile.signoff == "Best regards,")
    }

    @Test func clientMailScoresMoreFormalThanTeammateMail() {
        let builder = VoiceProfileBuilder()
        let client = builder.build(from: Fixtures.clientSent)
        let team = builder.build(from: Fixtures.teammateSent)
        #expect(client.formalityScore > team.formalityScore)
    }

    @Test func emojiRateIsEmojiPerMessage() {
        let builder = VoiceProfileBuilder()
        let team = builder.build(from: Fixtures.teammateSent)   // one 👍 across two messages
        #expect(team.emojiRate == 0.5)
        let client = builder.build(from: Fixtures.clientSent)
        #expect(client.emojiRate == 0.0)
    }

    @Test func commonPhrasesSurfaceRepeatedNgrams() {
        let builder = VoiceProfileBuilder()
        let team = builder.build(from: Fixtures.teammateSent)
        #expect(team.commonPhrases.contains("let me know"))
    }

    @Test func buildsPerDomainOverrides() {
        let builder = VoiceProfileBuilder()
        let profile = builder.build(from: Fixtures.allSent)
        #expect(profile.perDomainOverrides["client.com"]?.greeting == "Dear")
        #expect(profile.perDomainOverrides["quantana.in"]?.greeting == "Hey")
        // A domain with formal mail is more formal than the casual one.
        let formal = profile.perDomainOverrides["client.com"]!.formalityScore
        let casual = profile.perDomainOverrides["quantana.in"]!.formalityScore
        #expect(formal > casual)
    }

    @Test func emptyInputYieldsDefaultProfile() {
        let builder = VoiceProfileBuilder()
        #expect(builder.build(from: []) == VoiceProfile())
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceProfileBuilderTests`
  - **Expected:** `no type named 'VoiceProfileBuilder'`.
- [ ] **Implement** `VoiceProfileBuilder.swift`:

```swift
import Foundation
import SenaniRules

/// Pure-Swift heuristics that turn the user's SENT mail into a VoiceProfile.
/// No model is involved; everything here is deterministic and unit-testable.
public struct VoiceProfileBuilder: Sendable {
    public init() {}

    private static let greetingHeads = ["hi", "hey", "hello", "dear"]
    private static let signoffHeads = [
        "best regards,", "kind regards,", "best,", "regards,",
        "thanks,", "thank you,", "cheers,", "warmly,", "sincerely,",
    ]

    public func build(from messages: [Message]) -> VoiceProfile {
        let sent = messages.filter { $0.isFromUser }
        guard !sent.isEmpty else { return VoiceProfile() }

        var base = profile(for: sent)

        // Group by recipient domain (first recipient's domain) and build sub-profiles.
        var byDomain: [String: [Message]] = [:]
        for m in sent {
            guard let domain = recipientDomain(of: m) else { continue }
            byDomain[domain, default: []].append(m)
        }
        for (domain, msgs) in byDomain {
            base.perDomainOverrides[domain] = profile(for: msgs)
        }
        return base
    }

    // MARK: - Core profile from a homogeneous set of sent messages

    private func profile(for sent: [Message]) -> VoiceProfile {
        let bodies = sent.map(\.body)

        let greeting = mostCommon(bodies.compactMap(greeting(in:))) ?? ""
        let signoff = mostCommon(bodies.compactMap(signoff(in:))) ?? ""

        let totalWords = bodies.reduce(0) { $0 + VoiceTextStats.wordCount($1) }
        let totalSentences = bodies.reduce(0) { $0 + VoiceTextStats.sentenceCount($1) }
        let totalEmoji = bodies.reduce(0) { $0 + VoiceTextStats.emojiCount($1) }
        let count = Double(sent.count)

        let avgWords = count > 0 ? Double(totalWords) / count : 0
        let avgSentenceLen = totalSentences > 0 ? Double(totalWords) / Double(totalSentences) : 0
        let emojiRate = count > 0 ? Double(totalEmoji) / count : 0

        return VoiceProfile(
            greeting: greeting,
            signoff: signoff,
            formalityScore: formality(bodies: bodies, greeting: greeting),
            avgSentenceLength: avgSentenceLen,
            avgWordsPerMessage: avgWords,
            emojiRate: emojiRate,
            commonPhrases: VoiceTextStats.topNgrams(bodies, n: 3, limit: 5),
            perDomainOverrides: [:]
        )
    }

    // MARK: - Extraction helpers

    private func firstNonEmptyLine(_ body: String) -> String? {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty })
    }

    private func lastNonEmptyLines(_ body: String) -> [String] {
        body.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Returns the canonical greeting head (capitalized) if the first line opens with one.
    private func greeting(in body: String) -> String? {
        guard let line = firstNonEmptyLine(body) else { return nil }
        let lower = line.lowercased()
        for head in Self.greetingHeads where lower.hasPrefix(head) {
            return head.prefix(1).uppercased() + head.dropFirst()
        }
        return nil
    }

    /// Scans the last few non-empty lines for a known sign-off head, returns canonical form.
    private func signoff(in body: String) -> String? {
        let lines = lastNonEmptyLines(body)
        // Sign-off is usually within the last two non-empty lines (before the name).
        for line in lines.suffix(2).reversed() {
            let lower = line.lowercased()
            for head in Self.signoffHeads where lower.hasPrefix(head) {
                // Reconstruct original casing from the matched prefix length.
                return String(line.prefix(head.count))
            }
        }
        return nil
    }

    /// 0 (casual) ... 1 (formal). Higher for formal greetings, fewer contractions, no emoji.
    private func formality(bodies: [String], greeting: String) -> Double {
        guard !bodies.isEmpty else { return 0.5 }
        var score = 0.5
        let g = greeting.lowercased()
        if g == "dear" { score += 0.25 }
        else if g == "hey" { score -= 0.2 }

        let contractionShare = Double(bodies.filter(VoiceTextStats.containsContraction).count) / Double(bodies.count)
        score -= contractionShare * 0.25

        let emoji = bodies.reduce(0) { $0 + VoiceTextStats.emojiCount($1) }
        if emoji > 0 { score -= 0.15 }

        return min(max(score, 0), 1)
    }

    private func recipientDomain(of message: Message) -> String? {
        guard let first = message.to.first, let at = first.lastIndex(of: "@") else { return nil }
        return String(first[first.index(after: at)...]).lowercased()
    }

    private func mostCommon(_ values: [String]) -> String? {
        guard !values.isEmpty else { return nil }
        var counts: [String: Int] = [:]
        for v in values { counts[v, default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceProfileBuilderTests`
  - **Expected:** all pass. (If `emojiRate == 0.5` fails because `emojiCount` differs on the 👍 fixture, fix `VoiceTextStats.emojiCount` — the rate arithmetic is correct.)
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: VoiceProfileBuilder heuristics with per-domain sub-profiles

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 5 — VoiceProfileStore (persist JSON to voice_profile)

**Files:** `Sources/SenaniVoice/VoiceProfileStore.swift`, `Tests/SenaniVoiceTests/VoiceProfileStoreTests.swift`

`VoiceProfileStore` saves/loads the profile as JSON. It is written against a narrow `VoiceProfilePersistence` seam (see Cross-Package Assumptions) so it is unit-testable without the real DB. A `SenaniDatabase` adapter is provided for production wiring.

- [ ] **Write failing test** `VoiceProfileStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniVoice

@Suite struct VoiceProfileStoreTests {
    @Test func roundTripsProfileThroughPersistence() throws {
        let persistence = InMemoryVoiceProfilePersistence()
        let store = VoiceProfileStore(persistence: persistence)

        var profile = VoiceProfile(greeting: "Hi", signoff: "Cheers,", formalityScore: 0.3,
                                   avgSentenceLength: 10, avgWordsPerMessage: 40, emojiRate: 0.5,
                                   commonPhrases: ["let me know"])
        profile.perDomainOverrides["client.com"] = VoiceProfile(greeting: "Dear", signoff: "Best regards,")

        try store.save(profile)
        let loaded = try store.load()

        #expect(loaded == profile)
    }

    @Test func loadReturnsNilWhenNothingSaved() throws {
        let store = VoiceProfileStore(persistence: InMemoryVoiceProfilePersistence())
        #expect(try store.load() == nil)
    }

    @Test func saveOverwritesPreviousProfile() throws {
        let persistence = InMemoryVoiceProfilePersistence()
        let store = VoiceProfileStore(persistence: persistence)
        try store.save(VoiceProfile(greeting: "Hi"))
        try store.save(VoiceProfile(greeting: "Hey"))
        #expect(try store.load()?.greeting == "Hey")
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceProfileStoreTests`
  - **Expected:** `no type named 'VoiceProfileStore' / 'InMemoryVoiceProfilePersistence'`.
- [ ] **Implement** `VoiceProfileStore.swift`:

```swift
import Foundation
import SenaniStore

/// Narrow seam over the `voice_profile` table so the store is testable without a real DB.
/// The table holds a single JSON blob for the user's profile.
public protocol VoiceProfilePersistence: Sendable {
    func saveProfileJSON(_ data: Data) throws
    func loadProfileJSON() throws -> Data?
}

/// In-memory persistence for unit tests. Reference type so saves are observable.
public final class InMemoryVoiceProfilePersistence: VoiceProfilePersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    public init() {}
    public func saveProfileJSON(_ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        stored = data
    }
    public func loadProfileJSON() throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Production adapter backed by SenaniStore's `voice_profile` table.
///
/// ASSUMPTION: `SenaniDatabase` can execute the upsert/select below. Reconcile the two
/// method bodies with SenaniStore's real query API at integration time; the row shape is
/// a single-row table keyed by a constant id holding the JSON text. If SenaniStore exposes
/// a typed accessor for `voice_profile`, prefer it and delete the raw SQL.
public struct SenaniDatabaseVoiceProfilePersistence: VoiceProfilePersistence {
    private let db: SenaniDatabase
    public init(database: SenaniDatabase) { self.db = db }

    public func saveProfileJSON(_ data: Data) throws {
        // INTEGRATION POINT — replace with SenaniStore's real write API.
        // Intended SQL:
        //   INSERT INTO voice_profile (id, json) VALUES (1, ?)
        //   ON CONFLICT(id) DO UPDATE SET json = excluded.json;
        try VoiceProfileSQL.write(db, json: data)
    }

    public func loadProfileJSON() throws -> Data? {
        // INTEGRATION POINT — replace with SenaniStore's real read API.
        //   SELECT json FROM voice_profile WHERE id = 1;
        try VoiceProfileSQL.read(db)
    }
}

/// Saves/loads a VoiceProfile as JSON through any VoiceProfilePersistence.
public struct VoiceProfileStore: Sendable {
    private let persistence: any VoiceProfilePersistence
    public init(persistence: any VoiceProfilePersistence) { self.persistence = persistence }

    public func save(_ profile: VoiceProfile) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try persistence.saveProfileJSON(try encoder.encode(profile))
    }

    public func load() throws -> VoiceProfile? {
        guard let data = try persistence.loadProfileJSON() else { return nil }
        return try JSONDecoder().decode(VoiceProfile.self, from: data)
    }
}
```

- [ ] **Also implement** the SQL bridge `VoiceProfileSQL` in the same file as a clearly-marked TODO seam so the adapter compiles. It must NOT be exercised by unit tests (only the in-memory persistence is). If, at integration time, `SenaniDatabase`'s API is known, fill these in:

```swift
/// INTEGRATION SEAM. These two functions are the ONLY place that touches the real DB.
/// They throw `VoiceProfileSQL.Unwired` until reconciled with SenaniStore's query API,
/// so the adapter type compiles and links but signals clearly if used before wiring.
enum VoiceProfileSQL {
    struct Unwired: Error, CustomStringConvertible {
        var description: String { "SenaniDatabaseVoiceProfilePersistence not yet wired to SenaniStore's query API" }
    }
    static func write(_ db: SenaniDatabase, json: Data) throws { throw Unwired() }
    static func read(_ db: SenaniDatabase) throws -> Data? { throw Unwired() }
}
```

> Rationale: keeps `SenaniVoice` honest about the one real cross-package coupling without faking SenaniStore. Unit tests cover all profile-store logic via `InMemoryVoiceProfilePersistence`; the DB adapter is wired in a later integration ticket once SenaniStore's API is fixed.

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceProfileStoreTests`
  - **Expected:** 3 tests pass.
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: VoiceProfileStore with persistence seam + SenaniDatabase adapter

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 6 — VoiceExemplarIndexer (embed sent mail into the vector index)

**Files:** `Sources/SenaniVoice/VoiceExemplarIndexer.swift`, `Tests/SenaniVoiceTests/VoiceExemplarIndexerTests.swift`

Embeds selected sent messages via an `Embedder` and inserts them into a `VectorIndex` with `{domain, messageId}` metadata. Selection: `isFromUser == true`, non-empty body; cap per index call (default 200, most recent first).

- [ ] **Write failing test** `VoiceExemplarIndexerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniVoice
import SenaniStore
import SenaniInference

@Suite struct VoiceExemplarIndexerTests {
    @Test func indexesOnlySentMailWithMetadata() async throws {
        let index = InMemoryVectorIndex()
        let indexer = VoiceExemplarIndexer(embedder: FakeEmbedder(), index: index)

        let messages = Fixtures.allSent + [Fixtures.received("r", from: "x@client.com")]
        let count = try await indexer.index(messages: messages)

        #expect(count == Fixtures.allSent.count)            // received mail skipped
        // Each inserted exemplar is retrievable by an embedded query.
        let query = try await FakeEmbedder().embed("Dear Mr. Rao, proposal")
        let hits = index.search(vector: query, k: 10)
        #expect(hits.contains { $0.id == "c" })
    }

    @Test func storesRecipientDomainInMetadata() async throws {
        let index = InMemoryVectorIndex()
        let indexer = VoiceExemplarIndexer(embedder: FakeEmbedder(), index: index)
        _ = try await indexer.index(messages: Fixtures.clientSent)
        // Metadata is queried via the conditioner later; here assert the index recorded it.
        #expect(index.metadata(for: "c")?["domain"] == "client.com")
        #expect(index.metadata(for: "c")?["messageId"] == "c")
    }

    @Test func emptyInputInsertsNothing() async throws {
        let index = InMemoryVectorIndex()
        let indexer = VoiceExemplarIndexer(embedder: FakeEmbedder(), index: index)
        #expect(try await indexer.index(messages: []) == 0)
    }
}
```

> **ASSUMPTION ON `InMemoryVectorIndex.metadata(for:)`:** the test uses a `metadata(for:)` accessor. If SenaniStore's `InMemoryVectorIndex` does not expose stored metadata, replace the two metadata assertions with a search-returns-id assertion (the indexer still inserts metadata; we just cannot read it back through this fake). Note this in the test as a comment and keep the `count`/searchability assertions, which do not depend on the accessor.

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceExemplarIndexerTests`
  - **Expected:** `no type named 'VoiceExemplarIndexer'`.
- [ ] **Implement** `VoiceExemplarIndexer.swift`:

```swift
import Foundation
import SenaniRules
import SenaniStore
import SenaniInference

/// Embeds the user's sent messages and inserts them into a VectorIndex as voice
/// exemplars, tagged with recipient domain + message id so the conditioner can
/// retrieve audience-appropriate examples at draft time.
public struct VoiceExemplarIndexer: Sendable {
    private let embedder: any Embedder
    private let index: any VectorIndex
    private let maxExemplars: Int

    public init(embedder: any Embedder, index: any VectorIndex, maxExemplars: Int = 200) {
        self.embedder = embedder
        self.index = index
        self.maxExemplars = maxExemplars
    }

    /// Returns the number of exemplars inserted.
    @discardableResult
    public func index(messages: [Message]) async throws -> Int {
        let exemplars = messages
            .filter { $0.isFromUser && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.date > $1.date }
            .prefix(maxExemplars)

        var inserted = 0
        for m in exemplars {
            let vector = try await embedder.embed(Self.exemplarText(m))
            index.insert(
                id: m.id,
                vector: vector,
                metadata: ["domain": recipientDomain(of: m) ?? "", "messageId": m.id]
            )
            inserted += 1
        }
        return inserted
    }

    /// Subject + body is what we want the voice signal from.
    static func exemplarText(_ m: Message) -> String {
        m.subject.isEmpty ? m.body : "\(m.subject)\n\n\(m.body)"
    }

    private func recipientDomain(of message: Message) -> String? {
        guard let first = message.to.first, let at = first.lastIndex(of: "@") else { return nil }
        return String(first[first.index(after: at)...]).lowercased()
    }
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceExemplarIndexerTests`
  - **Expected:** all pass (adjust per the metadata-accessor assumption if needed).
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: VoiceExemplarIndexer embeds sent mail into the vector index

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 7 — VoiceConditioner (profile selection + retrieval + prompt prefix)

**Files:** `Sources/SenaniVoice/VoiceConditioner.swift`, `Tests/SenaniVoiceTests/VoiceConditionerTests.swift`

Given a `DraftingContext` (recipient address + topic/thread snippet), it: (a) picks the domain override or base profile, (b) embeds the query and retrieves k nearest exemplars from the index, (c) assembles a conditioning **prompt prefix** that embeds the profile traits + retrieved exemplars. The package does NOT call `TextGenerator` to draft — it only produces the prefix. (We still accept a `TextGenerator` in the type to honor the contract surface, but the prefix assembly is pure and independently tested; a small `previewDraft` convenience that calls `generate` is optional and tested only via `FakeTextGenerator` for the pass-through.)

- [ ] **Write failing test** `VoiceConditionerTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniVoice
import SenaniStore
import SenaniInference

@Suite struct VoiceConditionerTests {
    private func indexedConditioner() async throws -> (VoiceConditioner, VoiceProfile) {
        let index = InMemoryVectorIndex()
        try await VoiceExemplarIndexer(embedder: FakeEmbedder(), index: index).index(messages: Fixtures.allSent)
        let profile = VoiceProfileBuilder().build(from: Fixtures.allSent)
        let conditioner = VoiceConditioner(embedder: FakeEmbedder(), index: index, generator: FakeTextGenerator())
        return (conditioner, profile)
    }

    @Test func choosesDomainOverrideWhenRecipientDomainMatches() async throws {
        let (conditioner, profile) = try await indexedConditioner()
        let ctx = DraftingContext(recipient: "cfo@client.com", topic: "the proposal")
        let prefix = try await conditioner.conditioningPrefix(for: ctx, profile: profile, k: 2)
        // Client override greeting/signoff must appear, not the casual base ones.
        #expect(prefix.contains("Dear"))
        #expect(prefix.contains("Best regards,"))
    }

    @Test func fallsBackToBaseProfileForUnknownDomain() async throws {
        let (conditioner, profile) = try await indexedConditioner()
        let ctx = DraftingContext(recipient: "stranger@unknown.org", topic: "hello")
        let prefix = try await conditioner.conditioningPrefix(for: ctx, profile: profile, k: 2)
        #expect(prefix.contains(profile.signoff))   // base sign-off
    }

    @Test func embedsRetrievedExemplarsIntoPrefix() async throws {
        let (conditioner, profile) = try await indexedConditioner()
        let ctx = DraftingContext(recipient: "cfo@client.com", topic: "Dear Mr. Rao proposal follow up")
        let prefix = try await conditioner.conditioningPrefix(for: ctx, profile: profile, k: 2)
        #expect(prefix.contains("EXAMPLES OF MY PAST EMAILS"))
        // At least one client exemplar body fragment is present.
        #expect(prefix.contains("proposal"))
    }

    @Test func prefixStatesItIsAStyleInstructionNotContent() async throws {
        let (conditioner, profile) = try await indexedConditioner()
        let ctx = DraftingContext(recipient: "dev@quantana.in", topic: "ship it")
        let prefix = try await conditioner.conditioningPrefix(for: ctx, profile: profile, k: 1)
        #expect(prefix.lowercased().contains("write in my voice"))
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceConditionerTests`
  - **Expected:** `no type named 'VoiceConditioner' / 'DraftingContext'`.
- [ ] **Implement** `VoiceConditioner.swift`:

```swift
import Foundation
import SenaniStore
import SenaniInference

/// What the caller (Reply Drafter / Assistant) knows when asking for a voice-conditioned prefix.
public struct DraftingContext: Sendable, Equatable {
    public let recipient: String        // full email address
    public let topic: String            // thread snippet / subject / instruction
    public init(recipient: String, topic: String) {
        self.recipient = recipient
        self.topic = topic
    }
    /// Lowercased host after the last "@", or "".
    public var recipientDomain: String {
        guard let at = recipient.lastIndex(of: "@") else { return "" }
        return String(recipient[recipient.index(after: at)...]).lowercased()
    }
}

/// Produces a conditioning PROMPT PREFIX that instructs a text generator to write in the
/// user's voice, embedding the chosen profile's traits + retrieved exemplars.
/// It does NOT generate the draft — that belongs to the Reply Drafter / Assistant.
public struct VoiceConditioner: Sendable {
    private let embedder: any Embedder
    private let index: any VectorIndex
    private let generator: any TextGenerator

    public init(embedder: any Embedder, index: any VectorIndex, generator: any TextGenerator) {
        self.embedder = embedder
        self.index = index
        self.generator = generator
    }

    /// (a) pick profile, (b) retrieve k exemplars, (c) assemble the prefix.
    public func conditioningPrefix(
        for context: DraftingContext,
        profile: VoiceProfile,
        k: Int = 3
    ) async throws -> String {
        let chosen = profile.perDomainOverrides[context.recipientDomain] ?? profile
        let exemplars = try await retrieveExemplars(for: context, k: k)
        return Self.assemblePrefix(profile: chosen, exemplars: exemplars)
    }

    /// Retrieves nearest exemplar ids for the query, mapped back to their stored text if available.
    /// Returns the exemplar ids when the fake index cannot return text — the prefix still lists them.
    private func retrieveExemplars(for context: DraftingContext, k: Int) async throws -> [String] {
        guard k > 0 else { return [] }
        let query = try await embedder.embed("\(context.topic)")
        let hits = index.search(vector: query, k: k)
        // Prefer stored exemplar text via metadata accessor if the index exposes one.
        return hits.map { hit in
            if let text = (index as? InMemoryVectorIndex)?.metadata(for: hit.id)?["text"] {
                return text
            }
            return hit.id
        }
    }

    /// Pure prompt assembly — independently testable.
    static func assemblePrefix(profile: VoiceProfile, exemplars: [String]) -> String {
        var lines: [String] = []
        lines.append("You are writing an email AS ME. Write in my voice and match my style.")
        lines.append("")
        lines.append("MY STYLE:")
        if !profile.greeting.isEmpty { lines.append("- Open with a greeting like: \"\(profile.greeting)\"") }
        if !profile.signoff.isEmpty { lines.append("- Sign off with: \"\(profile.signoff)\"") }
        lines.append("- Formality: \(formalityLabel(profile.formalityScore)) (\(String(format: "%.2f", profile.formalityScore)) on a 0–1 scale)")
        if profile.avgSentenceLength > 0 {
            lines.append("- Typical sentence length: ~\(Int(profile.avgSentenceLength.rounded())) words")
        }
        if profile.emojiRate > 0 {
            lines.append("- I sometimes use emoji (about \(String(format: "%.1f", profile.emojiRate)) per email)")
        } else {
            lines.append("- I do not use emoji")
        }
        if !profile.commonPhrases.isEmpty {
            lines.append("- Phrases I use: " + profile.commonPhrases.map { "\"\($0)\"" }.joined(separator: ", "))
        }
        if !exemplars.isEmpty {
            lines.append("")
            lines.append("EXAMPLES OF MY PAST EMAILS (match this tone, do not copy verbatim):")
            for (i, ex) in exemplars.enumerated() {
                lines.append("Example \(i + 1):")
                lines.append(ex)
                lines.append("")
            }
        }
        lines.append("Now write in my voice:")
        return lines.joined(separator: "\n")
    }

    private static func formalityLabel(_ score: Double) -> String {
        switch score {
        case ..<0.34: return "casual"
        case ..<0.67: return "neutral"
        default: return "formal"
        }
    }
}
```

> **NOTE on exemplar text:** the prefix lists whatever the index returns for each hit. For the exemplar text to appear verbatim (so `prefix.contains("proposal")` holds robustly), have `VoiceExemplarIndexer` ALSO store the exemplar text in metadata under key `"text"` (add `"text": Self.exemplarText(m)` to the metadata dict in Task 6) IF `InMemoryVectorIndex` preserves arbitrary metadata. If it does not, the conditioner falls back to listing ids and the test's `prefix.contains("proposal")` assertion should instead assert `prefix.contains("EXAMPLES OF MY PAST EMAILS")` plus a hit id. **Reconcile both Task 6 and this test against the real `InMemoryVectorIndex` metadata behavior in one go.**

- [ ] If storing `"text"` metadata: go back to Task 6's implementation and add `"text": Self.exemplarText(m)` to the metadata dictionary, then re-run Task 6 tests to confirm still green.
- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceConditionerTests`
  - **Expected:** all pass.
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: VoiceConditioner builds voice prompt prefix from profile + exemplars

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 8 — VoiceOverride + applyOverride(_:to:) (chat-adjustable profile)

**Files:** `Sources/SenaniVoice/VoiceOverride.swift`, `Tests/SenaniVoiceTests/VoiceOverrideTests.swift`

Models chat instructions as structured edits and applies them. Cases: `setSignoff(String)`, `setGreeting(String)`, `setConciseness(Conciseness)` (adjusts `avgSentenceLength`/`avgWordsPerMessage` + a hint phrase), and `perDomain(domain: String, override: VoiceOverride)` (applies a nested override to a specific domain sub-profile, creating it from base if absent). Then persists via `VoiceProfileStore`.

- [ ] **Write failing test** `VoiceOverrideTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniVoice

@Suite struct VoiceOverrideTests {
    @Test func setSignoffChangesSignoff() {
        var p = VoiceProfile(greeting: "Hi", signoff: "Best,")
        let out = applyOverride(.setSignoff(""), to: p)        // "drop the Best, sign-off"
        #expect(out.signoff == "")
        p = applyOverride(.setSignoff("Cheers,"), to: p)
        #expect(p.signoff == "Cheers,")
    }

    @Test func setGreetingChangesGreeting() {
        let p = VoiceProfile(greeting: "Hey")
        #expect(applyOverride(.setGreeting("Hello"), to: p).greeting == "Hello")
    }

    @Test func moreConciseLowersLengths() {
        let p = VoiceProfile(avgSentenceLength: 20, avgWordsPerMessage: 120)
        let out = applyOverride(.setConciseness(.concise), to: p)
        #expect(out.avgSentenceLength < 20)
        #expect(out.avgWordsPerMessage < 120)
    }

    @Test func perDomainAppliesNestedOverrideAndCreatesSubProfile() {
        let base = VoiceProfile(greeting: "Hey", signoff: "Cheers,", avgWordsPerMessage: 100)
        // "be more concise with clients"
        let out = applyOverride(.perDomain(domain: "client.com", override: .setConciseness(.concise)), to: base)
        let sub = out.perDomainOverrides["client.com"]
        #expect(sub != nil)
        #expect(sub!.avgWordsPerMessage < base.avgWordsPerMessage)
        // base profile is untouched
        #expect(out.avgWordsPerMessage == 100)
    }

    @Test func overridePersistsThroughStore() throws {
        let store = VoiceProfileStore(persistence: InMemoryVoiceProfilePersistence())
        try store.save(VoiceProfile(signoff: "Best,"))
        let current = try store.load()!
        try store.save(applyOverride(.setSignoff(""), to: current))
        #expect(try store.load()?.signoff == "")
    }
}
```

- [ ] **Run-to-fail:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceOverrideTests`
  - **Expected:** `no type named 'VoiceOverride'` / `applyOverride` unresolved.
- [ ] **Implement** `VoiceOverride.swift`:

```swift
import Foundation

/// A structured edit to a VoiceProfile, produced from a chat instruction
/// (e.g. "drop the 'Best,' sign-off", "be more concise with clients").
public indirect enum VoiceOverride: Sendable, Equatable {
    public enum Conciseness: Sendable, Equatable { case concise, normal, verbose }

    case setSignoff(String)
    case setGreeting(String)
    case setConciseness(Conciseness)
    case perDomain(domain: String, override: VoiceOverride)
}

/// Applies a structured override to a profile, returning a new profile (value semantics).
public func applyOverride(_ override: VoiceOverride, to profile: VoiceProfile) -> VoiceProfile {
    var result = profile
    switch override {
    case .setSignoff(let s):
        result.signoff = s
    case .setGreeting(let g):
        result.greeting = g
    case .setConciseness(let level):
        let factor: Double
        switch level {
        case .concise: factor = 0.7
        case .normal:  factor = 1.0
        case .verbose: factor = 1.3
        }
        if result.avgSentenceLength > 0 { result.avgSentenceLength *= factor }
        if result.avgWordsPerMessage > 0 { result.avgWordsPerMessage *= factor }
    case .perDomain(let domain, let inner):
        let baseForDomain = result.perDomainOverrides[domain] ?? strippedCopy(of: result)
        result.perDomainOverrides[domain] = applyOverride(inner, to: baseForDomain)
    }
    return result
}

/// A domain sub-profile inherits the base traits but never its own nested overrides.
private func strippedCopy(of profile: VoiceProfile) -> VoiceProfile {
    var copy = profile
    copy.perDomainOverrides = [:]
    return copy
}
```

- [ ] **Run-to-pass:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test --filter VoiceOverrideTests`
  - **Expected:** all pass.
- [ ] **Commit:**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: VoiceOverride structured edits + applyOverride(_:to:)

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Task 9 — Full suite green + public surface check

**Files:** none (verification)

- [ ] **Run full suite:** `cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && swift test`
  - **Expected:** all suites pass, 0 failures, strict-concurrency clean (no warnings-as-errors triggers).
- [ ] **Confirm public surface** compiles as the documented contract: `VoiceProfile`, `VoiceProfileBuilder`, `VoiceProfileStore`, `VoiceProfilePersistence` (+ `InMemoryVoiceProfilePersistence`, `SenaniDatabaseVoiceProfilePersistence`), `VoiceExemplarIndexer`, `VoiceConditioner` (+ `DraftingContext`), `VoiceOverride` (+ `applyOverride`). Optionally `import SenaniVoice` in a scratch test to verify nothing leaked as `internal` that should be `public`.
- [ ] **Commit (if any cleanup):**
```
cd /Users/vishalkumar/Downloads/qmail/Packages/SenaniVoice && git add -A && git commit -q -m "$(cat <<'EOF'
SenaniVoice: full suite green; public contract verified

Generated with [Claude Code](https://claude.ai/code)
via [Happy](https://happy.engineering)

Co-Authored-By: Claude <noreply@anthropic.com>
Co-Authored-By: Happy <yesreply@happy.engineering>
EOF
)"
```

---

## Self-Review

- **Spec §9 coverage:**
  - Extract style signals (greeting/sign-off, formality, sentence length, emoji habits, common phrases, per-domain variation) → Task 4 `VoiceProfileBuilder` + Task 2 stats. ✅
  - Store compact Voice Profile in local store (`voice_profile`) → Task 5 `VoiceProfileStore` (+ `SenaniDatabase` adapter seam). ✅
  - Exemplars in the vector index → Task 6 `VoiceExemplarIndexer`. ✅
  - Use at draft time via RAG (retrieve closest sent + condition the model) → Task 7 `VoiceConditioner` produces the conditioning **prefix** (drafting itself is out of scope, as specified). ✅
  - Incremental refresh → builder + indexer are pure/idempotent over any `[Message]` slice; re-running on new sent mail refreshes. (No separate task needed; the API supports it. A scheduled refresh job lives in the app layer.) ✅
  - Chat-adjustable overrides → Task 8 `VoiceOverride` + `applyOverride`, persisted via the store. ✅
  - Fully on-device, profile in user's SQLite → no network; only deps are local packages. ✅
- **Constraints:** Nothing leaves the Mac (no network anywhere in this package); approval-first is upstream (this package only produces a prompt prefix, never sends); on-device (fakes in tests, MLX/Gemma in prod via the `Embedder`/`TextGenerator` seams); auditable (deterministic, value-typed transforms). ✅
- **Testability rule:** every component is unit-tested with fixtures + `FakeEmbedder`/`FakeTextGenerator` + `InMemoryVectorIndex` + `InMemoryVoiceProfilePersistence`. No real model required. ✅
- **TDD shape:** each task is REAL failing test → run-to-fail → minimal REAL impl → run-to-pass → REAL git commit. No placeholders in shipped code. ✅
- **Risks / things to reconcile at execution time (all isolated to thin seams):**
  1. `SenaniDatabase` query API — confined to `VoiceProfileSQL.write/read` (Task 5). The rest of the store logic is tested via in-memory persistence.
  2. `InMemoryVectorIndex` metadata read-back — Tasks 6 & 7 note the fallback if `metadata(for:)` / arbitrary metadata is unavailable; core assertions (insert count, searchability, prefix structure) do not depend on it.
  3. `FakeEmbedder` determinism — if it returns constant vectors, retrieval-ordering assertions soften to membership assertions (noted in Task 6).
  4. Sibling packages must exist before `swift build` — Task 0 verifies and STOPs with a clear blocker rather than faking them.
- **Out of scope (correctly):** actual draft generation/sending, MLX wiring, the `voice_profile` migration (owned by SenaniStore), scheduling of incremental refresh (app layer).
