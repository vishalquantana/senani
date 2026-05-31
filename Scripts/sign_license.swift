#!/usr/bin/env swift
// OFFLINE seller-side license tool. Run ONLY on a machine that is OFF the network
// when handling the private key. NEVER commit the private key. Usage:
//
//   swift Scripts/sign_license.swift gen-key [out-private-key-path]
//       → generates an Ed25519 keypair. Prints the PUBLIC key base64 to paste into
//         Sources/SenaniLicensing/EmbeddedPublicKey.swift. Writes the PRIVATE key
//         base64 to the given path (default ./senani-license-private.key) — KEEP OFFLINE.
//
//   swift Scripts/sign_license.swift sign <private-key-path> <licenseID> <core|pro> [email] [seats]
//       → prints a XXXXX-XXXXX-... license key to hand to the buyer.
//
// The byte layout MUST match LicenseVerifier: tag(0x01) ‖ canonicalPayloadJSON ‖ sig(64),
// base32-grouped (Crockford). This file intentionally re-implements the codec so the
// signer never imports the app package.

import Foundation
import CryptoKit

let tag: UInt8 = 0x01
let crockford = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

func base32Group(_ data: Data) -> String {
    var bits = 0, value = 0
    var symbols = ""
    for byte in data {
        value = (value << 8) | Int(byte); bits += 8
        while bits >= 5 { bits -= 5; symbols.append(crockford[(value >> bits) & 0x1F]) }
    }
    if bits > 0 { symbols.append(crockford[(value << (5 - bits)) & 0x1F]) }
    var grouped = ""
    for (i, ch) in symbols.enumerated() {
        if i > 0 && i % 5 == 0 { grouped.append("-") }
        grouped.append(ch)
    }
    return grouped
}

func canonicalPayload(licenseID: String, tier: String, issued: Int,
                      email: String?, seats: Int?) -> Data {
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    var fields: [(String, String)] = [
        ("issued", String(issued)),
        ("licenseID", "\"\(esc(licenseID))\""),
        ("tier", "\"\(esc(tier))\""),
    ]
    if let email { fields.append(("buyerEmail", "\"\(esc(email))\"")) }
    if let seats { fields.append(("seats", String(seats))) }
    fields.sort { $0.0 < $1.0 }
    let body = fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",")
    return Data("{\(body)}".utf8)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    FileHandle.standardError.write(Data("usage: gen-key | sign\n".utf8)); exit(2)
}

switch cmd {
case "gen-key":
    let priv = Curve25519.Signing.PrivateKey()
    let pubB64 = priv.publicKey.rawRepresentation.base64EncodedString()
    let privB64 = priv.rawRepresentation.base64EncodedString()
    let outPath = args.count > 1 ? args[1] : "./senani-license-private.key"
    try privB64.write(toFile: outPath, atomically: true, encoding: .utf8)
    print("PUBLIC KEY (paste into EmbeddedPublicKey.base64):")
    print(pubB64)
    print("PRIVATE KEY written to \(outPath) — KEEP OFFLINE, NEVER COMMIT.")

case "sign":
    guard args.count >= 4 else {
        FileHandle.standardError.write(Data("usage: sign <priv-path> <id> <core|pro> [email] [seats]\n".utf8)); exit(2)
    }
    let privPath = args[1], licenseID = args[2], tier = args[3]
    guard tier == "core" || tier == "pro" else {
        FileHandle.standardError.write(Data("tier must be core or pro\n".utf8)); exit(2)
    }
    let email = args.count > 4 && !args[4].isEmpty ? args[4] : nil
    let seats = args.count > 5 ? Int(args[5]) : nil
    let privB64 = try String(contentsOfFile: privPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let privData = Data(base64Encoded: privB64) else {
        FileHandle.standardError.write(Data("bad private key file\n".utf8)); exit(1)
    }
    let priv = try Curve25519.Signing.PrivateKey(rawRepresentation: privData)
    let issued = Int(Date().timeIntervalSince1970)
    let payload = canonicalPayload(licenseID: licenseID, tier: tier,
                                   issued: issued, email: email, seats: seats)
    var signed = Data([tag]); signed.append(payload)
    let sig = try priv.signature(for: signed)
    var keyBytes = signed; keyBytes.append(sig)
    print(base32Group(keyBytes))

default:
    FileHandle.standardError.write(Data("unknown command: \(cmd)\n".utf8)); exit(2)
}
