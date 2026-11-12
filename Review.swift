import Foundation

struct ReviewItem: Codable, Identifiable {
    enum Kind: String, Codable {
        case decision, action
        var label: String { self == .decision ? "Decision" : "Action" }
    }

    var id: String { "\(kind.rawValue)-\(line.id)" }
    let kind: Kind
    let line: Line
    var status: Status = .suggested
    var due: Date?

    enum Status: String, Codable { case suggested, kept, done, dismissed }

    static func suggestions(in lines: [Line]) -> [ReviewItem] {
        var results: [ReviewItem] = []
        for line in lines {
            let text = line.text.replacingOccurrences(of: "’", with: "'")
            if text.range(of: #"\b(we (agreed|decided|approved)|the decision is|we've (agreed|decided))\b"#,
                          options: [.caseInsensitive, .regularExpression]) != nil {
                results.append(ReviewItem(kind: .decision, line: line))
            }
            if text.range(of: #"\b(action item|follow up|follow-up|I'll|I will|we'll|we will|I can take)\b"#,
                          options: [.caseInsensitive, .regularExpression]) != nil {
                results.append(ReviewItem(kind: .action, line: line))
            }
        }
        return Array(results.prefix(24))
    }
}

extension Meeting {
    var reviewItems: [ReviewItem] {
        var saved = review ?? []
        let ids = Set(saved.map(\.id))
        saved += ReviewItem.suggestions(in: transcript ?? []).filter { !ids.contains($0.id) }
        return saved.sorted { $0.line.time < $1.line.time }
    }
}


// Local extractive search keeps answers linked to their original transcript.
enum TranscriptInsights {
    static let common: Set<String> = ["about", "after", "again", "also", "been", "before", "being", "could", "from", "have", "into", "just", "like", "more", "other", "some", "than", "that", "their", "there", "these", "they", "this", "those", "what", "when", "where", "which", "will", "with", "would", "your", "them", "then", "were", "said", "here", "because", "does", "much", "really", "want", "going"]
    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 4 && !common.contains($0) }
    }
    static func topics(_ lines: [Line]) -> [String] {
        var counts: [String: Int] = [:]
        for line in lines { for word in Set(words(line.text)) { counts[word, default: 0] += 1 } }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(12).map(\.key)
    }
    static func ranked(_ lines: [Line], terms: Set<String>) -> [Line] {
        var scored: [(line: Line, score: Int)] = []
        for line in lines {
            let score = Set(words(line.text)).intersection(terms).count
            if score > 0 { scored.append((line, score)) }
        }
        scored.sort { a, b in a.score == b.score ? a.line.time < b.line.time : a.score > b.score }
        return scored.map { $0.line }
    }
    static func matches(_ question: String, lines: [Line]) -> [Line] {
        Array(ranked(lines, terms: Set(words(question))).prefix(5))
    }
    static func summary(_ lines: [Line]) -> [Line] {
        Array(ranked(lines, terms: Set(topics(lines).prefix(6))).prefix(3)).sorted { $0.time < $1.time }
    }
}
