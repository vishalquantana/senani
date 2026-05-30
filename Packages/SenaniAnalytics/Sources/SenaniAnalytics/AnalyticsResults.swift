import Foundation

public struct SenderCount: Sendable, Equatable {
    public let sender: String
    public let count: Int
}

public struct DomainCount: Sendable, Equatable {
    public let domain: String
    public let count: Int
}

public struct VolumePoint: Sendable, Equatable {
    public let day: Date
    public let inbound: Int
    public let outbound: Int
}

public struct ReplyLatency: Sendable, Equatable {
    public let threadId: String
    public let seconds: Double
}

public struct RuleActivity: Sendable, Equatable {
    public let ruleId: String
    public let executed: Int
    public let prepared: Int
    public let queuedForApproval: Int
}
