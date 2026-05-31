import Foundation

/// A reference to an attachment part within a Gmail message.
///
/// Synced `SenaniRules.Message` values only carry `hasAttachment: Bool`, so
/// downstream pipelines use this to locate the attachment bytes via the API.
public struct GmailAttachmentRef: Sendable, Equatable {
    public let attachmentId: String
    public let filename: String
    public let mimeType: String
    public let size: Int

    public init(attachmentId: String, filename: String, mimeType: String, size: Int) {
        self.attachmentId = attachmentId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
    }
}

public enum GmailAttachmentError: Error, Equatable {
    case malformedAttachmentData
}

/// Fetches attachment metadata and bytes for a Gmail message via the API.
///
/// Mirrors `GmailSync`'s initializer: composes over an `HTTPClient`, an
/// `AccessTokenProviding`, and the account email.
public struct GmailAttachmentFetcher: Sendable {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding
    private let accountEmail: String

    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding, accountEmail: String) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.accountEmail = accountEmail
    }

    /// Fetches the full message and walks its payload parts (recursively, since
    /// attachments can be nested inside multipart parts) collecting every part
    /// that has a `body.attachmentId`, a non-empty `filename`, and a `mimeType`.
    public func attachments(messageId: String) async throws -> [GmailAttachmentRef] {
        let token = try await tokenProvider.validAccessToken()
        let request = GmailEndpoints.getMessage(id: messageId, accessToken: token)
        let (data, response) = try await http.send(request)
        try GmailAuth.validate(response: response, data: data)
        let message = try JSONDecoder().decode(GmailFullMessage.self, from: data)
        var refs: [GmailAttachmentRef] = []
        Self.collectAttachments(in: message.payload, into: &refs)
        return refs
    }

    private static func collectAttachments(in payload: GmailPayload, into refs: inout [GmailAttachmentRef]) {
        if let attachmentId = payload.body?.attachmentId, !attachmentId.isEmpty,
           let filename = payload.filename, !filename.isEmpty,
           let mimeType = payload.mimeType {
            refs.append(GmailAttachmentRef(
                attachmentId: attachmentId,
                filename: filename,
                mimeType: mimeType,
                size: payload.body?.size ?? 0
            ))
        }
        for part in payload.parts ?? [] {
            collectAttachments(in: part, into: &refs)
        }
    }

    /// Fetches the attachment body and decodes its URL-safe base64 `data` field.
    public func data(messageId: String, attachmentId: String) async throws -> Data {
        let token = try await tokenProvider.validAccessToken()
        let request = GmailEndpoints.getAttachment(
            messageId: messageId,
            attachmentId: attachmentId,
            accessToken: token
        )
        let (data, response) = try await http.send(request)
        try GmailAuth.validate(response: response, data: data)
        let body = try JSONDecoder().decode(GmailAttachmentBody.self, from: data)
        guard let bytes = Self.decodeBase64URL(body.data) else {
            throw GmailAttachmentError.malformedAttachmentData
        }
        return bytes
    }

    /// Decodes a Gmail URL-safe base64 string (no padding) into raw bytes.
    static func decodeBase64URL(_ encoded: String) -> Data? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }
}

struct GmailAttachmentBody: Decodable {
    var data: String
    var size: Int?
}
