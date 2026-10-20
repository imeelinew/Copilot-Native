import Foundation

struct QuestionSnapshot: Equatable, Sendable {
    let id: UUID
    let question: String
    let answer: String
    let updatedAt: Date
}

struct QuestionSearchIndex {
    /// Only match the question title, never incidental words in a saved answer.
    /// Ambiguous saved versions require a preferred library scope or a manual choice.
    func interviewMatch(_ query: String, allowedIDs: Set<UUID>? = nil) -> QuestionSnapshot? {
        let key = Self.interviewKey(query)
        guard !key.isEmpty else { return nil }
        let matches = items.filter {
            (allowedIDs == nil || allowedIDs!.contains($0.snapshot.id)) && Self.interviewKey($0.snapshot.question) == key
        }.map(\.snapshot).sorted { $0.updatedAt > $1.updatedAt }
        guard Set(matches.map(\.answer)).count == 1 else { return nil }
        return matches.first
    }

    static func isIntroductionRequest(_ text: String) -> Bool {
        let value = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        guard value.count <= 65, !value.hasPrefix("我"),
              !["刚才", "提到", "里面", "为什么", "怎么", "修改", "优化", "改成", "英文", "英语", "项目", "不足", "分钟", "秒", "然后", "再说", "以及", "并且", "另外", "我先", "我来", "我叫", "我的名字"].contains(where: value.contains) else { return false }
        return value == "自我介绍" || value.contains("自我介绍") && ["你", "您", "请", "做个", "做一个", "来一个", "来个"].contains(where: value.contains)
            || ["介绍一下自己", "介绍下自己", "介绍一下你自己", "介绍下你自己"].contains(where: value.contains)
    }

    private static func interviewKey(_ text: String) -> String {
        if isIntroductionRequest(text) { return "自我介绍" }
        var value = PreparedText.normalize(text).filter { !$0.isWhitespace && !$0.isPunctuation }
        for prefix in ["面试官您好", "你好", "麻烦你", "麻烦", "请问", "请你", "请", "你能不能", "你能", "能不能"] {
            if value.hasPrefix(prefix) { value.removeFirst(prefix.count) }
        }
        for suffix in ["好吗", "一下吧", "吗", "呢", "吧"] {
            if value.hasSuffix(suffix) { value.removeLast(suffix.count) }
        }
        return value
    }
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
