import SwiftUI

/// Pure, testable description of a glass panel's geometry/opacities,
/// derived from the landing page's .mock-card / .agent card CSS.
public struct GlassPanelStyle: Sendable, Equatable {
    public var cornerRadius: CGFloat
    public var borderWidth: CGFloat
    public var borderOpacity: Double   // gold edge alpha (--line)
    public var fillOpacity: Double     // translucent white fill (--glass)

    public init(cornerRadius: CGFloat, borderWidth: CGFloat,
                borderOpacity: Double, fillOpacity: Double) {
        self.cornerRadius = cornerRadius
        self.borderWidth = borderWidth
        self.borderOpacity = borderOpacity
        self.fillOpacity = fillOpacity
    }

    /// The hero .mock-card style.
    public static let `default` = GlassPanelStyle(
        cornerRadius: 18, borderWidth: 1, borderOpacity: 0.16, fillOpacity: 0.045)
    /// The tighter .agent / .price card style.
    public static let compact = GlassPanelStyle(
        cornerRadius: 15, borderWidth: 1, borderOpacity: 0.16, fillOpacity: 0.045)
}

/// Frosted gold-glass container (reconciliation §3). A rounded rect with a
/// translucent white fill over .ultraThinMaterial frost, a thin gold edge,
/// and a soft drop shadow — the brand's .mock-card.
public struct GlassPanel<Content: View>: View {
    public let style: GlassPanelStyle
    private let content: Content

    public init(style: GlassPanelStyle = .default,
                @ViewBuilder content: () -> Content) {
        self.style = style
        self.content = content()
    }

    public var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(style.fillOpacity))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
                    .strokeBorder(Gold.base.opacity(style.borderOpacity),
                                  lineWidth: style.borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, x: 0, y: 20)
    }
}

#Preview("GlassPanel") {
    GlassPanel {
        VStack(alignment: .leading, spacing: 8) {
            Text("Senani · handled overnight").font(.senaniTitle).foregroundStyle(Color.senaniInk)
            Text("3 threads need a reply.").font(.senaniBody).foregroundStyle(Color.senaniMuted)
        }
        .padding(24)
    }
    .padding(40)
    .background(Color.senaniSurface)
}
