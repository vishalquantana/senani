import Testing
@testable import SenaniLicensing

@Test func tierRawValuesAreStableWireStrings() {
    #expect(LicenseTier.core.rawValue == "core")
    #expect(LicenseTier.pro.rawValue == "pro")
    #expect(LicenseTier(rawValue: "pro") == .pro)
    #expect(LicenseTier(rawValue: "enterprise") == nil)
}

@Test func proOutranksCore() {
    #expect(LicenseTier.pro > LicenseTier.core)
    #expect(LicenseTier.core < LicenseTier.pro)
    #expect(LicenseTier.pro >= LicenseTier.pro)
}

@Test func coreUnlocksCoreFeaturesButNotPro() {
    let core = LicenseTier.core
    #expect(core.unlocks(.triage))
    #expect(core.unlocks(.replyDrafter))
    #expect(core.unlocks(.booking))
    #expect(core.unlocks(.dailyDigest))
    #expect(core.unlocks(.inboxHygiene))
    // Pro sales suite is locked on Core:
    #expect(!core.unlocks(.leadQualifier))
    #expect(!core.unlocks(.proposalTracker))
    #expect(!core.unlocks(.followUp))
    #expect(!core.unlocks(.outreach))
    #expect(!core.unlocks(.invoiceFinance))
    #expect(!core.unlocks(.pipelineCRM))
}

@Test func proUnlocksEverything() {
    let pro = LicenseTier.pro
    for feature in Feature.allCases {
        #expect(pro.unlocks(feature), "Pro must unlock \(feature)")
    }
}

@Test func featureAgentIDsMatchAgentContract() {
    // The agent-backed features expose the SAME stable id Agent.id uses, so the
    // composition root can filter agents by `tier.unlocks(.init(agentID:))`.
    #expect(Feature(agentID: "lead-qualifier") == .leadQualifier)
    #expect(Feature(agentID: "triage") == .triage)
    #expect(Feature(agentID: "unknown-agent") == nil)
    #expect(Feature.leadQualifier.agentID == "lead-qualifier")
    #expect(Feature.pipelineCRM.agentID == nil)   // not an agent
}
