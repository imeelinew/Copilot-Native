import Foundation
import Observation
import SwiftData

enum LibraryError: LocalizedError {
    case emptyQuestion
    case emptyAnswer
    case missingItem

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: "请输入问题"
        case .emptyAnswer: "请输入答案"
        case .missingItem: "这条问答已不存在"
        }
    }
}

@MainActor
@Observable
final class QuestionLibrary {
    private let context: ModelContext
    @ObservationIgnored private var itemsByID: [UUID: QuestionAnswer] = [:]
    @ObservationIgnored
    private var index = QuestionSearchIndex([])
    private(set) var items: [QuestionAnswer] = []
    private(set) var revision = 0

    init(container: ModelContainer) throws {
        context = ModelContext(container)
        try reload()
    }

    func search(_ query: String) -> [QuestionAnswer] {
        index.search(query).compactMap { itemsByID[$0] }
    }

    func item(id: UUID) -> QuestionAnswer? {
        items.first { $0.id == id }
    }

    @discardableResult
    func add(question: String, answer: String) throws -> QuestionAnswer {
        let fields = try validated(question: question, answer: answer)
        let item = QuestionAnswer(question: fields.question, answer: fields.answer)
        context.insert(item)
        do {
            try context.save()
            try reload()
            return item
        } catch {
            context.rollback()
            throw error
        }
    }

    func update(id: UUID, question: String, answer: String) throws {
        let fields = try validated(question: question, answer: answer)
        guard let item = item(id: id) else { throw LibraryError.missingItem }
        item.question = fields.question
        item.answer = fields.answer
        item.updatedAt = .now
        do {
            try context.save()
            try reload()
        } catch {
            context.rollback()
            throw error
        }
    }

    func delete(id: UUID) throws {
        guard let item = item(id: id) else { throw LibraryError.missingItem }
        context.delete(item)
        do {
            try context.save()
            try reload()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func reload() throws {
        let descriptor = FetchDescriptor<QuestionAnswer>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        items = try context.fetch(descriptor)
        itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        index = QuestionSearchIndex(items.map {
            QuestionSnapshot(id: $0.id, question: $0.question, answer: $0.answer, updatedAt: $0.updatedAt)
        })
        revision &+= 1
    }

    private func validated(question: String, answer: String) throws -> (question: String, answer: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw LibraryError.emptyQuestion }
        guard !answer.isEmpty else { throw LibraryError.emptyAnswer }
        return (question, answer)
    }
}
