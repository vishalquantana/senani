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
