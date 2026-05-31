import SwiftUI

/// Testable spec for the brand's gold CTA (.btn-gold).
public struct PrimaryButtonStyleSpec: Sendable, Equatable {
    public var cornerRadius: CGFloat
    public var textHex: String          // dark ink that reads on gold
    public var horizontalPadding: CGFloat
    public var verticalPadding: CGFloat

    public init(cornerRadius: CGFloat, textHex: String,
                horizontalPadding: CGFloat, verticalPadding: CGFloat) {
        self.cornerRadius = cornerRadius
        self.textHex = textHex
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
    }

    public static let `default` = PrimaryButtonStyleSpec(
        cornerRadius: 11, textHex: "#1a1408", horizontalPadding: 20, verticalPadding: 11)
}

/// The primary gold-gradient call-to-action (landing .btn-gold).
public struct PrimaryButton: View {
    public let title: String
    public let spec: PrimaryButtonStyleSpec
    public let action: () -> Void

    public init(_ title: String,
                spec: PrimaryButtonStyleSpec = .default,
                action: @escaping () -> Void) {
        self.title = title
        self.spec = spec
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Text(title)
                .font(.senaniBody.weight(.semibold))
                .foregroundStyle(Color(hex: spec.textHex))
                .padding(.horizontal, spec.horizontalPadding)
                .padding(.vertical, spec.verticalPadding)
                .background(
                    RoundedRectangle(cornerRadius: spec.cornerRadius, style: .continuous)
                        .fill(Gold.gradient)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview("PrimaryButton") {
    VStack(spacing: 16) {
        PrimaryButton("Approve & send") { }
        PrimaryButton("★ Star on GitHub") { }
    }
    .padding(40)
    .background(Color.senaniSurface)
}
