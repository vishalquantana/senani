import Foundation

public struct SenderCount: Sendable, Equatable {
    public let sender: String
    public let count: Int
    public init(sender: String, count: Int) {
        self.sender = sender
        self.count = count
    }
}

public struct DomainCount: Sendable, Equatable {
    public let domain: String
    public let count: Int
    public init(domain: String, count: Int) {
        self.domain = domain
        self.count = count
    }
}

public struct VolumePoint: Sendable, Equatable {
    public let day: Date
    public let inbound: Int
    public let outbound: Int
    public init(day: Date, inbound: Int, outbound: Int) {
        self.day = day
        self.inbound = inbound
        self.outbound = outbound
    }
}

public struct ReplyLatency: Sendable, Equatable {
    public let threadId: String
    public let seconds: Double
    public init(threadId: String, seconds: Double) {
        self.threadId = threadId
        self.seconds = seconds
    }
}

public struct RuleActivity: Sendable, Equatable {
    public let ruleId: String
    public let executed: Int
    public let prepared: Int
    public let queuedForApproval: Int
    public init(ruleId: String, executed: Int, prepared: Int, queuedForApproval: Int) {
        self.ruleId = ruleId
        self.executed = executed
        self.prepared = prepared
        self.queuedForApproval = queuedForApproval
    }
}
