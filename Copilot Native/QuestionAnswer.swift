import Foundation
import SwiftData

@Model
final class InterviewPackage {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    @Relationship(deleteRule: .cascade, inverse: \InterviewCapsule.package)
    var capsules: [InterviewCapsule]

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        capsules: [InterviewCapsule] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.capsules = capsules
    }
}

@Model
final class InterviewCapsule {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var package: InterviewPackage?
    @Relationship(deleteRule: .cascade, inverse: \QuestionAnswer.capsule)
    var questions: [QuestionAnswer]

    init(
        id: UUID = UUID(),
        name: String,
        package: InterviewPackage? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        questions: [QuestionAnswer] = []
    ) {
        self.id = id
        self.name = name
        self.package = package
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.questions = questions
    }
}

@Model
final class QuestionAnswer {
    @Attribute(.unique) var id: UUID
    var question: String
    var answer: String
    var createdAt: Date
    var updatedAt: Date
    var capsule: InterviewCapsule?

    init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        capsule: InterviewCapsule? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.capsule = capsule
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
