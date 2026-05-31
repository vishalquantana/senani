import Foundation

/// The data the seller signs. Compact and stable: licenseID, tier, issue date,
/// and optional buyer email + seat count. The SIGNED bytes are this struct's
/// CANONICAL JSON (sorted keys, nils omitted, date as integer epoch seconds) so
/// the signer and verifier agree on the exact bytes — JSONEncoder's key order is
/// not guaranteed, so we build the JSON by hand.
public struct LicensePayload: Sendable, Equatable {
    public let licenseID: String
    public let tier: LicenseTier
    public let issued: Date
    public let buyerEmail: String?
    public let seats: Int?

    public init(licenseID: String, tier: LicenseTier, issued: Date,
                buyerEmail: String? = nil, seats: Int? = nil) {
        self.licenseID = licenseID
        self.tier = tier
        self.issued = issued
        self.buyerEmail = buyerEmail
        self.seats = seats
    }

    enum CodingError: Error { case malformed }

    /// Canonical signed bytes: a hand-built JSON object with keys in sorted order,
    /// optionals omitted when nil, `issued` as integer epoch seconds. Deterministic.
    public func canonicalBytes() throws -> Data {
        // String fields are JSON-escaped; our inputs are simple, but escape anyway
        // so an email/id with a quote can't break the bytes (or signature) silently.
        func esc(_ s: String) -> String {
            var out = ""
            for ch in s.unicodeScalars {
                switch ch {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:   out.unicodeScalars.append(ch)
                }
            }
            return out
        }
        // Build (key, jsonValue) pairs, then sort by key for determinism.
        var fields: [(String, String)] = [
            ("issued", String(Int(issued.timeIntervalSince1970.rounded()))),
            ("licenseID", "\"\(esc(licenseID))\""),
            ("tier", "\"\(esc(tier.rawValue))\""),
        ]
        if let buyerEmail { fields.append(("buyerEmail", "\"\(esc(buyerEmail))\"")) }
        if let seats { fields.append(("seats", String(seats))) }
        fields.sort { $0.0 < $1.0 }
        let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
        return Data("{\(body)}".utf8)
    }

    /// Parse canonical (or any equivalent) JSON bytes back into a payload.
    public init(canonicalBytes data: Data) throws {
        guard
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let licenseID = obj["licenseID"] as? String,
            let tierRaw = obj["tier"] as? String,
            let tier = LicenseTier(rawValue: tierRaw),
            let issuedSeconds = obj["issued"] as? NSNumber
        else { throw CodingError.malformed }
        self.licenseID = licenseID
        self.tier = tier
        self.issued = Date(timeIntervalSince1970: issuedSeconds.doubleValue)
        self.buyerEmail = obj["buyerEmail"] as? String
        if let seats = obj["seats"] as? NSNumber { self.seats = seats.intValue } else { self.seats = nil }
    }
}
