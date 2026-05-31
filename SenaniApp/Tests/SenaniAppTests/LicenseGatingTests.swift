import Testing
import SenaniLicensing
@testable import SenaniApp

@MainActor
@Test func licenseStateGatesByTier() {
    // No key → unlicensed → unlocks nothing.
    let unlicensed = LicenseState(status: .invalid)
    #expect(!unlicensed.unlocks(.triage))
    #expect(!unlicensed.unlocks(.leadQualifier))

    let core = LicenseState(status: .valid(.core))
    #expect(core.unlocks(.triage))
    #expect(!core.unlocks(.leadQualifier))

    let pro = LicenseState(status: .valid(.pro))
    #expect(pro.unlocks(.triage))
    #expect(pro.unlocks(.leadQualifier))
}

@MainActor
@Test func enabledAgentIDsReflectTier() {
    let core = LicenseState(status: .valid(.core))
    let all = ["triage", "reply-drafter", "booking", "daily-digest",
               "inbox-hygiene", "lead-qualifier", "proposal-tracker",
               "follow-up", "outreach", "invoice-finance"]
    let enabled = all.filter { core.enablesAgent(id: $0) }
    #expect(enabled.contains("triage"))
    #expect(!enabled.contains("lead-qualifier"))
}
