import Foundation

public enum GmailEndpoints {
    static let baseURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me")!

    public static func modify(
        messageId: String,
        addLabelIds: [String],
        removeLabelIds: [String],
        accessToken: String
    ) -> URLRequest {
        var request = authorizedRequest(
            path: "messages/\(messageId)/modify",
            method: "POST",
            accessToken: accessToken
        )
        setJSONBody(["addLabelIds": addLabelIds, "removeLabelIds": removeLabelIds], on: &request)
        return request
    }

    public static func listMessages(
        query: String?,
        pageToken: String?,
        maxResults: Int,
        accessToken: String
    ) -> URLRequest {
        var components = URLComponents(url: baseURL.appendingPathComponent("messages"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "maxResults", value: String(maxResults))]
        if let query {
            items.append(URLQueryItem(name: "q", value: query))
        }
        if let pageToken {
            items.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        components.queryItems = items
        return authorizedRequest(url: components.url!, method: "GET", accessToken: accessToken)
    }

    public static func getMessage(id: String, accessToken: String) -> URLRequest {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("messages").appendingPathComponent(id),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [URLQueryItem(name: "format", value: "full")]
        return authorizedRequest(url: components.url!, method: "GET", accessToken: accessToken)
    }

    public static func createDraft(rawBase64URL: String, accessToken: String) -> URLRequest {
        var request = authorizedRequest(path: "drafts", method: "POST", accessToken: accessToken)
        setJSONBody(["message": ["raw": rawBase64URL]], on: &request)
        return request
    }

    public static func sendMessage(
        rawBase64URL: String,
        threadId: String?,
        accessToken: String
    ) -> URLRequest {
        var request = authorizedRequest(path: "messages/send", method: "POST", accessToken: accessToken)
        var body: [String: Any] = ["raw": rawBase64URL]
        if let threadId {
            body["threadId"] = threadId
        }
        setJSONBody(body, on: &request)
        return request
    }

    public static func listLabels(accessToken: String) -> URLRequest {
        authorizedRequest(path: "labels", method: "GET", accessToken: accessToken)
    }

    public static func createLabel(name: String, accessToken: String) -> URLRequest {
        var request = authorizedRequest(path: "labels", method: "POST", accessToken: accessToken)
        setJSONBody(["name": name, "labelListVisibility": "labelShow", "messageListVisibility": "show"], on: &request)
        return request
    }

    private static func authorizedRequest(path: String, method: String, accessToken: String) -> URLRequest {
        authorizedRequest(url: baseURL.appendingPathComponent(path), method: method, accessToken: accessToken)
    }

    private static func authorizedRequest(url: URL, method: String, accessToken: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private static func setJSONBody(_ object: Any, on request: inout URLRequest) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

struct ListResponse: Decodable {
    var messages: [MessageRef]?
    var nextPageToken: String?
}

struct MessageRef: Decodable {
    var id: String
}

struct GmailFullMessage: Decodable {
    var id: String
    var threadId: String
    var labelIds: [String]?
    var internalDate: String?
    var payload: GmailPayload
}

struct GmailPayload: Decodable {
    var mimeType: String?
    var filename: String?
    var headers: [GmailHeader]?
    var body: GmailBody?
    var parts: [GmailPayload]?
}

struct GmailHeader: Decodable {
    var name: String
    var value: String
}

struct GmailBody: Decodable {
    var data: String?
}

struct GmailLabelList: Decodable {
    var labels: [GmailLabel]?
}

struct GmailLabel: Decodable {
    var id: String
    var name: String
}
