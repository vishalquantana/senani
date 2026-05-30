# SenaniDocs — Document Parse → Extract → Index → Insights Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `SenaniDocs` Swift package — the on-device pipeline that turns an email attachment (PDF or image) into parsed text, LLM-extracted structured fields, persisted `documents`/`document_fields` rows + embedded vector chunks, and chat-queryable insights — with every piece of *logic* fully unit-tested behind injectable seams and the real liteparse Rust FFI exercised only by a separately-gated integration test.

**Architecture:** A standalone SPM library (`SenaniDocs`) depending on sibling path packages `../SenaniRules`, `../SenaniStore`, `../SenaniInference`. Parsing lives behind a `DocumentParser` protocol seam: `LiteParseDocumentParser` wraps the vendored liteparse Rust core via a C FFI target (`Clibliteparse`, built by a `cargo` script) and is integration-tested only; a `FakeDocumentParser` returns canned text so all extraction/indexing/search logic is deterministically unit-tested. `DocumentExtractor` uses `TextGenerator.generateJSON` with a `JSONSchema` to pull `ExtractedFields`; `DocumentIndexer` persists rows via `SenaniDatabase` and embeds text chunks into a `VectorIndex` via `Embedder`; `DocumentSearch` answers structured field queries and semantic queries; and a `DocumentPipeline` façade ties parse→extract→index for one attachment so the `parseDoc` action handler can call it.

**Tech Stack:** Swift 6.2 (swift-tools 6.0, strict concurrency), Swift Package Manager, Swift Testing (`import Testing`, ships with the toolchain — no external dependency), macOS 14. PDF/image text extraction via the liteparse Rust core (PDFium + Tesseract OCR bundled) linked through a C FFI target. Path-dependency packages: `SenaniRules`, `SenaniStore`, `SenaniInference`.

**Working directory:** All `swift` commands run from `Packages/SenaniDocs/` unless stated otherwise. All `git` commands run from the repository root and use repo-relative paths.

**Design spec:** `docs/superpowers/specs/2026-05-31-rules-engine-and-chat-assistant-design.md` (this plan implements **§7 Attachment parse → extract → index → insights**).

---

## File Structure

```
Packages/SenaniDocs/
  Package.swift                    # path deps on SenaniRules/SenaniStore/SenaniInference; Clibliteparse wiring (Task 8)
  Sources/
    SenaniDocs/
      ParsedDocument.swift         # ParsedDocument + LayoutBlock (parser output model)
      DocumentParser.swift         # DocumentParser protocol + DocumentParseError
      ExtractedFields.swift        # ExtractedFields struct (+ DocumentType)
      DocumentExtractor.swift      # ExtractedFields extraction via TextGenerator.generateJSON
      Chunker.swift                # pure text chunking used by the indexer
      DocumentIndexer.swift        # persists documents/document_fields rows + embeds chunks into VectorIndex
      DocumentSearch.swift         # structured field queries + semantic search insights
      DocumentPipeline.swift       # façade: parse -> extract -> index for one attachment
      LiteParseDocumentParser.swift# real Rust FFI parser (integration-tested only; Task 8)
    Clibliteparse/                 # C FFI shim target for the liteparse static lib (Task 8)
      include/
        liteparse.h
        module.modulemap
  Scripts/
    build-liteparse.sh             # vendors + cargo-builds the static lib (Task 8)
  Tests/
    SenaniDocsTests/
      FakeDocumentParser.swift     # test helper: canned ParsedDocument (test target only)
      ParsedDocumentTests.swift
      ExtractedFieldsTests.swift
      DocumentExtractorTests.swift
      ChunkerTests.swift
      DocumentIndexerTests.swift
      DocumentSearchTests.swift
      DocumentPipelineTests.swift
    SenaniDocsIntegrationTests/
      LiteParseIntegrationTests.swift  # gated by SENANI_LITEPARSE_SAMPLE_PDF; real FFI
```

Each file has one responsibility; collaborators that change together live together. The liteparse FFI bridging (real parser + C target + cargo build) is fully isolated in **Task 8** so every other task is independent of it and builds/tests with no Rust toolchain present.

### Assumed PUBLIC contracts from sibling packages (do not redefine here)
- **SenaniStore:** `SenaniDatabase` (already migrates `documents` and `document_fields` tables); `VectorIndex` protocol (`insert(id:String, vector:[Float], metadata:[String:String])`, `search(vector:[Float], k:Int) -> [(id:String, distance:Float)]`); `InMemoryVectorIndex` (used in unit tests).
- **SenaniInference:** `TextGenerator` (`generate(prompt:String, maxTokens:Int) async throws -> String`, `generateJSON(prompt:String, schema:JSONSchema) async throws -> String`); `Embedder` (`embed(_:String) async throws -> [Float]`); `JSONSchema`; test fakes `FakeTextGenerator` / `FakeEmbedder`.
- **SenaniRules:** linked as a path dependency per project convention (the `parseDoc` action this pipeline backs lives in the Action Kernel there). `SenaniDocs` does not import SenaniRules types in this slice.

> **DB access assumption (used by Tasks 5 & 6):** `SenaniDatabase` exposes an in-memory constructor for tests and the following row-level API. If the real `SenaniDatabase` names differ, adapt the call sites in `DocumentIndexer`/`DocumentSearch` and their tests to the actual API — the *logic and assertions* are what matter:
> ```swift
> public init(inMemory: Bool) throws
> // documents(id, source_path, document_type, parsed_text, created_at)
> func insertDocument(id: String, sourcePath: String, documentType: String, parsedText: String, createdAt: Date) throws
> func documentRow(id: String) throws -> DocumentRow?
> // document_fields(document_id, key, value)
> func insertDocumentField(documentId: String, key: String, value: String) throws
> func documentFields(documentId: String) throws -> [DocumentFieldRow]
> // structured insight query support
> func documentsByType(_ type: String) throws -> [DocumentRow]
> func documentFieldsByKeyValueRange(key: String, min: String, max: String) throws -> [DocumentFieldRow]
> ```
> `DocumentRow` and `DocumentFieldRow` are assumed to be public `Decodable`-ish structs on `SenaniStore`. Where this plan needs a value object it cannot assume, it defines its own (`StoredDocument`, see Task 6) and maps from the store rows.

---

### Task 1: Package scaffold + ParsedDocument model

