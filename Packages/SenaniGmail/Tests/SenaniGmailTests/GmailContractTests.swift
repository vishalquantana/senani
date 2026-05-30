import Foundation
import SenaniRules
import Testing
@testable import SenaniGmail

@Suite struct GmailContractTests {
    @Test func fakeHTTPClientReturnsQueuedResponseAndRecordsRequest() async throws {
        let fake = FakeHTTPClient()
        let url = URL(string: "https://gmail.googleapis.com/x")!
        await fake.enqueueJSON(#"{"ok":true}"#, url: url)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        let (data, response) = try await fake.send(request)

        #expect(response.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true}"#)
        #expect(await fake.recordedRequests.map(\.httpMethod) == ["POST"])
    }

    @Test func endpointsBuildExpectedRequests() throws {
        let modify = GmailEndpoints.modify(
            messageId: "abc123",
            addLabelIds: ["STARRED"],
            removeLabelIds: [],
            accessToken: "TOKEN"
        )
        #expect(modify.url?.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/abc123/modify")
        #expect(modify.httpMethod == "POST")
        #expect(modify.value(forHTTPHeaderField: "Authorization") == "Bearer TOKEN")
        let body = try JSONSerialization.jsonObject(with: modify.httpBody ?? Data()) as? [String: Any]
        #expect(body?["addLabelIds"] as? [String] == ["STARRED"])

        let list = GmailEndpoints.listMessages(query: "in:inbox", pageToken: "PG", maxResults: 50, accessToken: "T")
        let listComponents = URLComponents(url: list.url!, resolvingAgainstBaseURL: false)!
        let queryItems = Dictionary(uniqueKeysWithValues: (listComponents.queryItems ?? []).map { ($0.name, $0.value) })
        #expect(listComponents.path == "/gmail/v1/users/me/messages")
        #expect(queryItems["q"] == "in:inbox")
        #expect(queryItems["pageToken"] == "PG")
        #expect(queryItems["maxResults"] == "50")

        let get = GmailEndpoints.getMessage(id: "m1", accessToken: "T")
        let getComponents = URLComponents(url: get.url!, resolvingAgainstBaseURL: false)!
        #expect(getComponents.path == "/gmail/v1/users/me/messages/m1")
        #expect(getComponents.queryItems?.first?.value == "full")
    }

    @Test func pkceAndTokenRefreshWork() async throws {
        let pkce = PKCE(verifier: "verifier-123")
        #expect(pkce.challenge == PKCE(verifier: "verifier-123").challenge)
        #expect(!pkce.challenge.contains("="))
        #expect(!pkce.challenge.contains("+"))
        #expect(!pkce.challenge.contains("/"))

        let now = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryTokenStore()
        try await store.save(OAuthToken(
            accessToken: "old",
            refreshToken: "RT",
            expiresAt: now.addingTimeInterval(10)
        ))
        let fake = FakeHTTPClient()
        await fake.enqueueJSON(#"{"access_token":"new","expires_in":3600,"token_type":"Bearer"}"#,
                               url: URL(string: "https://oauth2.googleapis.com/token")!)
        let auth = GmailAuth(clientID: "CLIENT", http: fake, store: store, now: { now })

        #expect(try await auth.validAccessToken() == "new")
        #expect(try await store.load()?.refreshToken == "RT")
        let sent = await fake.recordedRequests
        #expect(sent.count == 1)
        #expect(String(decoding: sent[0].httpBody ?? Data(), as: UTF8.self).contains("grant_type=refresh_token"))
    }

    @Test func freshTokenSkipsRefresh() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let store = InMemoryTokenStore()
        try await store.save(OAuthToken(
            accessToken: "fresh",
            refreshToken: "RT",
            expiresAt: now.addingTimeInterval(3_600)
        ))
        let fake = FakeHTTPClient()
        let auth = GmailAuth(clientID: "CLIENT", http: fake, store: store, now: { now })
        #expect(try await auth.validAccessToken() == "fresh")
        #expect(await fake.recordedRequests.isEmpty)
    }

    @Test func mimeBuilderUsesHeadersAndURLSafeBase64() {
        let raw = MIMEBuilder.message(
            from: "me@example.com",
            to: ["sarah@acme.com"],
            subject: "Re: pricing",
            body: "Hi",
            inReplyTo: "<orig>",
            references: "<orig>"
        )
        #expect(raw.contains("From: me@example.com"))
        #expect(raw.contains("To: sarah@acme.com"))
        #expect(raw.contains("In-Reply-To: <orig>"))

        let encoded = MIMEBuilder.base64URL(Data("a/b+c==".utf8))
        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }

