import Foundation

public enum MIMEBuilder {
    public static func message(
        from: String,
        to: [String],
        subject: String,
        body: String,
        inReplyTo: String? = nil,
        references: String? = nil
    ) -> String {
        var lines = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
            "Subject: \(subject)",
            "MIME-Version: 1.0",
            "Content-Type: text/plain; charset=UTF-8",
        ]
        if let inReplyTo {
            lines.append("In-Reply-To: \(inReplyTo)")
        }
        if let references {
            lines.append("References: \(references)")
        }
        lines.append("")
        lines.append(body)
        return lines.joined(separator: "\r\n")
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
