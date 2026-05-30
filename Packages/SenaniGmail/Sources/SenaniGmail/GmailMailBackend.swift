import Foundation
import SenaniRules

public struct GmailMailBackend: MailBackend {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding
    private let accountEmail: String

    public init(
        http: any HTTPClient,
        tokenProvider: any AccessTokenProviding,
        accountEmail: String
    ) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.accountEmail = accountEmail
    }

    public func apply(_ action: Action, to message: Message) async throws {
        guard let request = try await request(for: action, message: message) else {
            return
        }
        let (data, response) = try await http.send(request)
        try GmailAuth.validate(response: response, data: data)
    }

    private func request(for action: Action, message: Message) async throws -> URLRequest? {
        let token = try await tokenProvider.validAccessToken()
        switch action {
        case .star:
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: ["STARRED"], removeLabelIds: [], accessToken: token)
        case .unstar:
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: [], removeLabelIds: ["STARRED"], accessToken: token)
        case .markRead:
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: [], removeLabelIds: ["UNREAD"], accessToken: token)
        case .markUnread:
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: ["UNREAD"], removeLabelIds: [], accessToken: token)
        case .archive:
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: [], removeLabelIds: ["INBOX"], accessToken: token)
        case .markSpam:
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: ["SPAM"], removeLabelIds: ["INBOX"], accessToken: token)
        case .label(let name):
            let labelID = try await resolveLabelID(name: name, token: token)
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: [labelID], removeLabelIds: [], accessToken: token)
        case .move(let name):
            let labelID = try await resolveLabelID(name: name, token: token)
            return GmailEndpoints.modify(messageId: message.id, addLabelIds: [labelID], removeLabelIds: ["INBOX"], accessToken: token)
        case .draft(let body):
            let raw = MIMEBuilder.message(
                from: accountEmail,
                to: [message.from],
                subject: replySubject(message.subject),
                body: body
            )
            return GmailEndpoints.createDraft(rawBase64URL: MIMEBuilder.base64URL(Data(raw.utf8)), accessToken: token)
        case .reply(let body):
            let raw = MIMEBuilder.message(
                from: accountEmail,
                to: [message.from],
                subject: replySubject(message.subject),
                body: body,
                inReplyTo: message.id,
                references: message.id
            )
            return GmailEndpoints.sendMessage(
                rawBase64URL: MIMEBuilder.base64URL(Data(raw.utf8)),
                threadId: message.threadId,
                accessToken: token
            )
        case .forward(let to, let body):
            let raw = MIMEBuilder.message(
                from: accountEmail,
                to: [to],
                subject: forwardSubject(message.subject),
                body: body
            )
            return GmailEndpoints.sendMessage(
                rawBase64URL: MIMEBuilder.base64URL(Data(raw.utf8)),
                threadId: message.threadId,
                accessToken: token
            )
        case .send(let body):
            let raw = MIMEBuilder.message(
                from: accountEmail,
                to: message.to,
                subject: message.subject,
                body: body
            )
            return GmailEndpoints.sendMessage(
                rawBase64URL: MIMEBuilder.base64URL(Data(raw.utf8)),
                threadId: nil,
                accessToken: token
            )
        case .fileAttachment, .parseDoc, .flagNeedsReply, .runAgent, .localWebhook:
            return nil
        }
    }

    private func resolveLabelID(name: String, token: String) async throws -> String {
        let listRequest = GmailEndpoints.listLabels(accessToken: token)
        let (listData, listResponse) = try await http.send(listRequest)
        try GmailAuth.validate(response: listResponse, data: listData)
        let labels = try JSONDecoder().decode(GmailLabelList.self, from: listData).labels ?? []
        if let match = labels.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return match.id
        }

        let createRequest = GmailEndpoints.createLabel(name: name, accessToken: token)
        let (createData, createResponse) = try await http.send(createRequest)
        try GmailAuth.validate(response: createResponse, data: createData)
        return try JSONDecoder().decode(GmailLabel.self, from: createData).id
    }

    private func replySubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("re:") ? subject : "Re: \(subject)"
    }

    private func forwardSubject(_ subject: String) -> String {
        subject.lowercased().hasPrefix("fwd:") ? subject : "Fwd: \(subject)"
    }
}
