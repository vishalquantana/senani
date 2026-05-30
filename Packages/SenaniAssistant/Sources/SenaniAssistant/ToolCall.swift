import Foundation
import SenaniRules

public struct ToolCall: Sendable, Equatable {
    public var tool: AssistantTool
    public var messageId: String?
    public var body: String?
    public var ruleName: String?

    public init(tool: AssistantTool, messageId: String? = nil, body: String? = nil, ruleName: String? = nil) {
        self.tool = tool
        self.messageId = messageId
        self.body = body
        self.ruleName = ruleName
    }

    public static func parse(_ raw: String) -> ToolCall? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let toolRaw = object["tool"] as? String,
              let tool = AssistantTool(rawValue: toolRaw)
        else { return nil }
        return ToolCall(
            tool: tool,
            messageId: object["messageId"] as? String,
            body: object["body"] as? String,
            ruleName: object["ruleName"] as? String
        )
    }

    public func action() -> Action? {
        switch tool {
        case .archive:
            return .archive
        case .draft:
            return .draft(body: body ?? "")
        case .reply:
            return .reply(body: body ?? "")
        case .searchMessages, .createRuleDraft:
            return nil
        }
    }
}
