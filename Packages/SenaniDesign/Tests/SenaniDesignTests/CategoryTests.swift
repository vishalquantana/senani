import Testing
import SwiftUI
@testable import SenaniDesign

@Test func leadChipUsesGoldPalette() {
    let p = Category.lead.palette
    #expect(p.textHex == Gold.highlightHex)   // c-lead text is --gold-bright
}

@Test func bookingChipUsesBluePalette() {
    let p = Category.booking.palette
    #expect(p.textHex == "#9db8ff")            // c-book
}

@Test func proposalChipUsesGreenPalette() {
    let p = Category.proposal.palette
    #expect(p.textHex == "#84d8a4")            // c-prop
}

@Test func unknownCategoryFallsBackToGold() {
    let p = Category.other("Invoice").palette
    #expect(p.textHex == Gold.highlightHex)
}

@Test func categoryTitleIsHumanReadable() {
    #expect(Category.lead.title == "Lead")
    #expect(Category.booking.title == "Booking")
    #expect(Category.proposal.title == "Proposal")
    #expect(Category.other("Invoice").title == "Invoice")
}

@Test @MainActor func chipBuildsForEveryStyledCategory() {
    for c in [Category.lead, .booking, .proposal, .other("X")] {
        _ = CategoryChip(c).body
    }
}
