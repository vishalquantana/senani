import SwiftUI

/// The gold gradient stops (reconciliation §3). Hex values mined from
/// landing/index.html :root (--gold / --gold-bright / --gold-deep).
public enum Gold {
    // Hex constants are the testable seam; the Colors are derived from them.
    public static let baseHex = "#d4af37"        // --gold
    public static let highlightHex = "#f4dd95"   // --gold-bright
    public static let shadowHex = "#9c7a2e"      // --gold-deep

    public static let base = Color(hex: baseHex)
    public static let highlight = Color(hex: highlightHex)
    public static let shadow = Color(hex: shadowHex)

    /// Ordered stops for the 135° brand gradient (--gold-grad), highlight → base → shadow.
    public static let gradientStops = [highlightHex, baseHex, shadowHex]

    /// The brand gold gradient used by PrimaryButton and gold edges.
    /// 135° in CSS ≈ topLeading → bottomTrailing in SwiftUI.
    public static let gradient = LinearGradient(
        gradient: Gradient(stops: [
            .init(color: highlight, location: 0.0),
            .init(color: base, location: 0.45),
            .init(color: shadow, location: 1.0),
        ]),
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
