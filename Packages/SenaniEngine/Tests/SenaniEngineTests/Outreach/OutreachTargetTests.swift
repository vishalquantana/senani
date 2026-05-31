import Testing
import Foundation
@testable import SenaniEngine
import SenaniRules

@Suite struct OutreachTargetTests {
    @Test func contactWithNoDealIsNeverOnCooldown() {
        let t = OX.target(contact: "new@lead.com", deal: nil)
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 10)
        #expect(policy.isOnCooldown(t, now: OX.now) == false)
    }

    @Test func contactTouchedWithinCooldownIsSkipped() {
        let d = OX.deal(contact: "warm@lead.com", touchedDaysAgo: 3)   // 3 < 7
        let t = OX.target(contact: "warm@lead.com", deal: d)
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 10)
        #expect(policy.isOnCooldown(t, now: OX.now) == true)
    }

    @Test func contactTouchedBeyondCooldownIsEligible() {
        let d = OX.deal(contact: "cold@lead.com", touchedDaysAgo: 30)  // 30 > 7
        let t = OX.target(contact: "cold@lead.com", deal: d)
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 10)
        #expect(policy.isOnCooldown(t, now: OX.now) == false)
    }

    @Test func eligibleFiltersCooledContactsAndAppliesCap() {
        let targets = [
            OX.target(contact: "a@x.com", deal: nil),                          // eligible
            OX.target(contact: "b@x.com", deal: OX.deal(contact: "b@x.com", touchedDaysAgo: 1)),   // cooled
            OX.target(contact: "c@x.com", deal: OX.deal(contact: "c@x.com", touchedDaysAgo: 20)),  // eligible
            OX.target(contact: "d@x.com", deal: nil),                          // eligible (but capped out)
        ]
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 2)
        let eligible = policy.eligible(from: targets, now: OX.now)
        #expect(eligible.map(\.contactEmail) == ["a@x.com", "c@x.com"])   // b cooled, cap=2 drops d
    }

    @Test func capOfZeroYieldsNothing() {
        let targets = [OX.target(contact: "a@x.com")]
        let policy = OutreachPolicy(cooldownDays: 7, maxPerRun: 0)
        #expect(policy.eligible(from: targets, now: OX.now).isEmpty)
    }
}
