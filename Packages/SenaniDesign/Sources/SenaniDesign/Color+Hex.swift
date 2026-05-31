import SwiftUI

/// Pure, testable hex → RGBA parser. The seam color tokens are built from.
/// Accepts "#RRGGBB", "RRGGBB", "#RRGGBBAA", "RRGGBBAA". Malformed input
/// returns opaque black (never crashes) so a bad token degrades visibly, not fatally.
public enum HexColor {
    public static func rgba(hex: String) -> (r: Double, g: Double, b: Double, a: Double) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8,
              let value = UInt64(s, radix: 16) else {
            return (0, 0, 0, 1)
        }
        if s.count == 6 {
            let r = Double((value & 0xFF0000) >> 16) / 255.0
            let g = Double((value & 0x00FF00) >> 8) / 255.0
            let b = Double(value & 0x0000FF) / 255.0
            return (r, g, b, 1.0)
        } else {
            let r = Double((value & 0xFF000000) >> 24) / 255.0
            let g = Double((value & 0x00FF0000) >> 16) / 255.0
            let b = Double((value & 0x0000FF00) >> 8) / 255.0
            let a = Double(value & 0x000000FF) / 255.0
            return (r, g, b, a)
        }
    }
}

public extension Color {
    /// Brand-hex initializer (uses the pure HexColor seam).
    init(hex: String) {
        let c = HexColor.rgba(hex: hex)
        self = Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a)
    }
}
