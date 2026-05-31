# License-Key Custody (OFFLINE)

Senani license keys are signed offline with Ed25519. The app embeds only the PUBLIC
key and verifies signatures with no network, no accounts, no telemetry.

## Key custody — non-negotiable
- The PRIVATE key is generated and used ONLY on a seller machine that is OFF the
  network when the key file is present. It is NEVER committed, NEVER in the app
  bundle, NEVER in this repo, and NEVER emailed.
- Store the private-key file (`senani-license-private.key`, base64 of the 32-byte
  raw key) in an encrypted, backed-up vault (e.g. a password manager / offline
  encrypted volume). Losing it means you can no longer sign keys (rotate — below).
- The PUBLIC key is safe to embed in source: it can only VERIFY, never sign.

## Generate the keypair (once)
    swift Scripts/sign_license.swift gen-key ~/secure/senani-license-private.key
Paste the printed PUBLIC KEY base64 into
`Packages/SenaniLicensing/Sources/SenaniLicensing/EmbeddedPublicKey.swift` (the
`base64` constant), commit THAT (public) change, and store the private key offline.

## Sign a license for a buyer
    swift Scripts/sign_license.swift sign ~/secure/senani-license-private.key \
        LIC-2026-0007 pro buyer@example.com 1
Hand the printed `XXXXX-XXXXX-...` key to the buyer (with their purchase receipt).

## Rotation
If the private key is ever exposed: generate a new keypair, embed the new public key
in a new app release, and re-issue keys to existing buyers. Old keys verify only
against the old public key, so a rotated build invalidates leaked keys. There is no
revocation list (that would need a server, which the trust model forbids) — rotation
via an app update is the offline-safe mechanism.

## What the app does
On launch / activation the app reads the stored key from the Keychain and calls
`LicenseVerifier.senani().verify(key)`. `.valid(tier)` gates features per `Feature`.
No network call is ever made for licensing.
