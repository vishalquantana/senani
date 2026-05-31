import Testing
import SenaniRules
@testable import SenaniEngine

/// Finding 9 wiring: the real agents declare the right `categories`, so the AgentRegistry
/// actually dispatches them (previously only BookingAgent declared categories, so the other
/// agents — defaulting to []), never routed).
@Suite struct AgentCategoriesTests {

    @Test func triageCategoryAllLabelsCoversEveryCase() {
        #expect(TriageCategory.allLabels.count == TriageCategory.allCases.count)
        #expect(TriageCategory.allLabels.contains(TriageCategory.lead.label))
        #expect(TriageCategory.allLabels.contains(TriageCategory.booking.label))
    }

    @Test func leadQualifierSubscribesOnlyToLead() {
        #expect(LeadQualifierAgent().categories == [TriageCategory.lead.label])
    }

    @Test func signalDrivenAgentsSubscribeToAllCategories() {
        #expect(InboxHygieneAgent().categories == TriageCategory.allLabels)
        #expect(InvoiceFinanceAgent().categories == TriageCategory.allLabels)
    }

    @Test func registryRoutesCategorySpecificAndSignalDrivenAgents() {
        let registry = AgentRegistry(agents: [LeadQualifierAgent(), InboxHygieneAgent()])

        let onLead = registry.agents(for: TriageCategory.lead.label).map(\.id)
        #expect(onLead.contains("lead-qualifier"))     // category-specific: matches Lead
        #expect(onLead.contains("inbox-hygiene"))      // signal-driven: subscribes to all

        let onBooking = registry.agents(for: TriageCategory.booking.label).map(\.id)
        #expect(!onBooking.contains("lead-qualifier"))  // Lead must NOT route on a Booking message
        #expect(onBooking.contains("inbox-hygiene"))    // signal-driven still routes
    }
}
