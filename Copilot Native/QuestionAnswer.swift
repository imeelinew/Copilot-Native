import Foundation
import SwiftData

@Model
final class QuestionAnswer {
    @Attribute(.unique) var id: UUID
    var question: String
    var answer: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