    @Test func mailBackendMapsActionsAndNoOps() async throws {
        let fake = FakeHTTPClient()
        await fake.enqueueJSON(#"{"id":"m1"}"#)
        let backend = GmailMailBackend(
            http: fake,
            tokenProvider: StubTokenProvider(token: "T"),
            accountEmail: "me@example.com"
        )

        try await backend.apply(.star, to: Self.message)
        let request = try #require(await fake.recordedRequests.first)
        #expect(request.url?.path == "/gmail/v1/users/me/messages/m1/modify")
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        #expect(body?["addLabelIds"] as? [String] == ["STARRED"])

        let noOpHTTP = FakeHTTPClient()
        let noOp = GmailMailBackend(
            http: noOpHTTP,
            tokenProvider: StubTokenProvider(token: "T"),
            accountEmail: "me@example.com"
        )
        try await noOp.apply(.parseDoc, to: Self.message)
        #expect(await noOpHTTP.recordedRequests.isEmpty)
    }

    @Test func mailBackendResolvesLabelsAndThrowsHTTPStatus() async throws {
        let fake = FakeHTTPClient()
        await fake.enqueueJSON(#"{"labels":[{"id":"Label_1","name":"Invoices"}]}"#)
        await fake.enqueueJSON(#"{"id":"m1"}"#)
        let backend = GmailMailBackend(http: fake, tokenProvider: StubTokenProvider(token: "T"), accountEmail: "me@example.com")
        try await backend.apply(.label("Invoices"), to: Self.message)
        let requests = await fake.recordedRequests
        #expect(requests.map(\.url!.path) == ["/gmail/v1/users/me/labels", "/gmail/v1/users/me/messages/m1/modify"])

        let failingHTTP = FakeHTTPClient()
        await failingHTTP.enqueueJSON(#"{"error":"denied"}"#, status: 403)
        let failingBackend = GmailMailBackend(http: failingHTTP, tokenProvider: StubTokenProvider(token: "T"), accountEmail: "me@example.com")
        await #expect(throws: HTTPClientError.self) {
            try await failingBackend.apply(.archive, to: Self.message)
        }
    }

    @Test func parserExtractsMessageFields() throws {
        let plain = try GmailMessageParser.parse(json: Fixtures.plainTextMessageJSON, accountEmail: "me@example.com")
        #expect(plain.from == "sarah@acme.com")
        #expect(plain.to == ["me@example.com"])
        #expect(plain.subject == "Pricing question")
        #expect(plain.body.contains("How much"))
        #expect(plain.labels == ["INBOX", "UNREAD"])
        #expect(plain.threadId == "t-100")
        #expect(plain.date == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(!plain.hasAttachment)

        let attachment = try GmailMessageParser.parse(json: Fixtures.multipartWithAttachmentJSON, accountEmail: "me@example.com")
        #expect(attachment.hasAttachment)
        #expect(attachment.body.contains("plain text body"))

        let unsubscribe = try GmailMessageParser.parse(json: Fixtures.messageWithListUnsubscribeJSON, accountEmail: "me@example.com")
        #expect(unsubscribe.listUnsubscribeHeader?.contains("mailto:") == true)

        let mine = try GmailMessageParser.parse(json: Fixtures.messageFromUserJSON, accountEmail: "me@example.com")
        #expect(mine.isFromUser)
    }

    @Test func syncListsAndFetchesMessages() async throws {
        let fake = FakeHTTPClient()
        await fake.enqueueJSON(Fixtures.listJSON)
        await fake.enqueueJSON(Fixtures.plainTextMessageJSON)
        await fake.enqueueJSON(Fixtures.messageWithListUnsubscribeJSON)
        let sync = GmailSync(http: fake, tokenProvider: StubTokenProvider(token: "T"), accountEmail: "me@example.com")

        let messages = try await sync.fetchMessages(query: "in:inbox", maxResults: 50)
        #expect(messages.count == 2)
        #expect(await fake.recordedRequests.count == 3)
    }

    @Test func publicBackendConformsToMailBackend() {
        let backend = GmailMailBackend(
            http: FakeHTTPClient(),
            tokenProvider: StubTokenProvider(token: "T"),
            accountEmail: "me@example.com"
        )
        let _: any MailBackend = backend
    }

    static let message = Message(
        id: "m1",
        from: "sarah@acme.com",
        to: ["me@example.com"],
        subject: "Pricing",
        body: "Body",
        hasAttachment: false,
        listUnsubscribeHeader: nil,
        labels: ["INBOX"],
        threadId: "t1",
        date: Date(timeIntervalSince1970: 0),
        isFromUser: false
    )
}

actor FakeHTTPClient: HTTPClient {
    struct Queued {
        let data: Data
        let response: HTTPURLResponse
    }

    private var queue: [Queued] = []
    private(set) var recordedRequests: [URLRequest] = []

    func enqueue(data: Data, response: HTTPURLResponse) {
        queue.append(Queued(data: data, response: response))
    }

    func enqueueJSON(
        _ json: String,
        status: Int = 200,
        url: URL = URL(string: "https://gmail.googleapis.com")!
    ) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        queue.append(Queued(data: Data(json.utf8), response: response))
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        recordedRequests.append(request)
        guard !queue.isEmpty else {
            throw HTTPClientError.noQueuedResponse
        }
        let next = queue.removeFirst()
        return (next.data, next.response)
    }
}

struct StubTokenProvider: AccessTokenProviding {
    let token: String

    func validAccessToken() async throws -> String {
        token
    }
}

enum Fixtures {
    static let listJSON = #"{"messages":[{"id":"plain"},{"id":"unsub"}]}"#
    static let plainTextMessageJSON = messageJSON(
        id: "plain",
        threadId: "t-100",
        from: "Sarah <sarah@acme.com>",
        to: "me@example.com",
        subject: "Pricing question",
        labels: ["INBOX", "UNREAD"],
        body: "How much is the enterprise plan?",
        internalDate: "1700000000000"
    )

    static let multipartWithAttachmentJSON: String = {
        let body = base64URL("plain text body")
        return """
        {"id":"attach","threadId":"t-200","labelIds":["INBOX"],"internalDate":"1700000000000",
         "payload":{"mimeType":"multipart/mixed","headers":[
           {"name":"From","value":"sarah@acme.com"},{"name":"To","value":"me@example.com"},{"name":"Subject","value":"Invoice"}],
           "parts":[{"mimeType":"multipart/alternative","parts":[
             {"mimeType":"text/plain","body":{"data":"\(body)"}},
             {"mimeType":"text/html","body":{"data":"\(base64URL("<b>html</b>"))"}}]},
             {"mimeType":"application/pdf","filename":"invoice.pdf","body":{}}]}}
        """
    }()

    static let messageWithListUnsubscribeJSON = messageJSON(
        id: "unsub",
        threadId: "t-300",
        from: "newsletter@example.com",
        to: "me@example.com",
        subject: "News",
        labels: ["INBOX"],
        body: "hello",
        internalDate: "1700000000000",
        extraHeaders: [("List-Unsubscribe", "<mailto:unsubscribe@example.com>")]
    )

    static let messageFromUserJSON = messageJSON(
        id: "mine",
        threadId: "t-400",
        from: "Me <me@example.com>",
        to: "sarah@acme.com",
        subject: "Sent",
        labels: ["SENT"],
        body: "sent",
        internalDate: "1700000000000"
    )

    private static func messageJSON(
        id: String,
        threadId: String,
        from: String,
        to: String,
        subject: String,
        labels: [String],
        body: String,
        internalDate: String,
        extraHeaders: [(String, String)] = []
    ) -> String {
        let headers = ([("From", from), ("To", to), ("Subject", subject)] + extraHeaders)
            .map { #"{"name":"\#($0.0)","value":"\#($0.1)"}"# }
            .joined(separator: ",")
        let labelsJSON = labels.map { #""\#($0)""# }.joined(separator: ",")
        return """
        {"id":"\(id)","threadId":"\(threadId)","labelIds":[\(labelsJSON)],"internalDate":"\(internalDate)",
         "payload":{"mimeType":"text/plain","headers":[\(headers)],"body":{"data":"\(base64URL(body))"}}}
        """
    }

    private static func base64URL(_ value: String) -> String {
        MIMEBuilder.base64URL(Data(value.utf8))
    }
}
