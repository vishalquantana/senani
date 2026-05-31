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
}
