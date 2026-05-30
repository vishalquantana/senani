import Foundation
import SenaniRules

public enum GmailParseError: Error, Equatable {
    case decodingFailed
    case missingPayload
}

public enum GmailMessageParser {
    public static func parse(json: String, accountEmail: String) throws -> Message {
        guard let data = json.data(using: .utf8) else {
            throw GmailParseError.decodingFailed
        }
        let gmail = try JSONDecoder().decode(GmailFullMessage.self, from: data)
        return try parse(gmail, accountEmail: accountEmail)
    }

    static func parse(_ gmail: GmailFullMessage, accountEmail: String) throws -> Message {
        let headers = headersByLowercaseName(gmail.payload.headers ?? [])
        let from = headers["from"] ?? ""
        let to = (headers["to"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let subject = headers["subject"] ?? ""
        let body = findPlainTextBody(in: gmail.payload) ?? ""
        let internalDate = Double(gmail.internalDate ?? "") ?? 0

        return Message(
            id: gmail.id,
            from: extractEmail(from),
            to: to.map(extractEmail(_:)),
            subject: subject,
            body: body,
            hasAttachment: containsAttachment(gmail.payload),
            listUnsubscribeHeader: headers["list-unsubscribe"],
            labels: gmail.labelIds ?? [],
            threadId: gmail.threadId,
            date: Date(timeIntervalSince1970: internalDate / 1_000),
            isFromUser: extractEmail(from).caseInsensitiveCompare(accountEmail) == .orderedSame
        )
    }

    private static func headersByLowercaseName(_ headers: [GmailHeader]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: headers.map { ($0.name.lowercased(), $0.value) })
    }

    private static func findPlainTextBody(in payload: GmailPayload) -> String? {
        if payload.mimeType == "text/plain",
           let encoded = payload.body?.data,
           let text = decodeBase64URLString(encoded),
           !text.isEmpty {
            return text
        }
        if let encoded = payload.body?.data,
           payload.parts?.isEmpty != false,
           let text = decodeBase64URLString(encoded),
           !text.isEmpty {
            return text
        }
        for part in payload.parts ?? [] {
            if let text = findPlainTextBody(in: part) {
                return text
            }
        }
        return nil
    }

    private static func containsAttachment(_ payload: GmailPayload) -> Bool {
        if let filename = payload.filename, !filename.isEmpty {
            return true
        }
        return (payload.parts ?? []).contains { containsAttachment($0) }
    }

    static func decodeBase64URLString(_ encoded: String) -> String? {
        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard let data = Data(base64Encoded: base64) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func extractEmail(_ value: String) -> String {
        if let start = value.firstIndex(of: "<"), let end = value.firstIndex(of: ">"), start < end {
            return String(value[value.index(after: start)..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct GmailSync: Sendable {
    private let http: any HTTPClient
    private let tokenProvider: any AccessTokenProviding
    private let accountEmail: String

    public init(http: any HTTPClient, tokenProvider: any AccessTokenProviding, accountEmail: String) {
        self.http = http
        self.tokenProvider = tokenProvider
        self.accountEmail = accountEmail
    }

    public func fetchMessages(query: String, maxResults: Int) async throws -> [Message] {
        let token = try await tokenProvider.validAccessToken()
        var pageToken: String?
        var messages: [Message] = []

        repeat {
            let listRequest = GmailEndpoints.listMessages(
                query: query,
                pageToken: pageToken,
                maxResults: maxResults,
                accessToken: token
            )
            let (listData, listResponse) = try await http.send(listRequest)
            try GmailAuth.validate(response: listResponse, data: listData)
            let list = try JSONDecoder().decode(ListResponse.self, from: listData)

            for ref in list.messages ?? [] {
                let getRequest = GmailEndpoints.getMessage(id: ref.id, accessToken: token)
                let (data, response) = try await http.send(getRequest)
                try GmailAuth.validate(response: response, data: data)
                let full = try JSONDecoder().decode(GmailFullMessage.self, from: data)
                messages.append(try GmailMessageParser.parse(full, accountEmail: accountEmail))
            }
            pageToken = list.nextPageToken
        } while pageToken != nil

        return messages
    }
}
