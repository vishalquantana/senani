import Foundation
import SenaniRules

/// Phase-3 Invoice / Finance agent. Watches inbound mail with an invoice/receipt
/// attachment, normalizes its finance fields (filling gaps via the model), persists
/// an `InvoiceRecord`, and emits reversible finance labels (+ an optional, approval-gated
/// payment-reminder reply).
public struct InvoiceFinanceAgent: Agent {
    public let id = "invoice-finance"
    public let autonomy: Autonomy = .prepare

    /// Category routing (Finding 9): invoices arrive under any category (detected by attachment/cues),
    /// so it subscribes to all and `wakesFor` (isInvoice) gates firing.
    public var categories: Set<String> { TriageCategory.allLabels }

    public static let invoiceLabel = "Senani/Finance/Invoice"
    public static let dueSoonLabel = "Senani/Finance/DueSoon"

    private let detector: InvoiceDetector
    private let normalizer: FinanceFieldNormalizer
    private let filler: InvoiceFieldFiller
    private let remindOnDueSoon: Bool
    private let dueSoonWindow: TimeInterval

    public init(
        detector: InvoiceDetector = InvoiceDetector(),
        normalizer: FinanceFieldNormalizer = FinanceFieldNormalizer(),
        filler: InvoiceFieldFiller = InvoiceFieldFiller(),
        remindOnDueSoon: Bool = false,
        dueSoonWindowDays: Int = 7
    ) {
        self.detector = detector
        self.normalizer = normalizer
        self.filler = filler
        self.remindOnDueSoon = remindOnDueSoon
        self.dueSoonWindow = TimeInterval(dueSoonWindowDays) * 86_400
    }

    // MARK: - Trigger

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        detector.isInvoice(message, documentFields: context.documentFields)
    }

    // MARK: - Proposals

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard detector.isInvoice(message, documentFields: context.documentFields) else { return [] }

        // 1. Normalize, filling gaps via the model only when sparse.
        var fields = normalizer.normalize(context.documentFields)
        if fields.isSparse {
            fields = try await filler.fill(fields, documentText: message.body,
                                           generateJSON: { prompt, schema in
                                               try await tools.generateJSON(prompt: prompt, schema: schema)
                                           })
        }

        // 2. Persist (pure store write — never an Action).
        // Writes happen inside `proposals` BY DESIGN (reconciliation §6); because the Orchestrator may
        // re-tick the same message, this must be IDEMPOTENT. We preserve the existing `capturedAt` when
        // the captured fields are unchanged (so the timestamp does not drift on a re-tick) and skip the
        // upsert entirely when the resulting record is materially identical.
        let recordId = Self.recordId(for: message, fields: fields)
        let existing = try? context.invoices.fetch(id: recordId)
        let record = InvoiceRecord(
            id: recordId,
            messageId: message.id,
            vendor: fields.vendor,
            invoiceNumber: fields.invoiceNumber,
            amount: fields.amount,
            currency: fields.currency,
            dueDate: fields.dueDate,
            capturedAt: Self.unchanged(existing, fields: fields, messageId: message.id)
                ? (existing?.capturedAt ?? context.now) : context.now)
        if existing != record {
            try context.invoices.upsert(record)
        }

        // 3. Labels.
        var actions: [Action] = [tools.proposeLabel(Self.invoiceLabel, on: message)]
        let due = isDueSoon(fields.dueDate, now: context.now)
        if due {
            actions.append(tools.proposeLabel(Self.dueSoonLabel, on: message))
        }

        // 4. Optional, approval-gated reminder (outbound → always queues).
        if remindOnDueSoon && due {
            actions.append(.reply(body: Self.reminderBody(fields)))
        }
        return actions
    }

    // MARK: - Pure helpers

    func isDueSoon(_ dueDate: Date?, now: Date) -> Bool {
        guard let due = dueDate else { return false }
        return due >= now && due <= now.addingTimeInterval(dueSoonWindow)
    }

    /// True when an already-stored record carries the same captured fields (everything except the
    /// `capturedAt` timestamp), so a re-tick should neither re-stamp nor re-write it.
    static func unchanged(_ existing: InvoiceRecord?, fields: InvoiceFields, messageId: String) -> Bool {
        guard let e = existing else { return false }
        return e.messageId == messageId
            && e.vendor == fields.vendor
            && e.invoiceNumber == fields.invoiceNumber
            && e.amount == fields.amount
            && e.currency == fields.currency
            && e.dueDate == fields.dueDate
    }

    static func recordId(for message: Message, fields: InvoiceFields) -> String {
        let who = fields.vendor ?? message.senderDomain
        let what = fields.invoiceNumber ?? message.id
        return "\(who):\(what)"
    }

    static func reminderBody(_ fields: InvoiceFields) -> String {
        let num = fields.invoiceNumber.map { " \($0)" } ?? ""
        return "Friendly reminder: invoice\(num) appears to be due soon. Please let me know if payment is already in progress."
    }
}
