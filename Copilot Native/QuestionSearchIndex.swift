import Foundation

struct QuestionSnapshot: Equatable, Sendable {
    let id: UUID
    let question: String
    let answer: String
    let updatedAt: Date
}

struct QuestionSearchIndex {
    private struct PreparedText {
        let normalized: String
        let pinyin: String
        let collapsedPinyin: String
        let initials: String

        init(_ text: String) {
            normalized = Self.normalize(text)
            let latin = (normalized as NSString).applyingTransform(.toLatin, reverse: false) ?? normalized
            pinyin = Self.normalize((latin as NSString).applyingTransform(.stripDiacritics, reverse: false) ?? latin)
            collapsedPinyin = Self.collapse(pinyin)
            initials = pinyin.split { !$0.isLetter && !$0.isNumber }
                .compactMap(\.first).map(String.init).joined()
        }

        static func normalize(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_CN"))
                .lowercased()
        }

        static func collapse(_ text: String) -> String {
            text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
                .map(String.init).joined()
        }

        func score(for query: String, collapsedQuery: String) -> Int? {
            guard !normalized.isEmpty else { return nil }
            if normalized == query { return 0 }
            if normalized.hasPrefix(query) { return 1 }
            if normalized.contains(query) { return 2 }
            guard !collapsedQuery.isEmpty else { return nil }
            if collapsedPinyin == collapsedQuery { return 3 }
            if collapsedPinyin.hasPrefix(collapsedQuery) { return 4 }
            if collapsedPinyin.contains(collapsedQuery) { return 5 }
            if initials.hasPrefix(collapsedQuery) { return 6 }
            if initials.contains(collapsedQuery) { return 7 }
            return nil
        }
    }

    private struct IndexedItem {
        let snapshot: QuestionSnapshot
        let question: PreparedText
        let answer: PreparedText
    }

    private let items: [IndexedItem]

    init(_ snapshots: [QuestionSnapshot]) {
        items = snapshots.map { snapshot in
            IndexedItem(snapshot: snapshot, question: PreparedText(snapshot.question), answer: PreparedText(snapshot.answer))
        }
    }

    func search(_ rawQuery: String) -> [UUID] {
        let query = PreparedText.normalize(rawQuery)
        guard !query.isEmpty else {
            return items.sorted { $0.snapshot.updatedAt > $1.snapshot.updatedAt }.map(\.snapshot.id)
        }
        let collapsedQuery = PreparedText.collapse(query)
        return items.compactMap { item -> (UUID, Int, Date)? in
            if let score = item.question.score(for: query, collapsedQuery: collapsedQuery) {
                return (item.snapshot.id, score, item.snapshot.updatedAt)
            }
            if let score = item.answer.score(for: query, collapsedQuery: collapsedQuery) {
                return (item.snapshot.id, 100 + score, item.snapshot.updatedAt)
            }
            return nil
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.2 > rhs.2 : lhs.1 < rhs.1
        }
        .map(\.0)
    }
}
