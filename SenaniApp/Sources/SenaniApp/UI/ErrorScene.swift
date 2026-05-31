import SwiftUI

/// Shown when the live composition root cannot be built at launch (most often
/// because the on-disk data store could not be opened). It explains the failure
/// plainly and never substitutes fake preview data for the user's real work.
struct ErrorScene: View {
    let error: Error

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)

            Text("Senani couldn't open its data store")
                .font(.title2.weight(.semibold))

            Text("""
            The app could not open the local database where your inbox, \
            approvals, and CRM data are stored, so it can't start safely.

            Quit and relaunch Senani. If the problem persists, check that the \
            application has permission to write to its support folder and that \
            the disk isn't full.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 480)

            Text(error.localizedDescription)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: 480, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Button("Quit Senani") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ErrorScene(error: NSError(
        domain: "SenaniDatabase",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "unable to open database file"]
    ))
}
