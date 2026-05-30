import SenaniInference

public enum AssistantTool: String, Codable, Sendable, Equatable, CaseIterable {
    case searchMessages
    case archive
    case draft
    case reply
    case createRuleDraft
}

public enum ToolSchema {
    public static let schema = JSONSchema.object(
        properties: [
            "tool": .string,
            "messageId": .string,
            "body": .string,
            "ruleName": .string,
        ],
        required: ["tool"]
    )
}
