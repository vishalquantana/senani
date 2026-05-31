import Foundation

public enum GmailOAuthConfigError: Error, Equatable {
    case missingClientID
}

/// Resolves the Google OAuth desktop client ID and pins the Gmail consent scopes.
///
/// The client ID is supplied outside source control. Resolution order is:
/// `SENANI_GMAIL_CLIENT_ID`, then Info.plist key `SenaniGmailClientID`, then
/// `~/Library/Application Support/Senani/oauth.plist` with key `SenaniGmailClientID`.
/// The desktop PKCE flow uses no client secret.
public enum GmailOAuthConfig {
    public static let scopes: [String] = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.modify",
        "https://www.googleapis.com/auth/gmail.compose",
        "openid",
        "email",
    ]

    public static func clientID(
        environment: [String: String],
        infoPlistValue: String?,
        fileValue: () -> String?
    ) throws -> String {
        if let value = nonEmpty(environment["SENANI_GMAIL_CLIENT_ID"]) {
            return value
        }
        if let value = nonEmpty(infoPlistValue) {
            return value
        }
        if let value = nonEmpty(fileValue()) {
            return value
        }
        throw GmailOAuthConfigError.missingClientID
    }

    public static func clientID() throws -> String {
        try clientID(
            environment: ProcessInfo.processInfo.environment,
            infoPlistValue: Bundle.main.object(forInfoDictionaryKey: "SenaniGmailClientID") as? String,
            fileValue: { readConfigFileClientID() }
        )
    }

    private static func readConfigFileClientID() -> String? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let url = appSupport.appendingPathComponent("Senani/oauth.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(
                from: data,
                format: nil
              ) as? [String: Any] else {
            return nil
        }
        return plist["SenaniGmailClientID"] as? String
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
