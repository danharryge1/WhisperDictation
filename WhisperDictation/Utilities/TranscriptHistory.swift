import Foundation

enum TranscriptHistory {
    static let maxCount = 5

    struct Entry: Codable, Equatable, Identifiable {
        var id: UUID
        var text: String
        var date: Date
    }

    /// Newest first. Consecutive identical text is ignored so a retry does not
    /// eat a history slot.
    static func recording(_ text: String, into items: [Entry]) -> [Entry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        if items.first?.text == trimmed { return items }
        var next = items
        next.insert(Entry(id: UUID(), text: trimmed, date: Date()), at: 0)
        return Array(next.prefix(maxCount))
    }
}
