import Foundation

/// One kanban lane: a stage and the deals currently in it (already sorted for display).
public struct StageColumn: Sendable, Identifiable {
    public var stage: DealStage
    public var deals: [Deal]
    public var id: String { stage.rawValue }
    public init(stage: DealStage, deals: [Deal]) {
        self.stage = stage
        self.deals = deals
    }
}

/// Pure grouping/sorting for the Pipeline view — no SwiftUI, no I/O. The view loads `[Deal]`
/// from a `PipelineStore` and hands them here; this returns one column per stage in canonical
/// order (every stage present, even empty), each column sorted by lastTouch desc then id asc.
public enum PipelineViewModel {
    public static func columns(from deals: [Deal]) -> [StageColumn] {
        let grouped = Dictionary(grouping: deals, by: \.stage)
        return DealStage.allCases.map { stage in
            let sorted = (grouped[stage] ?? []).sorted { lhs, rhs in
                if lhs.lastTouch != rhs.lastTouch { return lhs.lastTouch > rhs.lastTouch }
                return lhs.id < rhs.id
            }
            return StageColumn(stage: stage, deals: sorted)
        }
    }
}
