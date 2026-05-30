public enum Chunker {
    public static func chunks(text: String, maxWords: Int = 120, overlap: Int = 20) -> [String] {
        let words = text.split { $0.isWhitespace }.map(String.init)
        guard !words.isEmpty else { return [] }
        var output: [String] = []
        var start = 0
        while start < words.count {
            let end = min(words.count, start + maxWords)
            output.append(words[start..<end].joined(separator: " "))
            if end == words.count { break }
            start = max(0, end - overlap)
        }
        return output
    }
}
