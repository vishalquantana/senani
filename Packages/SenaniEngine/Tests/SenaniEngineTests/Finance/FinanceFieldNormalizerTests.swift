import Testing
import Foundation
@testable import SenaniEngine

@Suite struct FinanceFieldNormalizerTests {
    private let n = FinanceFieldNormalizer()

    @Test func parsesPlainAndGroupedAmounts() {
        #expect(FinanceFieldNormalizer.parseAmount("1234.56") == 1234.56)
        #expect(FinanceFieldNormalizer.parseAmount("$1,234.56") == 1234.56)
        #expect(FinanceFieldNormalizer.parseAmount("₹45,000") == 45000)
        #expect(FinanceFieldNormalizer.parseAmount("n/a") == nil)
        #expect(FinanceFieldNormalizer.parseAmount(nil) == nil)
    }

    @Test func normalizesCurrencyFromSymbolOrCode() {
        #expect(FinanceFieldNormalizer.normalizeCurrency("usd") == "USD")
        #expect(FinanceFieldNormalizer.normalizeCurrency("$") == "USD")
        #expect(FinanceFieldNormalizer.normalizeCurrency("€") == "EUR")
        #expect(FinanceFieldNormalizer.normalizeCurrency("£") == "GBP")
        #expect(FinanceFieldNormalizer.normalizeCurrency("₹") == "INR")
        #expect(FinanceFieldNormalizer.normalizeCurrency("eur") == "EUR")
        #expect(FinanceFieldNormalizer.normalizeCurrency("") == nil)
    }

    @Test func parsesDatesInSeveralFormats() {
        let iso = FinanceFieldNormalizer.parseDate("2026-06-10")
        let slash = FinanceFieldNormalizer.parseDate("06/10/2026")
        let spelled = FinanceFieldNormalizer.parseDate("10 Jun 2026")
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: iso!)
        #expect(comps.year == 2026 && comps.month == 6 && comps.day == 10)
        #expect(slash != nil)
        #expect(spelled != nil)
        #expect(FinanceFieldNormalizer.parseDate("not a date") == nil)
    }

    @Test func normalizesFullBagIntoInvoiceFields() {
        let f = n.normalize(FIN.fullFields)
        #expect(f.vendor == "Acme LLC")
        #expect(f.invoiceNumber == "INV-42")
        #expect(f.amount == 1234.56)
        #expect(f.currency == "USD")
        let comps = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(identifier: "UTC")!, from: f.dueDate!)
        #expect(comps.month == 6 && comps.day == 10)
    }

    @Test func readsSynonymKeys() {
        let f = n.normalize([
            "supplier": "Globex",          // vendor synonym
            "invoice_no": "X-9",           // invoice number synonym
            "total": "200",                // amount synonym
            "due": "2026-07-01"            // due-date synonym
        ])
        #expect(f.vendor == "Globex")
        #expect(f.invoiceNumber == "X-9")
        #expect(f.amount == 200)
        #expect(f.dueDate != nil)
    }

    @Test func missingFieldsBecomeNil() {
        let f = n.normalize([:])
        #expect(f.vendor == nil)
        #expect(f.invoiceNumber == nil)
        #expect(f.amount == nil)
        #expect(f.currency == nil)
        #expect(f.dueDate == nil)
        #expect(f.isSparse == true)
    }

    @Test func isSparseWhenAnyKeyFieldMissing() {
        let f = n.normalize(["amount": "100"])   // vendor / number / date missing
        #expect(f.isSparse == true)
        let full = n.normalize(FIN.fullFields)
        #expect(full.isSparse == false)
    }
}
