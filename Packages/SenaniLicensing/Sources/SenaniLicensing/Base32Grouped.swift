import Foundation

/// Crockford base32 (alphabet excludes I, L, O, U) with `XXXXX-XXXXX` grouping.
/// Encoding is uppercase/grouped; decoding is case-insensitive and ignores dashes
/// and surrounding whitespace. Pure — no crypto, no Foundation Data(base64:).
public enum Base32Grouped {
    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")  // 32 symbols, Crockford
    static let groupSize = 5

    enum DecodeError: Error { case illegalCharacter, truncated }

    public static func encode(_ data: Data) -> String {
        var bits = 0
        var value = 0
        var symbols = ""
        for byte in data {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                bits -= 5
                symbols.append(alphabet[(value >> bits) & 0x1F])
            }
        }
        if bits > 0 {
            symbols.append(alphabet[(value << (5 - bits)) & 0x1F])
        }
        // Group into 5-char blocks separated by '-'.
        var grouped = ""
        for (i, ch) in symbols.enumerated() {
            if i > 0 && i % groupSize == 0 { grouped.append("-") }
            grouped.append(ch)
        }
        return grouped
    }

    public static func decode(_ string: String) throws -> Data {
        // Build reverse lookup once; treat lowercase as uppercase.
        let cleaned = string.uppercased()
            .filter { $0 != "-" && !$0.isWhitespace }
        var lookup: [Character: Int] = [:]
        for (i, ch) in alphabet.enumerated() { lookup[ch] = i }

        var bits = 0
        var value = 0
        var out = Data()
        for ch in cleaned {
            guard let v = lookup[ch] else { throw DecodeError.illegalCharacter }
            value = (value << 5) | v
            bits += 5
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((value >> bits) & 0xFF))
            }
        }
        return out
    }
}
