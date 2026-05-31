import SwiftUI
import SenaniEngine
import SenaniDesign

/// The Phase-3 Pipeline / CRM view: deals grouped by stage in a gold-glass kanban.
/// Pure grouping/sorting is delegated to `PipelineViewModel`; this file is presentation only.
struct PipelineView: View {
    let deals: [Deal]
    /// Host seam: open the source thread for a tapped deal (passes sourceMessageId or deal id).
    var onOpenThread: (String) -> Void = { _ in }

    private var columns: [StageColumn] { PipelineViewModel.columns(from: deals) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(alignment: .top, spacing: 16) {
                ForEach(columns) { column in
                    StageLane(column: column, onOpenThread: onOpenThread)
                        .frame(width: 280)
                }
            }
            .padding(20)
        }
        .background(Color.senaniSurface.opacity(0.6))
        .navigationTitle("Pipeline")
    }
}

private struct StageLane: View {
    let column: StageColumn
    var onOpenThread: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                WordmarkHeader(title: column.stage.rawValue)
                Spacer()
                Text("\(column.deals.count)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            if column.deals.isEmpty {
                Text("No deals")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(column.deals) { deal in
                    DealCard(deal: deal)
                        .onTapGesture { onOpenThread(deal.sourceMessageId ?? deal.id) }
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DealCard: View {
    let deal: Deal

    var body: some View {
        GlassPanel(style: .compact) {
            VStack(alignment: .leading, spacing: 6) {
                Text(deal.company ?? deal.contactEmail)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.senaniInk)
                    .lineLimit(1)
                if deal.company != nil {
                    Text(deal.contactEmail)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.senaniMuted)
                        .lineLimit(1)
                }
                HStack(spacing: 8) {
                    StatusBadge(text: deal.stage.rawValue, color: Color.senaniGold)
                    if let score = deal.score {
                        Text("score \(score)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.senaniMuted)
                    }
                }
                HStack {
                    if let value = deal.value {
                        Text(Self.currency(value))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.senaniGold)
                    }
                    Spacer()
                    Text(Self.relative(deal.lastTouch))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.senaniMuted)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static func currency(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.maximumFractionDigits = 0
        return f.string(from: value as NSNumber) ?? "\(Int(value))"
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    PipelineView(deals: AppEnvironment.preview().seededDeals)
}

private extension AppEnvironment {
    var seededDeals: [Deal] { AppEnvironment.seededDeals }
}
