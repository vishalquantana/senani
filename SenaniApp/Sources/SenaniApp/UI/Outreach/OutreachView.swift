import SwiftUI
import SenaniEngine
import SenaniRules
import SenaniDesign

/// The Outreach screen. User-initiated and list-driven: it shows the dormant deals the engine
/// surfaces, lets the user select which contacts to reach out to, and a single button drafts a
/// voice-conditioned message per selection. Drafts are QUEUED FOR APPROVAL — they never auto-send;
/// they appear in the Approvals screen for the human to review. A thin renderer over
/// OutreachViewModel — all logic lives there.
struct OutreachView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: OutreachViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Outreach")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                Text("Dormant deals worth a nudge. Select contacts and draft an outreach message — "
                    + "each draft is queued for your approval (never sent automatically) and appears "
                    + "in the Approvals screen.")
                    .font(.senaniBody).foregroundStyle(Color.senaniMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let model, model.rows.isEmpty {
                    Text("No dormant deals right now. Outreach targets appear here once open deals "
                        + "go quiet past their cooldown.")
                        .font(.senaniBody).foregroundStyle(Color.senaniMuted)
                        .padding(.vertical, 24)
                }

                ForEach(model?.rows ?? []) { row in
                    targetCard(row)
                }

                if let model, !model.rows.isEmpty {
                    HStack {
                        Text("\(model.selectedCount) selected")
                            .font(.system(size: 12)).foregroundStyle(Color.senaniMuted)
                        Spacer()
                        PrimaryButton("Draft outreach (queues for approval)") {
                            Task { await model.draftSelected() }
                        }
                        .disabled(model.selectedCount == 0 || model.isDrafting)
                    }
                    .padding(.top, 8)
                }

                if let queued = model?.lastQueuedCount {
                    Text(queued == 0
                         ? "Nothing was queued."
                         : "Queued \(queued) draft\(queued == 1 ? "" : "s") for approval. Review them in the Approvals screen.")
                        .font(.senaniBody).foregroundStyle(Color.senaniAccent)
                }

                if let err = model?.lastError {
                    Text("Couldn’t draft outreach: \(err)")
                        .font(.senaniBody).foregroundStyle(.red)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = OutreachViewModel(environment: env) }
            model?.refresh()
        }
    }

    @ViewBuilder
    private func targetCard(_ row: OutreachViewModel.Row) -> some View {
        GlassPanel {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(row.isSelected ? Color.senaniAccent : Color.senaniMuted)
                    .font(.system(size: 18))
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.company ?? row.contactEmail)
                        .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                    if row.company != nil {
                        Text(row.contactEmail)
                            .font(.system(size: 12)).foregroundStyle(Color.senaniMuted)
                    }
                    HStack(spacing: 8) {
                        if let stage = row.stage {
                            StatusBadge(text: stage, color: Color.senaniGold)
                        }
                        if let touch = row.lastTouch {
                            Text("last touch \(Self.relative(touch))")
                                .font(.system(size: 10)).foregroundStyle(Color.senaniMuted)
                        }
                    }
                }
                Spacer()
            }
            .padding(20)
            .contentShape(Rectangle())
        }
        .onTapGesture { model?.toggle(id: row.id) }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    let env = AppEnvironment.preview()
    // Seed a dormant deal (open stage, last touched well past the cooldown) so the list is non-empty.
    try? env.pipeline.upsert(
        Deal(id: "dormant@globex.com", contactEmail: "dormant@globex.com", company: "Globex",
             stage: .negotiation, score: 64, value: 24_000,
             lastTouch: Date().addingTimeInterval(-45 * 86_400), sourceMessageId: nil))
    return OutreachView().environmentObject(env)
}
