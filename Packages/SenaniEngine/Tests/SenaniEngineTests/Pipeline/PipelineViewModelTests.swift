import Testing
import Foundation
@testable import SenaniEngine

@Suite struct PipelineViewModelTests {
    private func deal(_ id: String, stage: DealStage, touch: TimeInterval) -> Deal {
        Deal(id: id, contactEmail: "\(id)@x.com", company: nil, stage: stage, score: nil,
             value: nil, lastTouch: Date(timeIntervalSince1970: touch), sourceMessageId: nil)
    }

    @Test func emitsAllSixStagesInCanonicalOrderEvenWhenEmpty() {
        let columns = PipelineViewModel.columns(from: [])
        #expect(columns.map(\.stage) == [.lead, .qualified, .proposal, .negotiation, .won, .lost])
        #expect(columns.allSatisfy { $0.deals.isEmpty })
    }

    @Test func groupsDealsIntoTheirStageColumns() {
        let deals = [
            deal("a", stage: .qualified, touch: 10),
            deal("b", stage: .proposal, touch: 20),
            deal("c", stage: .qualified, touch: 30),
        ]
        let columns = PipelineViewModel.columns(from: deals)
        let qualified = columns.first { $0.stage == .qualified }!
        let proposal = columns.first { $0.stage == .proposal }!
        #expect(qualified.deals.map(\.id) == ["c", "a"])   // newer lastTouch first
        #expect(proposal.deals.map(\.id) == ["b"])
        #expect(columns.first { $0.stage == .won }!.deals.isEmpty)
    }

    @Test func sortsByLastTouchDescThenIdAsc() {
        let deals = [
            deal("z", stage: .lead, touch: 100),
            deal("a", stage: .lead, touch: 100),   // tie on lastTouch → id ascending
            deal("m", stage: .lead, touch: 200),
        ]
        let column = PipelineViewModel.columns(from: deals).first { $0.stage == .lead }!
        #expect(column.deals.map(\.id) == ["m", "a", "z"])
    }

    @Test func columnCountReflectsDealsInThatStage() {
        let deals = [deal("a", stage: .won, touch: 1), deal("b", stage: .won, touch: 2)]
        let columns = PipelineViewModel.columns(from: deals)
        #expect(columns.first { $0.stage == .won }!.deals.count == 2)
        #expect(columns.first { $0.stage == .lost }!.deals.count == 0)
    }
}
