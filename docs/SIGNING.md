# Code Signing & Notarization Runbook

This document describes how to package, sign, and notarize the Senani macOS application for distribution.

## Prerequisites

1.  **Apple Developer Program Membership**: Required for Developer ID Application certificates.
2.  **Developer ID Application Certificate**:
    *   Create at [developer.apple.com](https://developer.apple.com/account/resources/certificates/list).
    *   Download and install into your **login** keychain.
    *   The private key must be present in the keychain.
3.  **App Store Connect API Key**:
    *   Create at [appstoreconnect.apple.com](https://appstoreconnect.apple.com/access/integrations/api).
    *   Role: **Developer** (or Admin).
    *   Note your **Issuer ID** (UUID) and **Key ID** (10 chars).
    *   Download the `.p8` file (note: it can only be downloaded once).

## Local Packaging & Signing

To build a signed and notarized `.app` (and optionally a `.dmg`) on your Mac:

1.  **Export required environment variables**:
    ```bash
    export SENANI_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
    export SENANI_TEAM_ID="TEAMID"
    export SENANI_ASC_ISSUER_ID="69a6de7e-..."
    export SENANI_ASC_KEY_ID="ABCDE12345"
    export SENANI_ASC_KEY_PATH="/path/to/AuthKey_ABCDE12345.p8"
    ```
    *Find your identity string with:* `security find-identity -v -p codesigning`

2.  **Run the script**:
    ```bash
    # Optionally set SENANI_MAKE_DMG=1 to build a .dmg
    SENANI_MAKE_DMG=1 Scripts/package_and_sign.sh 0.1.0 1
    ```

3.  **Verify artifacts**:
    The artifacts will be in the `dist/` directory.

## GitHub Actions Release (CI)

The `.github/workflows/release.yml` workflow runs automatically when a tag matching `v*` is pushed.

### Required Repository Secrets

Set these in **Settings > Secrets and variables > Actions**:

| Secret | Description |
| :--- | :--- |
| `SENANI_SIGN_IDENTITY` | Exact common name of your Developer ID Application cert. |
| `SENANI_TEAM_ID` | Your 10-character Apple Team ID. |
| `SENANI_CERT_P12_BASE64` | Base64 of the Developer ID Application cert+key `.p12`. |
| `SENANI_CERT_P12_PASSWORD` | Password used when exporting that `.p12`. |
| `SENANI_ASC_ISSUER_ID` | App Store Connect API issuer UUID. |
| `SENANI_ASC_KEY_ID` | App Store Connect API key ID. |
| `SENANI_ASC_KEY_BASE64` | Base64 of the `AuthKey_*.p8` file. |

**To produce base64 strings**: `base64 -i file.p12 | pbcopy` (Mac).

## Expected Verification Output

A successful run should end with:

*   `dist/Senani.app: valid on disk`
*   `dist/Senani.app: satisfies its Designated Requirement`
*   `status: Accepted` (from `notarytool`)
*   `The staple and validate action worked!`
*   `dist/Senani.app: accepted / source=Notarized Developer ID`

## Entitlements Rationale

Senani uses a minimal set of entitlements for the Hardened Runtime:

*   `com.apple.security.cs.allow-jit`: Required for **MLX / Metal** JIT compilation of compute kernels.
*   `com.apple.security.network.client`: Required for outbound HTTPS calls to Google (Gmail/Calendar) and Hugging Face.

Senani has **no telemetry**, no sandbox (by design, for local model loading), and no server listener.

## Rotation & Troubleshooting

*   **Cert Expired**: Generate a new Developer ID Application cert, export as `.p12`, and update `SENANI_CERT_P12_BASE64` and `SENANI_SIGN_IDENTITY` secrets.
*   **Key Compromised**: Revoke the ASC API key in App Store Connect, generate a new one, and update the `ASC_KEY_ID` and `ASC_KEY_BASE64` secrets.
*   **Notarization `Invalid`**: Run `xcrun notarytool log <id> --issuer ... --key-id ... --key ...` to see the failure log.
