import Foundation
import SenaniRules

public struct VoiceProfile: Codable, Sendable, Equatable {
    public var scope: String
    public var averageSentenceWords: Double
    public var greeting: String?
    public var signoff: String?
    public var commonPhrases: [String]
    public var emojiRate: Double
    public var perDomain: [String: VoiceProfile]

    public init(
        scope: String,
        averageSentenceWords: Double,
        greeting: String?,
        signoff: String?,
        commonPhrases: [String],
        emojiRate: Double,
        perDomain: [String: VoiceProfile] = [:]
    ) {
        self.scope = scope
        self.averageSentenceWords = averageSentenceWords
        self.greeting = greeting
        self.signoff = signoff
        self.commonPhrases = commonPhrases
        self.emojiRate = emojiRate
        self.perDomain = perDomain
    }
}

public enum VoiceProfileBuilder {
    public static func build(from sent: [Message]) -> VoiceProfile {
        let sent = sent.filter(\.isFromUser)
        let global = buildFlat(scope: "global", from: sent)
        var domains: [String: VoiceProfile] = [:]
        for recipientDomain in Set(sent.flatMap { $0.to.compactMap(domain(of:)) }) {
            let messages = sent.filter { $0.to.contains { domain(of: $0) == recipientDomain } }
            domains[recipientDomain] = buildFlat(scope: "domain:\(recipientDomain)", from: messages)
        }
        var output = global
        output.perDomain = domains
        return output
    }

    private static func buildFlat(scope: String, from messages: [Message]) -> VoiceProfile {
        let bodies = messages.map(\.body)
        let words = bodies.flatMap { tokenize($0) }
        let sentences = bodies.flatMap { $0.split(whereSeparator: { ".!?".contains($0) }) }
        let average = sentences.isEmpty ? 0 : Double(words.count) / Double(sentences.count)
        let firstLines = bodies.compactMap { $0.split(separator: "\n").first.map(String.init) }
        let lastLines = bodies.compactMap { $0.split(separator: "\n").last.map(String.init) }
        return VoiceProfile(
            scope: scope,
            averageSentenceWords: average,
            greeting: mostCommon(firstLines),
            signoff: mostCommon(lastLines),
            commonPhrases: commonBigrams(words),
            emojiRate: bodies.isEmpty ? 0 : Double(bodies.joined().filter { $0.unicodeScalars.contains { $0.properties.isEmojiPresentation } }.count) / Double(max(1, words.count))
        )
    }

    static func tokenize(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private static func commonBigrams(_ words: [String]) -> [String] {
        guard words.count >= 2 else { return [] }
        var counts: [String: Int] = [:]
        for index in 0..<(words.count - 1) {
            counts["\(words[index]) \(words[index + 1])", default: 0] += 1
        }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(5).map(\.key)
    }

    private static func mostCommon(_ values: [String]) -> String? {
        values.reduce(into: [:]) { (counts: inout [String: Int], value) in counts[value, default: 0] += 1 }
            .max { $0.value < $1.value }?.key
    }

    static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        return String(email[email.index(after: at)...]).lowercased()
    }
}
