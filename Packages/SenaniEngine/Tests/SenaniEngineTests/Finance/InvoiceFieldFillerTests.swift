import Testing
import Foundation
@testable import SenaniEngine
import SenaniInference

@Suite struct InvoiceFieldFillerTests {
    private let filler = InvoiceFieldFiller()

    private func generate(_ json: String) -> @Sendable (String, JSONSchema) async throws -> String {
        let gen = FakeTextGenerator(response: json)
        return { prompt, schema in try await gen.generateJSON(prompt: prompt, schema: schema) }
    }

    @Test func fillsMissingFieldsFromModel() async throws {
        let sparse = InvoiceFields(amount: 999)   // vendor/number/date missing
        let json = #"{ "vendor": "Globex", "invoice_number": "G-1", "due_date": "2026-07-01" }"#
        let filled = try await filler.fill(sparse, documentText: "raw text",
                                           generateJSON: generate(json))
        #expect(filled.vendor == "Globex")
        #expect(filled.invoiceNumber == "G-1")
        #expect(filled.dueDate != nil)
        #expect(filled.amount == 999)             // extractor value preserved
    }

    @Test func neverOverwritesExtractorProvidedFields() async throws {
        let partial = InvoiceFields(vendor: "Acme LLC", amount: 100)   // vendor present
        let json = #"{ "vendor": "WRONG CO", "invoice_number": "INV-7", "due_date": "2026-07-01" }"#
        let filled = try await filler.fill(partial, documentText: "raw",
                                           generateJSON: generate(json))
        #expect(filled.vendor == "Acme LLC")      // NOT overwritten by the model
        #expect(filled.invoiceNumber == "INV-7")  // filled (was missing)
    }

    @Test func malformedModelJsonLeavesFieldsUnchanged() async throws {
        let sparse = InvoiceFields(amount: 50)
        let filled = try await filler.fill(sparse, documentText: "raw",
                                           generateJSON: generate("not json at all"))
        #expect(filled.amount == 50)
        #expect(filled.vendor == nil)             // no crash, nothing filled
    }

    @Test func threadsDocumentTextIntoPrompt() async throws {
        let gen = FakeTextGenerator(response: "{}")
        _ = try await filler.fill(InvoiceFields(), documentText: "MAGIC-MARKER-12345",
                                  generateJSON: { p, s in try await gen.generateJSON(prompt: p, schema: s) })
        let prompts = await gen.recordedPrompts
        #expect(prompts.first?.contains("MAGIC-MARKER-12345") == true)
    }
}
