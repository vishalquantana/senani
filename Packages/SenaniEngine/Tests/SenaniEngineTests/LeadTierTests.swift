import Testing
@testable import SenaniEngine

@Suite struct LeadTierTests {
    @Test func leadTierThresholds() {
        // Cold: 0..39, Warm: 40..69, Hot: 70..100 (inclusive boundaries).
        #expect(LeadTier(score: 0) == .cold)
        #expect(LeadTier(score: 39) == .cold)
        #expect(LeadTier(score: 40) == .warm)
        #expect(LeadTier(score: 69) == .warm)
        #expect(LeadTier(score: 70) == .hot)
        #expect(LeadTier(score: 100) == .hot)
    }

    @Test func leadTierLabelStrings() {
        #expect(LeadTier.hot.label == "Senani/Lead/Hot")
        #expect(LeadTier.warm.label == "Senani/Lead/Warm")
        #expect(LeadTier.cold.label == "Senani/Lead/Cold")
    }

    @Test func leadIntentParseIsCaseInsensitiveWithFallback() {
        #expect(LeadIntent.parse("ready") == .ready)
        #expect(LeadIntent.parse("EVALUATING") == .evaluating)
        #expect(LeadIntent.parse(" Info ") == .info)
        #expect(LeadIntent.parse("spam") == .spam)
        #expect(LeadIntent.parse("banana") == .info)   // unknown -> .info (neutral fallback)
        #expect(LeadIntent.parse("") == .info)
    }

    @Test func leadIntentAllCasesAreStableWireStrings() {
        #expect(LeadIntent.allCases.map(\.rawValue).sorted()
                == ["evaluating", "info", "ready", "spam"])
    }
}
