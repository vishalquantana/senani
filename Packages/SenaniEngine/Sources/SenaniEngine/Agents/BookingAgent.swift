import Foundation
import SenaniRules
import SenaniInference
import SenaniCalendar

/// Phase-2 Booking agent. Wakes for messages triaged into the "Booking" category (a label) or
/// that ask to meet, reads the user's free/busy through the injected `AvailabilityProviding` seam,
/// picks THREE concrete non-conflicting business-hours slots, and proposes them via ONE outbound
/// `reply` Action. `Action.reply` is `ActionClass.outbound`, so `ActionRouter.route` ALWAYS yields
/// `.queuedForApproval` — the agent NEVER auto-sends and NEVER books. (A real tentative hold needs
/// a new SenaniRules.Action case — §5 — and is deferred.)
public struct BookingAgent: Agent {
    public let id = "booking"
    /// Per-agent dial. Irrelevant to safety here: the emitted action is outbound, which
    /// `ActionRouter` queues regardless of autonomy.
    public let autonomy: Autonomy = .prepare

    /// The category label Triage assigns to scheduling mail. Triage emits the CANONICAL
    /// `TriageCategory.booking.label` ("Senani/Category/Booking"), so the agent MUST match that —
    /// not the bare "Booking" string it checked before (Finding 3).
    public static let category = TriageCategory.booking.label

    /// Category routing (Finding 9): the Orchestrator dispatches Booking-categorized mail here.
    public var categories: Set<String> { [Self.category] }
    /// Keywords that signal meeting intent when no Booking label is present.
    static let meetingKeywords = ["meet", "meeting", "schedule", "scheduling",
                                  "call", "calendar", "availability", "time to", "catch up"]

    private let availability: any AvailabilityProviding
    private let generator: (any TextGenerator)?
    private let timeZone: TimeZone
    let config: SlotConfig

    public init(
        availability: any AvailabilityProviding,
        generator: (any TextGenerator)? = nil,
        timeZone: TimeZone = .current,
        config: SlotConfig = .default
    ) {
        self.availability = availability
        self.generator = generator
        self.timeZone = timeZone
        self.config = config
    }

    public func wakesFor(_ message: Message, context: AgentContext) -> Bool {
        guard !message.isFromUser else { return false }
        if message.labels.contains(Self.category) { return true }
        let haystack = (message.subject + " " + message.body).lowercased()
        return Self.meetingKeywords.contains { haystack.contains($0) }
    }

    public func proposals(for message: Message, context: AgentContext, tools: AgentTools) async throws -> [Action] {
        guard wakesFor(message, context: context) else { return [] }

        let window = DateRange(
            start: context.now,
            end: context.now.addingTimeInterval(TimeInterval(config.searchDays * 86_400))
        )
        let busy = try await availability.busyIntervals(in: window)
        let slots = Self.pickSlots(now: context.now, busy: busy, config: config, timeZone: timeZone)

        let body: String
        if slots.isEmpty {
            body = fallbackBody(for: message)
        } else if let generator {
            let prompt = polishPrompt(slots: slots, message: message)
            let raw = try await generator.generate(prompt: prompt, maxTokens: Self.maxReplyTokens)
            let polished = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Always append the concrete slot lines so the proposal is unambiguous even if the model omits them.
            body = polished.isEmpty ? slotBody(slots: slots) : polished + "\n\n" + renderSlotLines(slots)
        } else {
            body = slotBody(slots: slots)
        }

        return [tools.draftReply(to: message, body: body)]
    }

    static let maxReplyTokens = 256

    // MARK: - Reply rendering (pure)

    private func slotBody(slots: [CalendarSlot]) -> String {
        "Thanks for reaching out — I'd be glad to meet. Here are a few times that work for me:\n\n"
            + renderSlotLines(slots)
            + "\n\nLet me know which suits you and I'll confirm."
    }

    private func renderSlotLines(_ slots: [CalendarSlot]) -> String {
        slots.map { "• " + format($0) }.joined(separator: "\n")
    }

    private func fallbackBody(for message: Message) -> String {
        "Thanks for reaching out — I'd be glad to meet. My calendar is quite full over the next few days; "
            + "could you share a couple of times that suit your availability and I'll confirm one?"
    }

    private func polishPrompt(slots: [CalendarSlot], message: Message) -> String {
        """
        Write a brief, friendly reply offering these meeting times (in my voice). \
        Keep it to two short sentences and do NOT invent times.

        \(PromptFencing.preamble)

        \(PromptFencing.fence("THEIR SUBJECT", message.subject))
        Proposed times:
        \(renderSlotLines(slots))
        """
    }

    private func format(_ slot: CalendarSlot) -> String {
        let df = DateFormatter()
        df.timeZone = timeZone
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE d MMM, HH:mm"
        let start = df.string(from: slot.start)
        let timeOnly = DateFormatter()
        timeOnly.timeZone = timeZone
        timeOnly.locale = Locale(identifier: "en_US_POSIX")
        timeOnly.dateFormat = "HH:mm"
        return "\(start)–\(timeOnly.string(from: slot.end))"
    }

    // MARK: - Pure slot selection (no I/O — independently testable)

    /// Walk business days from `now`, enumerate `slotMinutes` slots on the grid within business
    /// hours, skip past or busy-overlapping slots, and collect up to `config.slotsToPropose`.
    /// Returns fewer if the window is exhausted. Deterministic given the inputs.
    public static func pickSlots(
        now: Date,
        busy: [FreeBusyInterval],
        config: SlotConfig,
        timeZone: TimeZone
    ) -> [CalendarSlot] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        let slotLength = TimeInterval(config.slotMinutes * 60)
        let sortedBusy = busy.sorted { $0.start < $1.start }
        var found: [CalendarSlot] = []

        for dayOffset in 0..<config.searchDays {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: now) else { continue }
            // First slot of this business day.
            guard var cursor = calendar.date(
                bySettingHour: config.businessStartHour, minute: 0, second: 0, of: dayStart
            ) else { continue }
            guard let dayEnd = calendar.date(
                bySettingHour: config.businessEndHour, minute: 0, second: 0, of: dayStart
            ) else { continue }

            while cursor.addingTimeInterval(slotLength) <= dayEnd {
                let slotEnd = cursor.addingTimeInterval(slotLength)
                let inFuture = cursor >= now
                let overlapsBusy = sortedBusy.contains { $0.start < slotEnd && cursor < $0.end }
                if inFuture && !overlapsBusy {
                    found.append(CalendarSlot(start: cursor, end: slotEnd))
                    if found.count == config.slotsToPropose { return found }
                }
                cursor = slotEnd
            }
        }
        return found
    }
}

/// Tunable slot-selection policy (pure data — no I/O).
public struct SlotConfig: Sendable, Equatable {
    public let slotMinutes: Int           // proposed meeting length
    public let businessStartHour: Int     // inclusive, in the agent's time zone
    public let businessEndHour: Int       // exclusive
    public let searchDays: Int            // how many days forward to scan
    public let slotsToPropose: Int        // how many slots to offer

    public init(slotMinutes: Int = 30, businessStartHour: Int = 9, businessEndHour: Int = 17,
                searchDays: Int = 7, slotsToPropose: Int = 3) {
        self.slotMinutes = slotMinutes
        self.businessStartHour = businessStartHour
        self.businessEndHour = businessEndHour
        self.searchDays = searchDays
        self.slotsToPropose = slotsToPropose
    }

    public static let `default` = SlotConfig()
}