**Files:**
- Create: `Packages/SenaniDocs/Package.swift`
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/ParsedDocument.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/ParsedDocumentTests.swift`

- [ ] **Step 1: Create the package manifest (no liteparse target yet — added in Task 8)**

Create `Packages/SenaniDocs/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SenaniDocs",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SenaniDocs", targets: ["SenaniDocs"]),
    ],
    dependencies: [
        .package(path: "../SenaniRules"),
        .package(path: "../SenaniStore"),
        .package(path: "../SenaniInference"),
    ],
    targets: [
        .target(
            name: "SenaniDocs",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
            ]
        ),
        .testTarget(
            name: "SenaniDocsTests",
            dependencies: ["SenaniDocs"]
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/ParsedDocumentTests.swift`:

```swift
import Testing
@testable import SenaniDocs

@Suite struct ParsedDocumentTests {
    @Test func storesFullTextAndOptionalBlocks() {
        let doc = ParsedDocument(
            fullText: "Invoice 42",
            blocks: [
                LayoutBlock(page: 0, text: "Invoice 42", boundingBox: nil)
            ]
        )
        #expect(doc.fullText == "Invoice 42")
        #expect(doc.blocks.count == 1)
        #expect(doc.blocks[0].page == 0)
        #expect(doc.blocks[0].text == "Invoice 42")
        #expect(doc.blocks[0].boundingBox == nil)
    }

    @Test func blocksDefaultToEmpty() {
        let doc = ParsedDocument(fullText: "plain text only")
        #expect(doc.fullText == "plain text only")
        #expect(doc.blocks.isEmpty)
    }

    @Test func boundingBoxIsCarried() {
        let box = LayoutBlock.BoundingBox(x: 1, y: 2, width: 3, height: 4)
        let block = LayoutBlock(page: 2, text: "x", boundingBox: box)
        #expect(block.boundingBox == box)
        #expect(block.page == 2)
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — compile error, `cannot find 'ParsedDocument' in scope` (and `LayoutBlock`).

- [ ] **Step 4: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/ParsedDocument.swift`:

```swift
import Foundation

/// One spatial block of parsed text (a line/region on a page), as produced by liteparse.
public struct LayoutBlock: Sendable, Equatable {
    /// Optional spatial position of the block on its page, in the parser's coordinate space.
    public struct BoundingBox: Sendable, Equatable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// Zero-based page index the block came from.
    public let page: Int
    public let text: String
    public let boundingBox: BoundingBox?

    public init(page: Int, text: String, boundingBox: BoundingBox?) {
        self.page = page
        self.text = text
        self.boundingBox = boundingBox
    }
}

/// The output of parsing one document: the concatenated full text plus optional
/// page/layout blocks. Decoupled from any parser implementation so it is trivial
/// to construct in tests via `FakeDocumentParser`.
public struct ParsedDocument: Sendable, Equatable {
    public let fullText: String
    public let blocks: [LayoutBlock]

    public init(fullText: String, blocks: [LayoutBlock] = []) {
        self.fullText = fullText
        self.blocks = blocks
    }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — all three `ParsedDocumentTests` tests pass. (Building also resolves the three path dependencies; if resolution fails because a sibling package is missing, stop and confirm `../SenaniStore` and `../SenaniInference` exist before continuing.)

- [ ] **Step 6: Commit**

```bash
git add Packages/SenaniDocs/Package.swift Packages/SenaniDocs/Sources/SenaniDocs/ParsedDocument.swift Packages/SenaniDocs/Tests/SenaniDocsTests/ParsedDocumentTests.swift
git commit -m "feat(docs): scaffold SenaniDocs package + ParsedDocument model" --trailer "Co-Authored-By: Claude <noreply@anthropic.com>"
```

> Use this exact multi-line commit message body on every commit in this plan (the `-m` subject line varies per task):
> ```
> <subject>
>
> Generated with [Claude Code](https://claude.ai/code)
> via [Happy](https://happy.engineering)
>
> Co-Authored-By: Claude <noreply@anthropic.com>
> Co-Authored-By: Happy <yesreply@happy.engineering>
> ```
> Apply it by writing the message to a file and using `git commit -F`, or by passing the body via repeated `-m` flags. Subsequent tasks show only the subject line for brevity; always include the full trailer block.

---

### Task 2: DocumentParser protocol seam + FakeDocumentParser test helper

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/DocumentParser.swift`
- Create: `Packages/SenaniDocs/Tests/SenaniDocsTests/FakeDocumentParser.swift`

- [ ] **Step 1: Write the failing test (the FakeDocumentParser IS the seam exercise)**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/FakeDocumentParser.swift`:

```swift
import Foundation
@testable import SenaniDocs

/// Test double for `DocumentParser`: returns a canned `ParsedDocument` and records
/// the URL it was asked to parse, or throws a canned error. Used by every logic test
/// so the real liteparse FFI is never touched in unit tests.
final class FakeDocumentParser: DocumentParser, @unchecked Sendable {
    var result: ParsedDocument
    var errorToThrow: Error?
    private(set) var parsedURLs: [URL] = []

    init(result: ParsedDocument = ParsedDocument(fullText: ""), errorToThrow: Error? = nil) {
        self.result = result
        self.errorToThrow = errorToThrow
    }

    func parse(fileURL: URL) async throws -> ParsedDocument {
        parsedURLs.append(fileURL)
        if let errorToThrow { throw errorToThrow }
        return result
    }
}

import Testing

@Suite struct DocumentParserSeamTests {
    @Test func fakeReturnsCannedResultAndRecordsURL() async throws {
        let parser = FakeDocumentParser(result: ParsedDocument(fullText: "hello"))
        let url = URL(fileURLWithPath: "/tmp/a.pdf")
        let parsed = try await parser.parse(fileURL: url)
        #expect(parsed.fullText == "hello")
        #expect(parser.parsedURLs == [url])
    }

    @Test func fakeThrowsConfiguredError() async {
        let parser = FakeDocumentParser(errorToThrow: DocumentParseError.unreadable)
        await #expect(throws: DocumentParseError.self) {
            _ = try await parser.parse(fileURL: URL(fileURLWithPath: "/tmp/x.pdf"))
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find type 'DocumentParser' in scope` and `cannot find 'DocumentParseError' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/DocumentParser.swift`:

```swift
import Foundation

/// Errors a parser may surface. The real liteparse parser maps FFI failures onto these.
public enum DocumentParseError: Error, Equatable, Sendable {
    /// The file could not be opened or read.
    case unreadable
    /// The file type is not supported (only PDFs + images are in scope).
    case unsupportedType(String)
    /// The underlying parser failed with a message.
    case backend(String)
}

/// The parsing seam. Production uses `LiteParseDocumentParser` (Rust FFI, Task 8);
/// tests use `FakeDocumentParser`. Only PDFs and images are supported — Office
/// formats (.docx/.pptx/.xlsx) are explicitly out of scope (deferred per spec §7).
public protocol DocumentParser: Sendable {
    func parse(fileURL: URL) async throws -> ParsedDocument
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — `DocumentParserSeamTests` (2 tests) pass; `ParsedDocumentTests` still green.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/DocumentParser.swift Packages/SenaniDocs/Tests/SenaniDocsTests/FakeDocumentParser.swift
git commit -m "feat(docs): DocumentParser protocol seam + FakeDocumentParser test helper"
```

---

### Task 3: ExtractedFields model

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/ExtractedFields.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/ExtractedFieldsTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/ExtractedFieldsTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniDocs

@Suite struct ExtractedFieldsTests {
    @Test func holdsAllInvoiceFields() {
        let due = Date(timeIntervalSince1970: 1_700_000_000)
        let fields = ExtractedFields(
            documentType: .invoice,
            vendor: "Acme LLC",
            invoiceNumber: "INV-42",
            amount: Decimal(string: "1234.56"),
            currency: "USD",
            dueDate: due,
            partyNames: [],
            renewalClause: nil,
            extras: ["po": "PO-9"]
        )
        #expect(fields.documentType == .invoice)
        #expect(fields.vendor == "Acme LLC")
        #expect(fields.invoiceNumber == "INV-42")
        #expect(fields.amount == Decimal(string: "1234.56"))
        #expect(fields.currency == "USD")
        #expect(fields.dueDate == due)
        #expect(fields.extras["po"] == "PO-9")
    }

    @Test func holdsContractFields() {
        let fields = ExtractedFields(
            documentType: .contract,
            partyNames: ["Alice Corp", "Bob Inc"],
            renewalClause: "auto-renews annually unless cancelled 30 days prior"
        )
        #expect(fields.documentType == .contract)
        #expect(fields.partyNames == ["Alice Corp", "Bob Inc"])
        #expect(fields.renewalClause?.contains("auto-renews") == true)
        #expect(fields.amount == nil)
    }

    @Test func defaultsAreEmptyOrNil() {
        let fields = ExtractedFields(documentType: .unknown)
        #expect(fields.vendor == nil)
        #expect(fields.invoiceNumber == nil)
        #expect(fields.amount == nil)
        #expect(fields.partyNames.isEmpty)
        #expect(fields.extras.isEmpty)
    }

    @Test func documentTypeParsesFromRawStringSafely() {
        #expect(DocumentType(rawValue: "invoice") == .invoice)
        #expect(DocumentType(rawValue: "contract") == .contract)
        #expect(DocumentType(rawValue: "wat") == .unknown)
        #expect(DocumentType(rawValue: "") == .unknown)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find 'ExtractedFields'` / `'DocumentType'` in scope.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/ExtractedFields.swift`:

```swift
import Foundation

/// Coarse document classification driving downstream insight queries.
/// `init(rawValue:)` never fails — an unknown/empty string maps to `.unknown`,
/// keeping LLM output handling safe.
public enum DocumentType: String, Sendable, Equatable {
    case invoice
    case contract
    case receipt
    case statement
    case unknown

    public init(rawValue: String) {
        switch rawValue.lowercased() {
        case "invoice": self = .invoice
        case "contract": self = .contract
        case "receipt": self = .receipt
        case "statement": self = .statement
        default: self = .unknown
        }
    }
}

/// Structured fields extracted from a parsed document by `DocumentExtractor`.
/// Every domain-specific field is optional so partial/missing extraction is normal;
/// `extras` carries any additional key/value pairs the model surfaced.
public struct ExtractedFields: Sendable, Equatable {
    public let documentType: DocumentType
    public let vendor: String?
    public let invoiceNumber: String?
    public let amount: Decimal?
    public let currency: String?
    public let dueDate: Date?
    public let partyNames: [String]
    public let renewalClause: String?
    public let extras: [String: String]

    public init(
        documentType: DocumentType,
        vendor: String? = nil,
        invoiceNumber: String? = nil,
        amount: Decimal? = nil,
        currency: String? = nil,
        dueDate: Date? = nil,
        partyNames: [String] = [],
        renewalClause: String? = nil,
        extras: [String: String] = [:]
    ) {
        self.documentType = documentType
        self.vendor = vendor
        self.invoiceNumber = invoiceNumber
        self.amount = amount
        self.currency = currency
        self.dueDate = dueDate
        self.partyNames = partyNames
        self.renewalClause = renewalClause
        self.extras = extras
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — `ExtractedFieldsTests` (4 tests) pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/ExtractedFields.swift Packages/SenaniDocs/Tests/SenaniDocsTests/ExtractedFieldsTests.swift
git commit -m "feat(docs): ExtractedFields + DocumentType model with safe parsing"
```

---

### Task 4: DocumentExtractor (grammar-constrained field extraction via TextGenerator)

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/DocumentExtractor.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentExtractorTests.swift`

This task uses `FakeTextGenerator` from `SenaniInference`. It returns whatever canned JSON string the test configures from `generateJSON(prompt:schema:)`. The extractor's job is: build a `JSONSchema`, call the model, and **safely** decode the JSON into `ExtractedFields` (tolerating missing fields and malformed JSON).

> **FakeTextGenerator assumption:** `SenaniInference.FakeTextGenerator` lets a test set the JSON string returned by `generateJSON`. This plan assumes the shape below; adapt to the real fake's API if its property is named differently:
> ```swift
> let gen = FakeTextGenerator()
> gen.jsonResponse = "{ ... }"   // returned by generateJSON(prompt:schema:)
> ```

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentExtractorTests.swift`:

```swift
import Testing
import Foundation
import SenaniInference
@testable import SenaniDocs

@Suite struct DocumentExtractorTests {
    private func makeExtractor(json: String) -> (DocumentExtractor, FakeTextGenerator) {
        let gen = FakeTextGenerator()
        gen.jsonResponse = json
        return (DocumentExtractor(generator: gen), gen)
    }

    @Test func extractsFullInvoiceFields() async throws {
        let json = """
        {
          "documentType": "invoice",
          "vendor": "Acme LLC",
          "invoiceNumber": "INV-42",
          "amount": "1234.56",
          "currency": "USD",
          "dueDate": "2026-06-15",
          "partyNames": [],
          "renewalClause": null,
          "extras": { "po": "PO-9" }
        }
        """
        let (extractor, _) = makeExtractor(json: json)
        let fields = try await extractor.extract(from: ParsedDocument(fullText: "Invoice INV-42 ..."))

        #expect(fields.documentType == .invoice)
        #expect(fields.vendor == "Acme LLC")
        #expect(fields.invoiceNumber == "INV-42")
        #expect(fields.amount == Decimal(string: "1234.56"))
        #expect(fields.currency == "USD")
        #expect(fields.extras["po"] == "PO-9")
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: fields.dueDate!)
        #expect(comps.year == 2026 && comps.month == 6 && comps.day == 15)
    }

    @Test func extractsContractPartiesAndRenewal() async throws {
        let json = """
        {
          "documentType": "contract",
          "partyNames": ["Alice Corp", "Bob Inc"],
          "renewalClause": "auto-renews annually"
        }
        """
        let (extractor, _) = makeExtractor(json: json)
        let fields = try await extractor.extract(from: ParsedDocument(fullText: "Agreement ..."))
        #expect(fields.documentType == .contract)
        #expect(fields.partyNames == ["Alice Corp", "Bob Inc"])
        #expect(fields.renewalClause == "auto-renews annually")
        #expect(fields.amount == nil)
    }

    @Test func missingFieldsBecomeNilNotErrors() async throws {
        let (extractor, _) = makeExtractor(json: #"{ "documentType": "receipt" }"#)
        let fields = try await extractor.extract(from: ParsedDocument(fullText: "x"))
        #expect(fields.documentType == .receipt)
        #expect(fields.vendor == nil)
        #expect(fields.invoiceNumber == nil)
        #expect(fields.amount == nil)
        #expect(fields.partyNames.isEmpty)
        #expect(fields.extras.isEmpty)
    }

    @Test func unknownDocumentTypeFallsBackSafely() async throws {
        let (extractor, _) = makeExtractor(json: #"{ "documentType": "spaceship" }"#)
        let fields = try await extractor.extract(from: ParsedDocument(fullText: "x"))
        #expect(fields.documentType == .unknown)
    }

    @Test func malformedJSONThrowsExtractionError() async {
        let (extractor, _) = makeExtractor(json: "{ this is not json ")
        await #expect(throws: DocumentExtractionError.self) {
            _ = try await extractor.extract(from: ParsedDocument(fullText: "x"))
        }
    }

    @Test func emptyResponseThrowsExtractionError() async {
        let (extractor, _) = makeExtractor(json: "")
        await #expect(throws: DocumentExtractionError.self) {
            _ = try await extractor.extract(from: ParsedDocument(fullText: "x"))
        }
    }

    @Test func passesDocumentTextIntoPrompt() async throws {
        let (extractor, gen) = makeExtractor(json: #"{ "documentType": "invoice" }"#)
        _ = try await extractor.extract(from: ParsedDocument(fullText: "MAGIC-MARKER-TEXT"))
        #expect(gen.lastPrompt?.contains("MAGIC-MARKER-TEXT") == true)
    }
}
```

> **Second FakeTextGenerator assumption:** the fake records the last prompt as `gen.lastPrompt`. If it does not, drop the `passesDocumentTextIntoPrompt` test or adapt to the available spy property.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find 'DocumentExtractor'` / `'DocumentExtractionError'` in scope.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/DocumentExtractor.swift`:

```swift
import Foundation
import SenaniInference

/// Errors surfaced when structured extraction fails irrecoverably.
public enum DocumentExtractionError: Error, Equatable, Sendable {
    /// The model returned an empty string.
    case emptyResponse
    /// The model returned text that is not valid JSON for the expected shape.
    case malformedJSON
}

/// Extracts structured `ExtractedFields` from parsed document text using a
/// grammar-constrained JSON call against the local model. Missing fields are
/// tolerated (become nil/empty); malformed or empty JSON throws.
public struct DocumentExtractor: Sendable {
    private let generator: any TextGenerator

    public init(generator: any TextGenerator) {
        self.generator = generator
    }

    /// The JSON schema the model is constrained to. Domain fields are optional so
    /// partial extraction is valid.
    static func schema() -> JSONSchema {
        JSONSchema(json: #"""
        {
          "type": "object",
          "properties": {
            "documentType": { "type": "string",
              "enum": ["invoice", "contract", "receipt", "statement", "unknown"] },
            "vendor": { "type": ["string", "null"] },
            "invoiceNumber": { "type": ["string", "null"] },
            "amount": { "type": ["string", "null"] },
            "currency": { "type": ["string", "null"] },
            "dueDate": { "type": ["string", "null"] },
            "partyNames": { "type": "array", "items": { "type": "string" } },
            "renewalClause": { "type": ["string", "null"] },
            "extras": { "type": "object", "additionalProperties": { "type": "string" } }
          },
          "required": ["documentType"]
        }
        """#)
    }

    public func extract(from document: ParsedDocument) async throws -> ExtractedFields {
        let prompt = Self.buildPrompt(text: document.fullText)
        let raw = try await generator.generateJSON(prompt: prompt, schema: Self.schema())
        return try Self.decode(raw)
    }

    static func buildPrompt(text: String) -> String {
        """
        You are extracting structured fields from a business document.
        Return ONLY JSON matching the provided schema.
        Identify the document type and any of: vendor, invoice number, amount,
        currency, due date (ISO-8601 YYYY-MM-DD), contract party names, and any
        renewal clause text. Use null for fields not present. Do not invent values.

        DOCUMENT TEXT:
        \(text)
        """
    }

    /// Decodes the model's JSON into `ExtractedFields`, tolerating missing keys
    /// and never crashing on unexpected values.
    static func decode(_ raw: String) throws -> ExtractedFields {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentExtractionError.emptyResponse }
        guard let data = trimmed.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw DocumentExtractionError.malformedJSON }

        func string(_ key: String) -> String? {
            (obj[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        let typeRaw = (obj["documentType"] as? String) ?? "unknown"

        var dueDate: Date?
        if let s = string("dueDate") {
            dueDate = Self.isoDateFormatter.date(from: s)
        }

        var amount: Decimal?
        if let s = string("amount") {
            amount = Decimal(string: s)
        }

        let partyNames = (obj["partyNames"] as? [Any])?.compactMap { $0 as? String } ?? []

        var extras: [String: String] = [:]
        if let raw = obj["extras"] as? [String: Any] {
            for (k, v) in raw { if let s = v as? String { extras[k] = s } }
        }

        return ExtractedFields(
            documentType: DocumentType(rawValue: typeRaw),
            vendor: string("vendor"),
            invoiceNumber: string("invoiceNumber"),
            amount: amount,
            currency: string("currency"),
            dueDate: dueDate,
            partyNames: partyNames,
            renewalClause: string("renewalClause"),
            extras: extras
        )
    }

    static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
```

> **JSONSchema assumption:** `SenaniInference.JSONSchema` is constructible from a raw JSON string via `JSONSchema(json:)`. If the real initializer differs (e.g. a DSL builder), adapt `schema()` to construct the same logical schema — the test does not assert on the schema object, only on decoded output.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — all 7 `DocumentExtractorTests` pass; earlier suites still green.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/DocumentExtractor.swift Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentExtractorTests.swift
git commit -m "feat(docs): DocumentExtractor — grammar-constrained field extraction"
```

---

### Task 5: Chunker (pure text chunking for indexing)

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/Chunker.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/ChunkerTests.swift`

A pure, deterministic chunker the indexer uses before embedding. No dependencies — fully unit-testable.

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/ChunkerTests.swift`:

```swift
import Testing
@testable import SenaniDocs

@Suite struct ChunkerTests {
    @Test func shortTextIsOneChunk() {
        let chunks = Chunker(maxChunkLength: 100).chunks(for: "hello world")
        #expect(chunks == ["hello world"])
    }

    @Test func emptyOrWhitespaceTextYieldsNoChunks() {
        #expect(Chunker(maxChunkLength: 100).chunks(for: "").isEmpty)
        #expect(Chunker(maxChunkLength: 100).chunks(for: "   \n  ").isEmpty)
    }

    @Test func longTextIsSplitIntoBoundedChunks() {
        let text = String(repeating: "a", count: 250)
        let chunks = Chunker(maxChunkLength: 100).chunks(for: text)
        #expect(chunks.count == 3)
        #expect(chunks[0].count == 100)
        #expect(chunks[1].count == 100)
        #expect(chunks[2].count == 50)
        #expect(chunks.joined() == text)
    }

    @Test func chunkingPrefersParagraphBoundaries() {
        let text = "para one.\n\npara two.\n\npara three."
        let chunks = Chunker(maxChunkLength: 12).chunks(for: text)
        // Each paragraph fits under 12 chars and is kept intact.
        #expect(chunks.contains("para one."))
        #expect(chunks.contains("para two."))
        #expect(chunks.contains("para three."))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find 'Chunker' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/Chunker.swift`:

```swift
import Foundation

/// Splits document text into bounded chunks for embedding. Prefers paragraph
/// boundaries (`\n\n`); paragraphs longer than `maxChunkLength` are hard-split.
/// Pure and deterministic — no I/O, no model.
public struct Chunker: Sendable {
    public let maxChunkLength: Int

    public init(maxChunkLength: Int = 1000) {
        self.maxChunkLength = max(1, maxChunkLength)
    }

    public func chunks(for text: String) -> [String] {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        var result: [String] = []
        let paragraphs = text.components(separatedBy: "\n\n")
        for paragraph in paragraphs {
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.count <= maxChunkLength {
                result.append(trimmed)
            } else {
                result.append(contentsOf: hardSplit(trimmed))
            }
        }

        // If there were no paragraph breaks at all, hardSplit the whole thing.
        if result.isEmpty {
            result = hardSplit(text)
        }
        return result
    }

    private func hardSplit(_ s: String) -> [String] {
        var chunks: [String] = []
        var index = s.startIndex
        while index < s.endIndex {
            let end = s.index(index, offsetBy: maxChunkLength, limitedBy: s.endIndex) ?? s.endIndex
            chunks.append(String(s[index..<end]))
            index = end
        }
        return chunks
    }
}
```

> Note: `chunkingPrefersParagraphBoundaries` relies on paragraph splitting; `longTextIsSplitIntoBoundedChunks` uses single-paragraph text (no `\n\n`) so it exercises `hardSplit` and the `joined() == text` invariant holds.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — all 4 `ChunkerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/Chunker.swift Packages/SenaniDocs/Tests/SenaniDocsTests/ChunkerTests.swift
git commit -m "feat(docs): pure deterministic text Chunker for indexing"
```

---

### Task 6: DocumentIndexer (persist rows + embed chunks into the vector index)

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/DocumentIndexer.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentIndexerTests.swift`

Persists one `documents` row + N `document_fields` rows via `SenaniDatabase`, then chunks the parsed text, embeds each chunk via `Embedder`, and inserts each vector into `VectorIndex` with `["documentId": id, "chunk": "<n>"]` metadata.

> **FakeEmbedder assumption:** `SenaniInference.FakeEmbedder` returns a deterministic vector per input (e.g. a fixed-dim vector derived from the string) and records calls. This plan assumes `FakeEmbedder()` with a recorded `embeddedTexts: [String]`. Adapt if names differ.

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentIndexerTests.swift`:

```swift
import Testing
import Foundation
import SenaniStore
import SenaniInference
@testable import SenaniDocs

@Suite struct DocumentIndexerTests {
    private func makeIndexer() throws -> (DocumentIndexer, SenaniDatabase, InMemoryVectorIndex, FakeEmbedder) {
        let db = try SenaniDatabase(inMemory: true)
        let vectors = InMemoryVectorIndex()
        let embedder = FakeEmbedder()
        let indexer = DocumentIndexer(
            database: db, vectorIndex: vectors, embedder: embedder,
            chunker: Chunker(maxChunkLength: 100))
        return (indexer, db, vectors, embedder)
    }

    @Test func writesDocumentRowAndFieldRows() async throws {
        let (indexer, db, _, _) = try makeIndexer()
        let fields = ExtractedFields(
            documentType: .invoice, vendor: "Acme LLC", invoiceNumber: "INV-42",
            amount: Decimal(string: "100.00"), currency: "USD",
            dueDate: Date(timeIntervalSince1970: 1_700_000_000))

        try await indexer.index(
            documentId: "doc-1",
            sourcePath: "/tmp/invoice.pdf",
            parsed: ParsedDocument(fullText: "Invoice INV-42 total 100.00 USD"),
            fields: fields,
            now: Date(timeIntervalSince1970: 0))

        let row = try db.documentRow(id: "doc-1")
        #expect(row?.documentType == "invoice")

        let stored = try db.documentFields(documentId: "doc-1")
        let asDict = Dictionary(uniqueKeysWithValues: stored.map { ($0.key, $0.value) })
        #expect(asDict["vendor"] == "Acme LLC")
        #expect(asDict["invoiceNumber"] == "INV-42")
        #expect(asDict["currency"] == "USD")
        #expect(asDict["amount"] == "100")          // Decimal(100.00).description
        #expect(asDict["dueDate"] != nil)            // stored as ISO string
    }

    @Test func embedsChunksAndInsertsVectorsWithDocumentMetadata() async throws {
        let (indexer, _, vectors, embedder) = try makeIndexer()
        let longText = String(repeating: "x", count: 250) // -> 3 chunks at maxChunkLength 100
        try await indexer.index(
            documentId: "doc-2", sourcePath: "/tmp/a.pdf",
            parsed: ParsedDocument(fullText: longText),
            fields: ExtractedFields(documentType: .unknown),
            now: Date(timeIntervalSince1970: 0))

        #expect(embedder.embeddedTexts.count == 3)
        #expect(vectors.count == 3)
        for entry in vectors.entries {
            #expect(entry.metadata["documentId"] == "doc-2")
        }
    }

    @Test func emptyTextWritesRowButNoVectors() async throws {
        let (indexer, db, vectors, embedder) = try makeIndexer()
        try await indexer.index(
            documentId: "doc-3", sourcePath: "/tmp/empty.pdf",
            parsed: ParsedDocument(fullText: "   "),
            fields: ExtractedFields(documentType: .receipt),
            now: Date(timeIntervalSince1970: 0))
        #expect(try db.documentRow(id: "doc-3") != nil)
        #expect(embedder.embeddedTexts.isEmpty)
        #expect(vectors.count == 0)
    }

    @Test func skipsNilFieldsWhenWritingFieldRows() async throws {
        let (indexer, db, _, _) = try makeIndexer()
        try await indexer.index(
            documentId: "doc-4", sourcePath: "/tmp/x.pdf",
            parsed: ParsedDocument(fullText: "x"),
            fields: ExtractedFields(documentType: .contract, partyNames: ["A", "B"],
                                    renewalClause: "auto-renews"),
            now: Date(timeIntervalSince1970: 0))
        let stored = try db.documentFields(documentId: "doc-4")
        let keys = Set(stored.map { $0.key })
        #expect(keys.contains("renewalClause"))
        #expect(keys.contains("partyNames"))
        #expect(!keys.contains("vendor"))   // nil -> not written
        #expect(!keys.contains("amount"))
    }
}
```

> **InMemoryVectorIndex assumption:** for assertions this plan assumes the in-memory index exposes `count` and `entries: [(id:String, vector:[Float], metadata:[String:String])]`. If the real `InMemoryVectorIndex` only conforms to the `VectorIndex` protocol, add these test-inspection accessors to it in SenaniStore, or wrap it in a tiny recording test double in this test file. Prefer adding inspection accessors to the existing `InMemoryVectorIndex` since the brief designates it the unit-test index.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find 'DocumentIndexer' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/DocumentIndexer.swift`:

```swift
import Foundation
import SenaniStore
import SenaniInference

/// Persists a parsed+extracted document: one `documents` row, one `document_fields`
/// row per non-nil field, and one embedded vector per text chunk (tagged with the
/// document id). Pure orchestration over injected store/embedder/index seams.
public struct DocumentIndexer: Sendable {
    private let database: SenaniDatabase
    private let vectorIndex: any VectorIndex
    private let embedder: any Embedder
    private let chunker: Chunker

    public init(
        database: SenaniDatabase,
        vectorIndex: any VectorIndex,
        embedder: any Embedder,
        chunker: Chunker = Chunker()
    ) {
        self.database = database
        self.vectorIndex = vectorIndex
        self.embedder = embedder
        self.chunker = chunker
    }

    public func index(
        documentId: String,
        sourcePath: String,
        parsed: ParsedDocument,
        fields: ExtractedFields,
        now: Date
    ) async throws {
        // 1. documents row
        try database.insertDocument(
            id: documentId,
            sourcePath: sourcePath,
            documentType: fields.documentType.rawValue,
            parsedText: parsed.fullText,
            createdAt: now)

        // 2. document_fields rows (only non-nil/non-empty)
        for (key, value) in Self.fieldRows(from: fields) {
            try database.insertDocumentField(documentId: documentId, key: key, value: value)
        }

        // 3. embed chunks -> vectors
        let chunks = chunker.chunks(for: parsed.fullText)
        for (n, chunk) in chunks.enumerated() {
            let vector = try await embedder.embed(chunk)
            vectorIndex.insert(
                id: "\(documentId)#\(n)",
                vector: vector,
                metadata: ["documentId": documentId, "chunk": "\(n)"])
        }
    }

    /// Flattens `ExtractedFields` into string key/value rows, omitting nil/empty values.
    static func fieldRows(from fields: ExtractedFields) -> [(String, String)] {
        var rows: [(String, String)] = []
        func add(_ key: String, _ value: String?) {
            if let value, !value.isEmpty { rows.append((key, value)) }
        }
        add("vendor", fields.vendor)
        add("invoiceNumber", fields.invoiceNumber)
        add("amount", fields.amount.map { "\($0)" })
        add("currency", fields.currency)
        add("dueDate", fields.dueDate.map { DocumentExtractor.isoDateFormatter.string(from: $0) })
        add("renewalClause", fields.renewalClause)
        if !fields.partyNames.isEmpty {
            add("partyNames", fields.partyNames.joined(separator: "; "))
        }
        for (k, v) in fields.extras { add("extra.\(k)", v) }
        return rows
    }
}
```

> The `dueDate` field row uses the ISO date string from `DocumentExtractor.isoDateFormatter`, so structured range queries in Task 7 can compare lexicographically (`yyyy-MM-dd` sorts chronologically).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — all 4 `DocumentIndexerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/DocumentIndexer.swift Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentIndexerTests.swift
git commit -m "feat(docs): DocumentIndexer — persist rows + embed chunks to vectors"
```

---

### Task 7: DocumentSearch (structured field queries + semantic insight search)

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/DocumentSearch.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentSearchTests.swift`

Two insight paths:
- **(a) structured:** "invoices due this month" → `documentsByType("invoice")` intersected with `documentFieldsByKeyValueRange(key:"dueDate", min:..., max:...)`.
- **(b) semantic:** "contract with the auto-renewal clause" → `embedder.embed(query)` → `vectorIndex.search(vector:k:)` → map result ids (`"<docId>#<n>"`) back to documents.

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentSearchTests.swift`:

```swift
import Testing
import Foundation
import SenaniStore
import SenaniInference
@testable import SenaniDocs

@Suite struct DocumentSearchTests {
    private func seed() async throws -> (DocumentSearch, SenaniDatabase, InMemoryVectorIndex, FakeEmbedder) {
        let db = try SenaniDatabase(inMemory: true)
        let vectors = InMemoryVectorIndex()
        let embedder = FakeEmbedder()
        let indexer = DocumentIndexer(database: db, vectorIndex: vectors,
                                      embedder: embedder, chunker: Chunker(maxChunkLength: 1000))

        // invoice due 2026-06-10 (this month, for now = 2026-06-15)
        try await indexer.index(
            documentId: "inv-1", sourcePath: "/a.pdf",
            parsed: ParsedDocument(fullText: "Invoice one total due soon"),
            fields: ExtractedFields(documentType: .invoice, vendor: "Acme",
                                    invoiceNumber: "INV-1",
                                    dueDate: Self.date("2026-06-10")),
            now: Date(timeIntervalSince1970: 0))
        // invoice due next month
        try await indexer.index(
            documentId: "inv-2", sourcePath: "/b.pdf",
            parsed: ParsedDocument(fullText: "Invoice two"),
            fields: ExtractedFields(documentType: .invoice, invoiceNumber: "INV-2",
                                    dueDate: Self.date("2026-07-20")),
            now: Date(timeIntervalSince1970: 0))
        // a contract with renewal clause
        try await indexer.index(
            documentId: "con-1", sourcePath: "/c.pdf",
            parsed: ParsedDocument(fullText: "This contract auto-renews annually unless cancelled."),
            fields: ExtractedFields(documentType: .contract, partyNames: ["A", "B"],
                                    renewalClause: "auto-renews annually"),
            now: Date(timeIntervalSince1970: 0))

        let search = DocumentSearch(database: db, vectorIndex: vectors, embedder: embedder)
        return (search, db, vectors, embedder)
    }

    static func date(_ s: String) -> Date {
        DocumentExtractor.isoDateFormatter.date(from: s)!
    }

    @Test func structuredQueryFindsInvoicesDueInRange() async throws {
        let (search, _, _, _) = try seed()
        let results = try search.invoices(
            dueBetween: Self.date("2026-06-01"), and: Self.date("2026-06-30"))
        let ids = Set(results.map { $0.id })
        #expect(ids == ["inv-1"])             // inv-2 is due in July
    }

    @Test func structuredQueryEmptyWhenNoneInRange() async throws {
        let (search, _, _, _) = try seed()
        let results = try search.invoices(
            dueBetween: Self.date("2026-01-01"), and: Self.date("2026-01-31"))
        #expect(results.isEmpty)
    }

    @Test func semanticSearchReturnsMatchingDocuments() async throws {
        let (search, _, _, _) = try seed()
        // FakeEmbedder is deterministic, so embedding the contract's own text yields
        // the nearest vector -> con-1. (See FakeEmbedder assumption note.)
        let results = try await search.semanticSearch(
            query: "This contract auto-renews annually unless cancelled.", limit: 1)
        #expect(results.first?.id == "con-1")
    }

    @Test func semanticSearchDeduplicatesChunksToDocuments() async throws {
        let (search, _, _, _) = try seed()
        let results = try await search.semanticSearch(query: "Invoice one total due soon", limit: 5)
        // Even if multiple chunks of one doc match, each document appears once.
        let ids = results.map { $0.id }
        #expect(Set(ids).count == ids.count)
    }
}
```

> **FakeEmbedder determinism assumption:** the semantic tests assume `FakeEmbedder` maps identical strings to identical vectors and similar strings to nearby vectors, so embedding a document's own text retrieves that document as nearest. If the real fake is not distance-meaningful (e.g. returns a constant vector), make the two semantic tests assert only that results are non-empty and dedup-correct, and add a comment pointing at the integration-level semantic check. Do not weaken the structured-query tests.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find 'DocumentSearch' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/DocumentSearch.swift`:

```swift
import Foundation
import SenaniStore
import SenaniInference

/// A document surfaced by an insight query.
public struct DocumentHit: Sendable, Equatable, Identifiable {
    public let id: String
    public let documentType: String
    public let sourcePath: String
    public init(id: String, documentType: String, sourcePath: String) {
        self.id = id
        self.documentType = documentType
        self.sourcePath = sourcePath
    }
}

/// Answers insight queries over indexed documents — both structured field queries
/// and semantic vector search. Pure orchestration over injected store/index/embedder.
public struct DocumentSearch: Sendable {
    private let database: SenaniDatabase
    private let vectorIndex: any VectorIndex
    private let embedder: any Embedder

    public init(database: SenaniDatabase, vectorIndex: any VectorIndex, embedder: any Embedder) {
        self.database = database
        self.vectorIndex = vectorIndex
        self.embedder = embedder
    }

    // MARK: - (a) Structured field query

    /// Invoices whose `dueDate` falls within [from, to] inclusive.
    public func invoices(dueBetween from: Date, and to: Date) throws -> [DocumentHit] {
        let minS = DocumentExtractor.isoDateFormatter.string(from: from)
        let maxS = DocumentExtractor.isoDateFormatter.string(from: to)
        let dueRows = try database.documentFieldsByKeyValueRange(key: "dueDate", min: minS, max: maxS)
        let dueDocIds = Set(dueRows.map { $0.documentId })

        let invoiceRows = try database.documentsByType(DocumentType.invoice.rawValue)
        return invoiceRows
            .filter { dueDocIds.contains($0.id) }
            .map { DocumentHit(id: $0.id, documentType: $0.documentType, sourcePath: $0.sourcePath) }
    }

    // MARK: - (b) Semantic search

    /// Embeds `query`, searches the vector index, maps chunk ids back to unique
    /// documents (preserving distance order), and resolves them to `DocumentHit`s.
    public func semanticSearch(query: String, limit: Int) async throws -> [DocumentHit] {
        let vector = try await embedder.embed(query)
        // Over-fetch so dedup-to-document still yields up to `limit` documents.
        let raw = vectorIndex.search(vector: vector, k: max(limit, limit * 4))

        var seen = Set<String>()
        var hits: [DocumentHit] = []
        for entry in raw {
            let docId = Self.documentId(fromChunkId: entry.id)
            guard !seen.contains(docId) else { continue }
            seen.insert(docId)
            if let row = try database.documentRow(id: docId) {
                hits.append(DocumentHit(id: row.id, documentType: row.documentType, sourcePath: row.sourcePath))
            }
            if hits.count == limit { break }
        }
        return hits
    }

    /// Vector ids are `"<documentId>#<chunkIndex>"`; strip the chunk suffix.
    static func documentId(fromChunkId chunkId: String) -> String {
        if let hash = chunkId.lastIndex(of: "#") {
            return String(chunkId[chunkId.startIndex..<hash])
        }
        return chunkId
    }
}
```

> **Store row property assumption:** `DocumentRow` exposes `id`, `documentType`, `sourcePath` (Swift-cased). `DocumentFieldRow` exposes `documentId`, `key`, `value`. If the actual store uses snake_case property names, adjust these accessors. The mapping logic and dedup behavior are what the tests pin down.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — all 4 `DocumentSearchTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/DocumentSearch.swift Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentSearchTests.swift
git commit -m "feat(docs): DocumentSearch — structured field + semantic insight queries"
```

---

### Task 8: DocumentPipeline façade (parse → extract → index for one attachment)

**Files:**
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/DocumentPipeline.swift`
- Test: `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentPipelineTests.swift`

The single entry point the `parseDoc` action handler calls. Ties the seams together with all fakes in the test.

- [ ] **Step 1: Write the failing test**

Create `Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentPipelineTests.swift`:

```swift
import Testing
import Foundation
import SenaniStore
import SenaniInference
@testable import SenaniDocs

@Suite struct DocumentPipelineTests {
    private func makePipeline(
        parsedText: String,
        extractionJSON: String
    ) throws -> (DocumentPipeline, SenaniDatabase, InMemoryVectorIndex, FakeDocumentParser) {
        let parser = FakeDocumentParser(result: ParsedDocument(fullText: parsedText))
        let gen = FakeTextGenerator()
        gen.jsonResponse = extractionJSON
        let db = try SenaniDatabase(inMemory: true)
        let vectors = InMemoryVectorIndex()
        let pipeline = DocumentPipeline(
            parser: parser,
            extractor: DocumentExtractor(generator: gen),
            indexer: DocumentIndexer(database: db, vectorIndex: vectors,
                                     embedder: FakeEmbedder(), chunker: Chunker(maxChunkLength: 1000)))
        return (pipeline, db, vectors, parser)
    }

    @Test func runsParseExtractIndexEndToEnd() async throws {
        let (pipeline, db, vectors, parser) = try makePipeline(
            parsedText: "Invoice INV-77 amount 50.00 USD",
            extractionJSON: #"{ "documentType": "invoice", "invoiceNumber": "INV-77", "amount": "50.00", "currency": "USD" }"#)

        let url = URL(fileURLWithPath: "/tmp/inv.pdf")
        let result = try await pipeline.run(fileURL: url, documentId: "doc-77",
                                            now: Date(timeIntervalSince1970: 0))

        // parser was called with the URL
        #expect(parser.parsedURLs == [url])
        // returned fields
        #expect(result.documentId == "doc-77")
        #expect(result.fields.documentType == .invoice)
        #expect(result.fields.invoiceNumber == "INV-77")
        // persisted row + vectors
        #expect(try db.documentRow(id: "doc-77")?.documentType == "invoice")
        let stored = Dictionary(uniqueKeysWithValues:
            try db.documentFields(documentId: "doc-77").map { ($0.key, $0.value) })
        #expect(stored["invoiceNumber"] == "INV-77")
        #expect(vectors.count >= 1)
    }

    @Test func generatesDocumentIdWhenNotProvided() async throws {
        let (pipeline, db, _, _) = try makePipeline(
            parsedText: "x", extractionJSON: #"{ "documentType": "receipt" }"#)
        let result = try await pipeline.run(fileURL: URL(fileURLWithPath: "/tmp/r.pdf"),
                                            documentId: nil, now: Date(timeIntervalSince1970: 0))
        #expect(!result.documentId.isEmpty)
        #expect(try db.documentRow(id: result.documentId) != nil)
    }

    @Test func propagatesParseError() async throws {
        let parser = FakeDocumentParser(errorToThrow: DocumentParseError.unreadable)
        let gen = FakeTextGenerator(); gen.jsonResponse = "{}"
        let db = try SenaniDatabase(inMemory: true)
        let pipeline = DocumentPipeline(
            parser: parser,
            extractor: DocumentExtractor(generator: gen),
            indexer: DocumentIndexer(database: db, vectorIndex: InMemoryVectorIndex(),
                                     embedder: FakeEmbedder()))
        await #expect(throws: DocumentParseError.self) {
            _ = try await pipeline.run(fileURL: URL(fileURLWithPath: "/tmp/bad.pdf"),
                                       documentId: "d", now: Date(timeIntervalSince1970: 0))
        }
        // nothing persisted when parsing fails
        #expect(try db.documentRow(id: "d") == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/SenaniDocs && swift test`
Expected: FAIL — `cannot find 'DocumentPipeline' in scope`.

- [ ] **Step 3: Write the minimal implementation**

Create `Packages/SenaniDocs/Sources/SenaniDocs/DocumentPipeline.swift`:

```swift
import Foundation

/// Result of running the pipeline on one attachment.
public struct DocumentPipelineResult: Sendable, Equatable {
    public let documentId: String
    public let parsed: ParsedDocument
    public let fields: ExtractedFields
    public init(documentId: String, parsed: ParsedDocument, fields: ExtractedFields) {
        self.documentId = documentId
        self.parsed = parsed
        self.fields = fields
    }
}

/// Façade tying parse → extract → index for a single attachment. This is what the
/// `parseDoc` Action Kernel handler calls. On a parse error nothing is persisted.
public struct DocumentPipeline: Sendable {
    private let parser: any DocumentParser
    private let extractor: DocumentExtractor
    private let indexer: DocumentIndexer

    public init(parser: any DocumentParser, extractor: DocumentExtractor, indexer: DocumentIndexer) {
        self.parser = parser
        self.extractor = extractor
        self.indexer = indexer
    }

    /// Parses the file, extracts fields, persists + indexes them, and returns the result.
    /// If `documentId` is nil a fresh UUID string is used.
    @discardableResult
    public func run(fileURL: URL, documentId: String? = nil, now: Date = Date()) async throws -> DocumentPipelineResult {
        let id = documentId ?? UUID().uuidString
        let parsed = try await parser.parse(fileURL: fileURL)
        let fields = try await extractor.extract(from: parsed)
        try await indexer.index(
            documentId: id,
            sourcePath: fileURL.path,
            parsed: parsed,
            fields: fields,
            now: now)
        return DocumentPipelineResult(documentId: id, parsed: parsed, fields: fields)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd Packages/SenaniDocs && swift test`
Expected: PASS — all 3 `DocumentPipelineTests` pass; entire `SenaniDocsTests` suite green.

- [ ] **Step 5: Commit**

```bash
git add Packages/SenaniDocs/Sources/SenaniDocs/DocumentPipeline.swift Packages/SenaniDocs/Tests/SenaniDocsTests/DocumentPipelineTests.swift
git commit -m "feat(docs): DocumentPipeline façade tying parse->extract->index"
```

---

### Task 9: liteparse Rust FFI — vendor, build, bridge, real parser + gated integration test

> **This task is fully isolated.** Tasks 1–8 build and pass with no Rust toolchain. This task adds the real parser, the C FFI bridging, and a real integration test that is **skipped unless** `SENANI_LITEPARSE_SAMPLE_PDF` (a path to a sample PDF) is set *and* the static lib has been built. Do not weaken or stub the integration test — gate it.

**Files:**
- Create: `Packages/SenaniDocs/Sources/Clibliteparse/include/liteparse.h`
- Create: `Packages/SenaniDocs/Sources/Clibliteparse/include/module.modulemap`
- Create: `Packages/SenaniDocs/Scripts/build-liteparse.sh`
- Create: `Packages/SenaniDocs/Sources/SenaniDocs/LiteParseDocumentParser.swift`
- Create: `Packages/SenaniDocs/Tests/SenaniDocsIntegrationTests/LiteParseIntegrationTests.swift`
- Edit: `Packages/SenaniDocs/Package.swift`

- [ ] **Step 1: Vendor the liteparse Rust crate and write the build script**

The liteparse Rust core is vendored under `Packages/SenaniDocs/Vendor/liteparse/` as a Cargo crate that produces a **C-ABI static library** (`crate-type = ["staticlib"]`) exposing a stable C interface (PDFium + Tesseract are linked into that staticlib by the crate's own build). Do NOT use the Python/Node wrapper.

Create `Packages/SenaniDocs/Scripts/build-liteparse.sh` (real, runnable):

```bash
#!/usr/bin/env bash
# Builds the vendored liteparse Rust core as a C-ABI static library and stages
# the artifact + header where the Clibliteparse SPM target expects them.
# Requires: a Rust toolchain (cargo) with the macOS target installed.
set -euo pipefail

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE_DIR="${PKG_DIR}/Vendor/liteparse"
OUT_LIB_DIR="${PKG_DIR}/Sources/Clibliteparse/lib"
INCLUDE_DIR="${PKG_DIR}/Sources/Clibliteparse/include"

if ! command -v cargo >/dev/null 2>&1; then
  echo "error: cargo (Rust toolchain) not found. Install via https://rustup.rs" >&2
  exit 1
fi

echo "Building liteparse staticlib (release)…"
( cd "${CRATE_DIR}" && cargo build --release )

mkdir -p "${OUT_LIB_DIR}"
cp "${CRATE_DIR}/target/release/libliteparse.a" "${OUT_LIB_DIR}/libliteparse.a"

# The crate's cbindgen step emits liteparse.h; copy it next to the modulemap.
cp "${CRATE_DIR}/include/liteparse.h" "${INCLUDE_DIR}/liteparse.h"

echo "Done. Static lib at ${OUT_LIB_DIR}/libliteparse.a"
```

Make it executable: `chmod +x Packages/SenaniDocs/Scripts/build-liteparse.sh`

- [ ] **Step 2: Write the C header + module map for the FFI shim**

Create `Packages/SenaniDocs/Sources/Clibliteparse/include/liteparse.h` (the stable C surface the Rust crate exports — kept minimal: parse a file path to a UTF-8 JSON string the Swift side decodes, plus a free function):

```c
#ifndef LITEPARSE_H
#define LITEPARSE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Parse the file at `path` (a PDF or image). Returns a newly-allocated,
/// NUL-terminated UTF-8 JSON string describing the parsed document
/// ({ "fullText": "...", "blocks": [ { "page": n, "text": "...",
///    "bbox": [x,y,w,h] | null } ] }), or NULL on failure.
/// The caller MUST free the returned pointer with `liteparse_string_free`.
char *liteparse_parse_file(const char *path);

/// Free a string previously returned by `liteparse_parse_file`.
void liteparse_string_free(char *s);

#ifdef __cplusplus
}
#endif

#endif /* LITEPARSE_H */
```

Create `Packages/SenaniDocs/Sources/Clibliteparse/include/module.modulemap`:

```
module Clibliteparse {
    header "liteparse.h"
    link "liteparse"
    export *
}
```

- [ ] **Step 3: Wire the Clibliteparse target into Package.swift**

Edit `Packages/SenaniDocs/Package.swift` to add the system/FFI target, make `SenaniDocs` depend on it, point the linker at the staticlib dir, and add the separate integration test target. Replace the `targets:` array with:

```swift
    targets: [
        .systemLibrary(
            name: "Clibliteparse",
            path: "Sources/Clibliteparse"
        ),
        .target(
            name: "SenaniDocs",
            dependencies: [
                .product(name: "SenaniRules", package: "SenaniRules"),
                .product(name: "SenaniStore", package: "SenaniStore"),
                .product(name: "SenaniInference", package: "SenaniInference"),
                "Clibliteparse",
            ],
            linkerSettings: [
                .unsafeFlags(["-L", "Sources/Clibliteparse/lib"], .when(platforms: [.macOS])),
            ]
        ),
        .testTarget(
            name: "SenaniDocsTests",
            dependencies: ["SenaniDocs"]
        ),
        .testTarget(
            name: "SenaniDocsIntegrationTests",
            dependencies: ["SenaniDocs"]
        ),
    ]
```

> The `.systemLibrary` approach keeps the modulemap + header in-tree and links the cargo-built `libliteparse.a` via the `-L` flag. If `swift test` for Tasks 1–8 must run on a machine without the staticlib present, keep `LiteParseDocumentParser.swift` behind a `#if canImport(Clibliteparse)` guard (below) so the unit-test target never forces the link. Because the staticlib is only referenced by code compiled when `Clibliteparse` is imported, and the integration test is the only thing that constructs the real parser, the unit tests in `SenaniDocsTests` remain link-clean.

- [ ] **Step 4: Write the real LiteParseDocumentParser**

Create `Packages/SenaniDocs/Sources/SenaniDocs/LiteParseDocumentParser.swift`:

```swift
import Foundation
#if canImport(Clibliteparse)
import Clibliteparse
#endif

/// Real `DocumentParser` backed by the vendored liteparse Rust core via C FFI.
/// PDFs + images only (Office formats are out of scope per spec §7). Not unit-tested
/// directly — exercised by the gated integration test. The unit-tested logic lives
/// behind the `DocumentParser` seam (`FakeDocumentParser`).
public struct LiteParseDocumentParser: DocumentParser {
    public init() {}

    public func parse(fileURL: URL) async throws -> ParsedDocument {
        #if canImport(Clibliteparse)
        let path = fileURL.path
        guard let cstr = liteparse_parse_file(path) else {
            throw DocumentParseError.unreadable
        }
        defer { liteparse_string_free(cstr) }
        let json = String(cString: cstr)
        return try Self.decode(json)
        #else
        throw DocumentParseError.backend("liteparse not linked: run Scripts/build-liteparse.sh")
        #endif
    }

    /// Decodes the liteparse JSON envelope into a `ParsedDocument`.
    static func decode(_ json: String) throws -> ParsedDocument {
        guard let data = json.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let fullText = obj["fullText"] as? String
        else { throw DocumentParseError.backend("unexpected liteparse output") }

        var blocks: [LayoutBlock] = []
        if let rawBlocks = obj["blocks"] as? [[String: Any]] {
            for b in rawBlocks {
                let page = (b["page"] as? Int) ?? 0
                let text = (b["text"] as? String) ?? ""
                var box: LayoutBlock.BoundingBox?
                if let bbox = b["bbox"] as? [Double], bbox.count == 4 {
                    box = .init(x: bbox[0], y: bbox[1], width: bbox[2], height: bbox[3])
                }
                blocks.append(LayoutBlock(page: page, text: text, boundingBox: box))
            }
        }
        return ParsedDocument(fullText: fullText, blocks: blocks)
    }
}
```

- [ ] **Step 5: Write the gated integration test (real, not placeholder)**

Create `Packages/SenaniDocs/Tests/SenaniDocsIntegrationTests/LiteParseIntegrationTests.swift`:

```swift
import Testing
import Foundation
@testable import SenaniDocs

/// Real FFI exercise. SKIPPED unless `SENANI_LITEPARSE_SAMPLE_PDF` points at a
/// real PDF AND the liteparse staticlib has been built (Scripts/build-liteparse.sh).
/// This is the only test that constructs the real parser.
@Suite struct LiteParseIntegrationTests {
    private var samplePDFPath: String? {
        ProcessInfo.processInfo.environment["SENANI_LITEPARSE_SAMPLE_PDF"]
    }

    @Test func parsesSamplePDFIntoNonEmptyText() async throws {
        try withKnownIssueIfUnavailable()
        guard let path = samplePDFPath else {
            // Not configured -> treat as skipped (no failure).
            return
        }
        let url = URL(fileURLWithPath: path)
        let parser = LiteParseDocumentParser()
        let parsed = try await parser.parse(fileURL: url)
        #expect(!parsed.fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func throwsForMissingFile() async throws {
        guard samplePDFPath != nil else { return }  // only run when env configured
        let parser = LiteParseDocumentParser()
        await #expect(throws: DocumentParseError.self) {
            _ = try await parser.parse(fileURL: URL(fileURLWithPath: "/no/such/file-xyz.pdf"))
        }
    }

    /// Documents the gating contract; no-op when configured.
    private func withKnownIssueIfUnavailable() throws {
        if samplePDFPath == nil {
            // Intentionally a no-op return path in the test above; this method exists
            // to make the gating explicit and greppable.
        }
    }
}
```

- [ ] **Step 6: Run the unit suite (must stay green without Rust) and the gated integration test**

Run (unit suite, no Rust toolchain needed):
`cd Packages/SenaniDocs && swift test --filter SenaniDocsTests`
Expected: PASS — all Task 1–8 tests green; `LiteParseDocumentParser` compiles (its FFI body is under `#if canImport(Clibliteparse)`; without the staticlib it throws `.backend`).

Run (integration, configured): build the lib then run with the env var:
```bash
cd Packages/SenaniDocs
./Scripts/build-liteparse.sh
SENANI_LITEPARSE_SAMPLE_PDF=/absolute/path/to/sample.pdf swift test --filter SenaniDocsIntegrationTests
```
Expected: PASS — `parsesSamplePDFIntoNonEmptyText` extracts non-empty text from the real PDF; `throwsForMissingFile` throws `DocumentParseError`.

Run (integration, unconfigured): `cd Packages/SenaniDocs && swift test --filter SenaniDocsIntegrationTests`
Expected: PASS — both tests short-circuit (skipped) because `SENANI_LITEPARSE_SAMPLE_PDF` is unset; no failure.

- [ ] **Step 7: Commit**

```bash
git add Packages/SenaniDocs/Package.swift \
        Packages/SenaniDocs/Sources/Clibliteparse \
        Packages/SenaniDocs/Scripts/build-liteparse.sh \
        Packages/SenaniDocs/Sources/SenaniDocs/LiteParseDocumentParser.swift \
        Packages/SenaniDocs/Tests/SenaniDocsIntegrationTests/LiteParseIntegrationTests.swift
git commit -m "feat(docs): liteparse Rust FFI parser + gated integration test"
```

---

## What this plan deliberately leaves out (next plans / out of scope)

- **Office-document parsing (.docx/.pptx/.xlsx)** — requires LibreOffice; explicitly **deferred** per spec §1/§7. PDFs + images are the only supported path here.
- **The `parseDoc` Action Kernel handler wiring** — lives in `SenaniRules`/the app; it *calls* `DocumentPipeline.run(fileURL:)`. This plan exposes the façade it needs but does not edit `SenaniRules`.
- **The Invoice/Finance agent** that consumes these insights (spec §7 step 4) — its own plan.
- **Real `SenaniStore` / `SenaniInference` implementations** — assumed as public contracts; only their test fakes + in-memory variants are used here.
- **Vendoring the actual liteparse crate source + tuning PDFium/Tesseract bundling** — Task 9 specifies the build/bridge mechanism; obtaining and pinning the upstream crate revision is an ops step done once.

---

## Self-Review

**Spec coverage (§7):** Extract via liteparse Rust-core FFI (PDFium + Tesseract, no Python/Node) → Task 9 (`LiteParseDocumentParser` + `Clibliteparse` + `build-liteparse.sh`), seam in Task 2. Grammar-constrained Gemma field extraction (invoice #, amount, due date, vendor, contract parties/dates, renewal clause) → Task 4 (`DocumentExtractor` with `JSONSchema`), model in Task 3 (`ExtractedFields`). Index as structured rows (`documents`, `document_fields`) **and** vector chunks → Tasks 5+6 (`Chunker`, `DocumentIndexer`). Chat-queryable insights — "invoices due this month" (structured) and "contract with the auto-renewal clause" (semantic) → Task 7 (`DocumentSearch`). The `parseDoc` pipeline entry point → Task 8 (`DocumentPipeline`). Office formats explicitly deferred. Every §7 requirement is addressed.

**Testability rule compliance:** Rust FFI is NOT unit-tested — it sits behind `DocumentParser`; all extraction/indexing/search/orchestration logic is unit-tested with `FakeDocumentParser` + `FakeTextGenerator` + `FakeEmbedder` + `InMemoryVectorIndex` + in-memory `SenaniDatabase` (Tasks 2–8). The real liteparse FFI is exercised by a **separate, clearly-gated** integration test target (`SenaniDocsIntegrationTests`), skipped unless `SENANI_LITEPARSE_SAMPLE_PDF` is set and the lib is built — real, not placeholder. The bridging (vendor + cargo staticlib + C header/modulemap + `.systemLibrary` target) is confined to Task 9; Tasks 1–8 are independent of it and compile/pass with no Rust toolchain.

**Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step is complete, compilable Swift (or runnable bash/C). Assumptions about sibling-package APIs (`SenaniDatabase` row methods, `FakeTextGenerator.jsonResponse`/`lastPrompt`, `FakeEmbedder.embeddedTexts`/determinism, `InMemoryVectorIndex.entries`/`count`, `JSONSchema(json:)`) are called out inline with explicit fallbacks so a worker can adapt to the real contracts without guessing.

**Type consistency:** Public types referenced across tasks line up — `ParsedDocument`/`LayoutBlock`(+`BoundingBox`), `DocumentParser`/`DocumentParseError`, `FakeDocumentParser` (test helper), `ExtractedFields`/`DocumentType`, `DocumentExtractor`/`DocumentExtractionError` (+ shared `isoDateFormatter` reused by indexer & search for chronologically-sortable `yyyy-MM-dd` rows), `Chunker`, `DocumentIndexer`, `DocumentSearch`/`DocumentHit`, `DocumentPipeline`/`DocumentPipelineResult`, `LiteParseDocumentParser`. Vector chunk ids are `"<docId>#<n>"` written in Task 6 and parsed back in Task 7 — consistent. The `dueDate` row format written by `DocumentIndexer.fieldRows` matches the `documentFieldsByKeyValueRange` lexical range query in `DocumentSearch.invoices`.

**Concurrency:** All production types are `struct`+`Sendable`; protocols are `Sendable`; the only mutable test double (`FakeDocumentParser`) is `@unchecked Sendable` with simple value state, acceptable for the single-threaded test usage. No global mutable state except the `static let` `DateFormatter` (immutable after init).
