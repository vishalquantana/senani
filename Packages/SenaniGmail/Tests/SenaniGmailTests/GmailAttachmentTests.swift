import Foundation
import Testing
@testable import SenaniGmail

@Suite struct GmailAttachmentTests {
    @Test func getAttachmentEndpointBuildsExpectedRequest() {
        let request = GmailEndpoints.getAttachment(
            messageId: "m1",
            attachmentId: "att-9",
            accessToken: "TOKEN"
        )
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/gmail/v1/users/me/messages/m1/attachments/att-9")
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
    }

    @Test func attachmentRefIsValueType() {
        let ref = GmailAttachmentRef(
            attachmentId: "att-9",
            filename: "invoice.pdf",
            mimeType: "application/pdf",
            size: 1234
        )
        #expect(ref == GmailAttachmentRef(attachmentId: "att-9", filename: "invoice.pdf", mimeType: "application/pdf", size: 1234))
        #expect(ref.attachmentId == "att-9")
        #expect(ref.filename == "invoice.pdf")
        #expect(ref.mimeType == "application/pdf")
        #expect(ref.size == 1234)
    }

    @Test func dataDecodesBase64URLWithURLSafeCharsAndMissingPadding() async throws {
        // Bytes whose standard base64 contains both '+' and '/' and needs padding.
        let original = Data([0xFB, 0xFF, 0xBF, 0x00, 0x10, 0x83, 0x3E, 0x7F])
        let standard = original.base64EncodedString()
        #expect(standard.contains("+") || standard.contains("/"))
        let urlSafe = MIMEBuilder.base64URL(original) // strips padding, uses - and _
        #expect(!urlSafe.contains("="))

        let fake = FakeHTTPClient()
        await fake.enqueueJSON(#"{"data":"\#(urlSafe)","size":\#(original.count)}"#)
        let fetcher = GmailAttachmentFetcher(
            http: fake,
            tokenProvider: StubTokenProvider(token: "T"),
            accountEmail: "me@example.com"
        )

        let decoded = try await fetcher.data(messageId: "m1", attachmentId: "att-9")
        #expect(decoded == original)
        let request = try #require(await fake.recordedRequests.first)
        #expect(request.url?.path == "/gmail/v1/users/me/messages/m1/attachments/att-9")
    }

    @Test func dataThrowsOnNon200() async throws {
        let fake = FakeHTTPClient()
        await fake.enqueueJSON(#"{"error":"denied"}"#, status: 403)
        let fetcher = GmailAttachmentFetcher(
            http: fake,
            tokenProvider: StubTokenProvider(token: "T"),
            accountEmail: "me@example.com"
        )
        await #expect(throws: HTTPClientError.self) {
            _ = try await fetcher.data(messageId: "m1", attachmentId: "att-9")
        }
    }

    @Test func dataThrowsOnMalformedJSON() async throws {
        let fake = FakeHTTPClient()
        await fake.enqueueJSON(#"{"size":10}"#) // missing "data"
        let fetcher = GmailAttachmentFetcher(
            http: fake,
            tokenProvider: StubTokenProvider(token: "T"),
            accountEmail: "me@example.com"
        )
        await #expect(throws: (any Error).self) {
            _ = try await fetcher.data(messageId: "m1", attachmentId: "att-9")
        }
    }
}
