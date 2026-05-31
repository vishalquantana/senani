import SwiftUI
import SenaniRules
import SenaniDesign

/// The Approval Queue screen. Lists pending proposals as gold-glass cards;
/// Approve executes through the MailBackend, Reject discards. A thin renderer
/// over ApprovalQueueViewModel — all logic lives there.
struct ApprovalQueueView: View {
    @EnvironmentObject private var env: AppEnvironment
    @State private var model: ApprovalQueueViewModel?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Approvals")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                if let model, model.cards.isEmpty {
                    Text("Nothing waiting. Proposals your agents create will appear here for your approval.")
                        .font(.senaniBody).foregroundStyle(Color.senaniMuted)
                        .padding(.vertical, 24)
                }

                ForEach(model?.cards ?? []) { card in
                    cardView(card)
                }

                if let err = model?.lastError {
                    Text("Couldn’t complete the last action: \(err)")
                        .font(.senaniBody).foregroundStyle(.red)
                }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
        .task {
            if model == nil { model = ApprovalQueueViewModel(environment: env) }
            model?.refresh()
        }
    }

    @ViewBuilder
    private func cardView(_ card: ApprovalCard) -> some View {
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(card.actionSummary)
                        .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                    Spacer()
                    Text(card.kind == .outbound ? "Outbound" : "Reversible")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.senaniAccent)
                }
                Text(card.subject).font(.senaniBody).foregroundStyle(Color.senaniInk)
                Text(card.sender).font(.senaniBody).foregroundStyle(Color.senaniMuted)
                if !card.snippet.isEmpty {
                    Text(card.snippet).font(.senaniBody).foregroundStyle(Color.senaniMuted).lineLimit(3)
                }
                HStack {
                    Text("Proposed by \(card.proposingAgent)")
                        .font(.system(size: 11)).foregroundStyle(Color.senaniMuted)
                    Spacer()
                    Button("Reject") { Task { await model?.reject(id: card.id) } }
                        .buttonStyle(.plain).foregroundStyle(Color.senaniMuted)
                    PrimaryButton("Approve") { Task { await model?.approve(id: card.id) } }
                }
            }
            .padding(20)
        }
    }
}

#Preview {
    let env = AppEnvironment.preview()
    try? env.approvals.enqueue(id: "preview-ap",
        Proposal(action: .reply(body: "Our Pro tier is $199/yr — happy to set up a call."),
                 message: Message(id: "pm1", from: "Mark <mark@acme.com>", to: ["me@x.com"],
                                  subject: "Pricing enquiry", body: "Hi, what does the Pro tier cost?",
                                  hasAttachment: false, listUnsubscribeHeader: nil, labels: [],
                                  threadId: "t1", date: .now, isFromUser: false),
                 trigger: .rule(id: "reply-drafter")))
    return ApprovalQueueView().environmentObject(env)
}
