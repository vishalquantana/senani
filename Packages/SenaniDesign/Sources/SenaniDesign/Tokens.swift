import SwiftUI

/// Brand-hex constants (the testable seam). Mined from landing/index.html :root.
public enum SenaniTokens {
    public static let inkHex = "#ece7dc"      // --ink   (primary text)
    public static let surfaceHex = "#08080b"  // --bg    (app background)
    public static let accentHex = "#e8c97a"   // --champagne (accent)
    public static let mutedHex = "#9b948a"    // --muted (secondary text)
}

public extension Color {
    /// Primary text on dark surfaces.
    static let senaniInk = Color(hex: SenaniTokens.inkHex)
    /// The near-black app background.
    static let senaniSurface = Color(hex: SenaniTokens.surfaceHex)
    /// Champagne accent (highlights, active edges).
    static let senaniAccent = Color(hex: SenaniTokens.accentHex)
    /// Secondary / muted text.
    static let senaniMuted = Color(hex: SenaniTokens.mutedHex)
}

public extension Font {
    /// Display/title intent (brand: Fraunces serif). System serif fallback;
    /// upgrade to a bundled Fraunces face is a documented deferred item.
    static let senaniTitle = Font.system(.title, design: .serif).weight(.medium)
    /// Body intent (brand: Hanken Grotesk). System default sans fallback.
    static let senaniBody = Font.system(.body, design: .default)
    /// Monospace intent (brand: code blocks). System monospaced.
    static let senaniMono = Font.system(.body, design: .monospaced)
}

public extension Color {
    static let senaniGold = Color(hex: "#d4af37")
    static let senaniObsidian = Color(white: 0.04)
}
