import Foundation
import SenaniRules
import SenaniGmail
import SenaniDocs

/// Seam over `GmailAttachmentFetcher` so the provider is unit-testable with a
/// fake that returns canned refs/bytes (no network).
public protocol AttachmentFetching: Sendable {
    func attachments(messageId: String) async throws -> [GmailAttachmentRef]
    func data(messageId: String, attachmentId: String) async throws -> Data
}

extension GmailAttachmentFetcher: AttachmentFetching {}

/// Real provider: lists a message's attachments, picks the first parseable doc,
/// fetches its bytes, parses + extracts fields via SenaniDocs, and maps the
/// result into the `[String: String]` bag the agents consume.
///
/// The `ExtractedFields.fields` bag already uses the snake_case keys the
/// consumers expect (e.g. `amount`, `total`, `invoice_number`, `vendor`,
/// `due_date`, `currency`), so the mapping is a direct pass-through.
///
/// Best-effort: ANY failure degrades to `[:]`. Never throws out; never logs
/// tokens or attachment bytes.
public struct GmailDocumentFieldsProvider: DocumentFieldsProviding {
    private let fetcher: any AttachmentFetching
    private let parser: any DocumentParser
    private let extractor: DocumentExtractor

    public init(fetcher: any AttachmentFetching, parser: any DocumentParser, extractor: DocumentExtractor) {
        self.fetcher = fetcher
        self.parser = parser
        self.extractor = extractor
    }

    /// mimeType prefixes / filename extensions we attempt to parse.
    static let parseableExtensions: Set<String> = ["pdf", "docx", "png", "jpg", "jpeg", "tiff", "heic"]
    static func isParseable(_ ref: GmailAttachmentRef) -> Bool {
        let mime = ref.mimeType.lowercased()
        if mime == "application/pdf" { return true }
        if mime == "application/vnd.openxmlformats-officedocument.wordprocessingml.document" { return true }
        if mime.hasPrefix("image/") { return true }
        let ext = (ref.filename as NSString).pathExtension.lowercased()
        return parseableExtensions.contains(ext)
    }

    public func fields(for message: Message) async -> [String: String] {
        guard message.hasAttachment else { return [:] }
        do {
            let refs = try await fetcher.attachments(messageId: message.id)
            guard let ref = refs.first(where: { Self.isParseable($0) }) else { return [:] }

            let bytes = try await fetcher.data(messageId: message.id, attachmentId: ref.attachmentId)
            let url = try Self.writeTemp(bytes, filename: ref.filename)
            defer { try? FileManager.default.removeItem(at: url) }

            let parsed = try await parser.parse(url: url, messageId: message.id)
            let extracted = try await extractor.extract(from: parsed)
            return extracted.fields
        } catch {
            // Graceful degradation: agents fall back to subject/body heuristics.
            return [:]
        }
    }

    /// Writes attachment bytes to a unique temp file preserving the original
    /// extension (so the parser can dispatch on file type).
    static func writeTemp(_ data: Data, filename: String) throws -> URL {
        let ext = (filename as NSString).pathExtension
        var name = UUID().uuidString
        if !ext.isEmpty { name += "." + ext }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}
