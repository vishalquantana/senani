import Testing
import Foundation
@testable import SenaniApp
import SenaniRules
import SenaniGmail
import SenaniDocs
import SenaniInference

private struct FakeAttachmentFetcher: AttachmentFetching {
    var refs: [GmailAttachmentRef] = []
    var bytes: Data = Data("hello".utf8)
    var throwOnAttachments = false
    var throwOnData = false

    enum Err: Error { case boom }

    func attachments(messageId: String) async throws -> [GmailAttachmentRef] {
        if throwOnAttachments { throw Err.boom }
        return refs
    }
    func data(messageId: String, attachmentId: String) async throws -> Data {
        if throwOnData { throw Err.boom }
        return bytes
    }
}

/// A parser that returns a canned ParsedDocument, ignoring the file contents.
private struct FakeDocumentParser: DocumentParser {
    var canned: ParsedDocument
    var shouldThrow = false
    enum Err: Error { case boom }
    func parse(url: URL, messageId: String) async throws -> ParsedDocument {
        if shouldThrow { throw Err.boom }
        return canned
    }
}

private func pdfRef(_ name: String = "invoice.pdf") -> GmailAttachmentRef {
    GmailAttachmentRef(attachmentId: "att-1", filename: name, mimeType: "application/pdf", size: 100)
}

private func message(hasAttachment: Bool) -> Message {
    Message(id: "m-1", from: "vendor@acme.com", to: ["me@x.com"], subject: "Docs",
            body: "see attached", hasAttachment: hasAttachment, listUnsubscribeHeader: nil,
            labels: [], threadId: "t-1", date: Date(timeIntervalSince1970: 1000), isFromUser: false)
}

private func extractor(returning fields: [String: String]) -> DocumentExtractor {
    // DocumentExtractor reads `object["fields"]` from the generator's JSON.
    let payload: [String: Any] = ["fields": fields]
    let data = try! JSONSerialization.data(withJSONObject: payload)
    let json = String(data: data, encoding: .utf8)!
    return DocumentExtractor(generator: FakeTextGenerator(response: json))
}

@Suite struct GmailDocumentFieldsProviderTests {

    @Test func emitsConsumerKeysFromExtractedFields() async {
        let parsed = ParsedDocument(id: "d-1", messageId: "m-1", filename: "invoice.pdf",
                                    kind: "pdf", text: "Invoice total $500")
        let provider = GmailDocumentFieldsProvider(
            fetcher: FakeAttachmentFetcher(refs: [pdfRef()], bytes: Data("pdfbytes".utf8)),
            parser: FakeDocumentParser(canned: parsed),
            extractor: extractor(returning: ["amount": "$500.00", "vendor": "Acme",
                                             "invoice_number": "INV-7", "total": "$500.00"]))

        let fields = await provider.fields(for: message(hasAttachment: true))
        #expect(fields["amount"] == "$500.00")
        #expect(fields["total"] == "$500.00")
        #expect(fields["vendor"] == "Acme")
        #expect(fields["invoice_number"] == "INV-7")
    }

    @Test func noAttachmentReturnsEmpty() async {
        let provider = GmailDocumentFieldsProvider(
            fetcher: FakeAttachmentFetcher(refs: [pdfRef()]),
            parser: FakeDocumentParser(canned: ParsedDocument(id: "d", messageId: "m-1", filename: "x", kind: "pdf", text: "t")),
            extractor: extractor(returning: ["amount": "$500"]))
        let fields = await provider.fields(for: message(hasAttachment: false))
        #expect(fields.isEmpty)
    }

    @Test func fetchThrowDegradesToEmpty() async {
        let provider = GmailDocumentFieldsProvider(
            fetcher: FakeAttachmentFetcher(refs: [pdfRef()], throwOnAttachments: true),
            parser: FakeDocumentParser(canned: ParsedDocument(id: "d", messageId: "m-1", filename: "x", kind: "pdf", text: "t")),
            extractor: extractor(returning: ["amount": "$500"]))
        let fields = await provider.fields(for: message(hasAttachment: true))
        #expect(fields.isEmpty)
    }

    @Test func parseThrowDegradesToEmpty() async {
        let provider = GmailDocumentFieldsProvider(
            fetcher: FakeAttachmentFetcher(refs: [pdfRef()]),
            parser: FakeDocumentParser(canned: ParsedDocument(id: "d", messageId: "m-1", filename: "x", kind: "pdf", text: "t"), shouldThrow: true),
            extractor: extractor(returning: ["amount": "$500"]))
        let fields = await provider.fields(for: message(hasAttachment: true))
        #expect(fields.isEmpty)
    }

    @Test func noParseableAttachmentReturnsEmpty() async {
        let calRef = GmailAttachmentRef(attachmentId: "a", filename: "event.ics",
                                        mimeType: "text/calendar", size: 10)
        let provider = GmailDocumentFieldsProvider(
            fetcher: FakeAttachmentFetcher(refs: [calRef]),
            parser: FakeDocumentParser(canned: ParsedDocument(id: "d", messageId: "m-1", filename: "x", kind: "pdf", text: "t")),
            extractor: extractor(returning: ["amount": "$500"]))
        let fields = await provider.fields(for: message(hasAttachment: true))
        #expect(fields.isEmpty)
    }

    @Test func picksFirstParseableDoc() async {
        let txt = GmailAttachmentRef(attachmentId: "a0", filename: "note.txt", mimeType: "text/plain", size: 5)
        let docx = GmailAttachmentRef(attachmentId: "a1", filename: "proposal.docx",
                                      mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: 200)
        let parsed = ParsedDocument(id: "d", messageId: "m-1", filename: "proposal.docx", kind: "docx", text: "Quote total $12,000")
        let provider = GmailDocumentFieldsProvider(
            fetcher: FakeAttachmentFetcher(refs: [txt, docx]),
            parser: FakeDocumentParser(canned: parsed),
            extractor: extractor(returning: ["total": "$12,000"]))
        let fields = await provider.fields(for: message(hasAttachment: true))
        #expect(fields["total"] == "$12,000")
    }
}
