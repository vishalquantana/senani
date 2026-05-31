import SwiftUI
import SenaniRules

/// Internal sample host so the gallery #Preview can drive a stateful AutonomyDial.
private struct DesignGallery: View {
    @State private var autonomy: Autonomy = .prepare

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Text("Senani Design System")
                    .font(.senaniTitle).foregroundStyle(Color.senaniInk)

                GlassPanel {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            CategoryChip(.lead); CategoryChip(.booking); CategoryChip(.proposal)
                        }
                        Text("Acme Corp — pricing enquiry")
                            .font(.senaniBody.weight(.semibold)).foregroundStyle(Color.senaniInk)
                        Text("Reply drafted in your voice · lead scored 87")
                            .font(.senaniBody).foregroundStyle(Color.senaniMuted)
                    }
                    .padding(20)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Autonomy").font(.senaniBody).foregroundStyle(Color.senaniMuted)
                    AutonomyDial($autonomy)
                }

                PrimaryButton("Approve & send") { }
            }
            .padding(40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.senaniSurface)
    }
}

#Preview("Gallery") {
    DesignGallery()
}
