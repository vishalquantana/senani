import SwiftUI

/// A triage category surfaced as a colored chip (landing mock: Lead/Booking/Proposal).
/// Open-ended via `.other` for the full agent set; unknown categories reuse the gold style.
public enum Category: Sendable, Equatable {
    case lead
    case booking
    case proposal
    case other(String)

    public var title: String {
        switch self {
        case .lead: return "Lead"
        case .booking: return "Booking"
        case .proposal: return "Proposal"
        case .other(let name): return name
        }
    }

    /// Testable color seam: the three hex strings a chip is painted with.
    public var palette: (fillHex: String, textHex: String, borderHex: String) {
        switch self {
        case .lead, .other:
            // c-lead: gold fill, --gold-bright text, --line border.
            return ("#d4af3729", Gold.highlightHex, "#d4af3729")
        case .booking:
            // c-book: soft blue.
            return ("#78a0ff21", "#9db8ff", "#78a0ff33")
        case .proposal:
            // c-prop: soft green.
            return ("#78dca01f", "#84d8a4", "#78dca033")
        }
    }
}

/// A small pill chip tagging a message's category (the landing .chip).
public struct CategoryChip: View {
    public let category: Category

    public init(_ category: Category) { self.category = category }

    public var body: some View {
        let p = category.palette
        Text(category.title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color(hex: p.textHex))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color(hex: p.fillHex)))
            .overlay(Capsule().strokeBorder(Color(hex: p.borderHex), lineWidth: 1))
    }
}

#Preview("CategoryChips") {
    HStack(spacing: 10) {
        CategoryChip(.lead)
        CategoryChip(.booking)
        CategoryChip(.proposal)
        CategoryChip(.other("Invoice"))
    }
    .padding(40)
    .background(Color.senaniSurface)
}
