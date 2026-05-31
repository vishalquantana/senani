import Combine
import Foundation
import SenaniRules
import SenaniStore

@MainActor
final class InboxCockpitViewModel: ObservableObject {
    typealias MessageReader = () throws -> [Message]
    typealias ThreadReader = (String) throws -> [Message]
    typealias ApprovalReader = () throws -> [StoredProposal]
    typealias AuditReader = () async throws -> [AuditEntry]
    typealias ProcessAction = () async throws -> Void

    @Published private(set) var sections: [InboxSection] = []
    @Published private(set) var selectedThread: [Message] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var errorMessage: String?

    private var readMessages: MessageReader
    private var readThread: ThreadReader
    private var readApprovals: ApprovalReader
    private var readAuditEntries: AuditReader
    private var process: ProcessAction

    init(
        messages: @escaping MessageReader = { [] },
        thread: @escaping ThreadReader = { _ in [] },
        approvals: @escaping ApprovalReader = { [] },
        auditEntries: @escaping AuditReader = { [] },
        process: @escaping ProcessAction = {}
    ) {
        self.readMessages = messages
        self.readThread = thread
        self.readApprovals = approvals
        self.readAuditEntries = auditEntries
        self.process = process
    }

    func bind(environment: AppEnvironment) {
        readMessages = { try environment.messages.all() }
        readThread = { try environment.messages.thread(id: $0) }
        readApprovals = { try environment.approvals.pending() }
        readAuditEntries = { try await environment.audit.records() }
        process = { _ = try await environment.scheduler.tick() }
    }

    func refresh(selectedMessageID: Message.ID?) async -> Message.ID? {
        do {
            let messages = try readMessages()
            let approvals = try readApprovals()
            let auditEntries = try await readAuditEntries()
            sections = InboxGrouping.buildSections(
                messages: messages,
                approvals: approvals,
                auditEntries: auditEntries
            )
            errorMessage = nil

            let resolvedSelection = selectedMessageID.flatMap { id in
                sections.lazy.flatMap(\.rows).contains(where: { $0.id == id }) ? id : nil
            } ?? sections.first?.rows.first?.id
            refreshThread(selectedMessageID: resolvedSelection)
            return resolvedSelection
        } catch {
            errorMessage = error.localizedDescription
            return selectedMessageID
        }
    }

    func refreshThread(selectedMessageID: Message.ID?) {
        guard let selectedMessageID else {
            selectedThread = []
            return
        }

        do {
            selectedThread = try readThread(selectedMessageID)
            errorMessage = nil
        } catch {
            selectedThread = []
            errorMessage = error.localizedDescription
        }
    }

    func processInbox(selectedMessageID: Message.ID?) async -> Message.ID? {
        guard !isProcessing else { return selectedMessageID }
        isProcessing = true
        defer { isProcessing = false }

        do {
            try await process()
            return await refresh(selectedMessageID: selectedMessageID)
        } catch {
            errorMessage = error.localizedDescription
            return selectedMessageID
        }
    }
}
