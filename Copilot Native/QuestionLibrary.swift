import Foundation
import Observation
import SwiftData

enum LibraryScope: Hashable {
    case package(UUID)
    case capsule(UUID)
}

enum LibraryError: LocalizedError {
    case emptyQuestion
    case emptyAnswer
    case emptyName
    case missingItem
    case missingPackage
    case missingCapsule
    case lastPackage
    case lastCapsule
    case invalidTransferFile
    case wrongTransferKind(expected: String)
    case unsupportedTransferVersion

    var errorDescription: String? {
        switch self {
        case .emptyQuestion: "请输入问题"
        case .emptyAnswer: "请输入答案"
        case .emptyName: "名称不能为空"
        case .missingItem: "这条问答已不存在"
        case .missingPackage: "这个 Package 已不存在"
        case .missingCapsule: "这个 Capsule 已不存在"
        case .lastPackage: "至少需要保留一个 Package"
        case .lastCapsule: "每个 Package 至少需要保留一个 Capsule"
        case .invalidTransferFile: "无法读取这个 Copilot Native 文件"
        case .wrongTransferKind(let expected): "请选择 \(expected) 导出文件"
        case .unsupportedTransferVersion: "这个文件来自不受支持的版本"
        }
    }
}

@MainActor
@Observable
final class QuestionLibrary {
    private let context: ModelContext
    @ObservationIgnored private var itemsByID: [UUID: QuestionAnswer] = [:]
    @ObservationIgnored private var packagesByID: [UUID: InterviewPackage] = [:]
    @ObservationIgnored private var capsulesByID: [UUID: InterviewCapsule] = [:]
    @ObservationIgnored private var index = QuestionSearchIndex([])

    private(set) var packages: [InterviewPackage] = []
    private(set) var capsules: [InterviewCapsule] = []
    private(set) var items: [QuestionAnswer] = []
    private(set) var revision = 0

    init(container: ModelContainer) throws {
        context = ModelContext(container)
        try reload()
    }

    func search(_ query: String, in scope: LibraryScope?) -> [QuestionAnswer] {
        index.search(query)
            .compactMap { itemsByID[$0] }
            .filter { item in scopeContains(item, scope: scope) }
    }

    func item(id: UUID) -> QuestionAnswer? { itemsByID[id] }
    func package(id: UUID) -> InterviewPackage? { packagesByID[id] }
    func capsule(id: UUID) -> InterviewCapsule? { capsulesByID[id] }

    func capsules(in packageID: UUID) -> [InterviewCapsule] {
        capsules.filter { $0.package?.id == packageID }
    }

    func questionCount(in scope: LibraryScope) -> Int {
        items.lazy.filter { self.scopeContains($0, scope: scope) }.count
    }

    func contains(_ scope: LibraryScope) -> Bool {
        switch scope {
        case .package(let id): packagesByID[id] != nil
        case .capsule(let id): capsulesByID[id] != nil
        }
    }

    func title(for scope: LibraryScope?) -> String {
        switch scope {
        case .package(let id): package(id: id)?.name ?? "Package"
        case .capsule(let id): capsule(id: id)?.name ?? "Capsule"
        case nil: "题库"
        }
    }

    func packageID(for scope: LibraryScope?) -> UUID? {
        switch scope {
        case .package(let id): id
        case .capsule(let id): capsule(id: id)?.package?.id
        case nil: packages.first?.id
        }
    }

    func preferredCapsuleID(for scope: LibraryScope?) -> UUID? {
        switch scope {
        case .capsule(let id): capsulesByID[id] == nil ? nil : id
        case .package(let id): capsules(in: id).first?.id
        case nil: capsules.first?.id
        }
    }

    @discardableResult
    func addPackage(name: String) throws -> InterviewPackage {
        let package = InterviewPackage(name: try validatedName(name))
        let capsule = InterviewCapsule(name: "默认 Capsule", package: package)
        context.insert(package)
        context.insert(capsule)
        try saveAndReload()
        return package
    }

    @discardableResult
    func addCapsule(name: String, to packageID: UUID) throws -> InterviewCapsule {
        guard let package = package(id: packageID) else { throw LibraryError.missingPackage }
        let capsule = InterviewCapsule(name: try validatedName(name), package: package)
        context.insert(capsule)
        package.updatedAt = .now
        try saveAndReload()
        return capsule
    }

    func renamePackage(id: UUID, name: String) throws {
        guard let package = package(id: id) else { throw LibraryError.missingPackage }
        package.name = try validatedName(name)
        package.updatedAt = .now
        try saveAndReload()
    }

    func renameCapsule(id: UUID, name: String) throws {
        guard let capsule = capsule(id: id) else { throw LibraryError.missingCapsule }
        capsule.name = try validatedName(name)
        capsule.updatedAt = .now
        capsule.package?.updatedAt = .now
        try saveAndReload()
    }

    func deletePackage(id: UUID) throws {
        guard packages.count > 1 else { throw LibraryError.lastPackage }
        guard let package = package(id: id) else { throw LibraryError.missingPackage }
        context.delete(package)
        try saveAndReload()
    }

    func deleteCapsule(id: UUID) throws {
        guard let capsule = capsule(id: id), let packageID = capsule.package?.id else {
            throw LibraryError.missingCapsule
        }
        guard capsules(in: packageID).count > 1 else { throw LibraryError.lastCapsule }
        context.delete(capsule)
        try saveAndReload()
    }

    @discardableResult
    func add(question: String, answer: String, capsuleID: UUID) throws -> QuestionAnswer {
        let fields = try validated(question: question, answer: answer)
        guard let capsule = capsule(id: capsuleID) else { throw LibraryError.missingCapsule }
        let item = QuestionAnswer(question: fields.question, answer: fields.answer, capsule: capsule)
        context.insert(item)
        capsule.updatedAt = .now
        capsule.package?.updatedAt = .now
        try saveAndReload()
        return item
    }

    func update(id: UUID, question: String, answer: String, capsuleID: UUID) throws {
        let fields = try validated(question: question, answer: answer)
        guard let item = item(id: id) else { throw LibraryError.missingItem }
        guard let capsule = capsule(id: capsuleID) else { throw LibraryError.missingCapsule }
        item.question = fields.question
        item.answer = fields.answer
        item.capsule = capsule
        item.updatedAt = .now
        capsule.updatedAt = .now
        capsule.package?.updatedAt = .now
        try saveAndReload()
    }

    func move(id: UUID, to capsuleID: UUID) throws {
        guard let item = item(id: id) else { throw LibraryError.missingItem }
        guard let capsule = capsule(id: capsuleID) else { throw LibraryError.missingCapsule }
        guard item.capsule?.id != capsuleID else { return }

        let previousCapsule = item.capsule
        item.capsule = capsule
        item.updatedAt = .now
        previousCapsule?.updatedAt = .now
        previousCapsule?.package?.updatedAt = .now
        capsule.updatedAt = .now
        capsule.package?.updatedAt = .now
        try saveAndReload()
    }

    func delete(id: UUID) throws {
        guard let item = item(id: id) else { throw LibraryError.missingItem }
        let capsule = item.capsule
        context.delete(item)
        capsule?.updatedAt = .now
        capsule?.package?.updatedAt = .now
        try saveAndReload()
    }

    func exportPackage(id: UUID) throws -> Data {
        guard let package = package(id: id) else { throw LibraryError.missingPackage }
        let payload = PackageTransfer(
            name: package.name,
            capsules: capsules(in: id).map(makeCapsuleTransfer)
        )
        return try encode(TransferDocument(version: 1, kind: .package, package: payload, capsule: nil))
    }

    func exportCapsule(id: UUID) throws -> Data {
        guard let capsule = capsule(id: id) else { throw LibraryError.missingCapsule }
        return try encode(
            TransferDocument(version: 1, kind: .capsule, package: nil, capsule: makeCapsuleTransfer(capsule))
        )
    }

    @discardableResult
    func importPackage(from data: Data) throws -> InterviewPackage {
        let document = try decode(data)
        guard document.kind == .package, let payload = document.package else {
            throw LibraryError.wrongTransferKind(expected: "Package")
        }
        let payloads = payload.capsules.isEmpty
            ? [CapsuleTransfer(name: "默认 Capsule", questions: [])]
            : payload.capsules
        let packageName = try validatedName(payload.name)
        for capsulePayload in payloads {
            try validate(capsulePayload)
        }

        let package = InterviewPackage(name: packageName)
        context.insert(package)
        for capsulePayload in payloads {
            try insert(capsulePayload, into: package)
        }
        try saveAndReload()
        return package
    }

    @discardableResult
    func importCapsule(from data: Data, into packageID: UUID) throws -> InterviewCapsule {
        guard let package = package(id: packageID) else { throw LibraryError.missingPackage }
        let document = try decode(data)
        guard document.kind == .capsule, let payload = document.capsule else {
            throw LibraryError.wrongTransferKind(expected: "Capsule")
        }
        try validate(payload)
        let capsule = try insert(payload, into: package)
        try saveAndReload()
        return capsule
    }

    private func scopeContains(_ item: QuestionAnswer, scope: LibraryScope?) -> Bool {
        switch scope {
        case .package(let id): item.capsule?.package?.id == id
        case .capsule(let id): item.capsule?.id == id
        case nil: true
        }
    }

    private func saveAndReload() throws {
        do {
            try context.save()
            try reload()
        } catch {
            context.rollback()
            throw error
        }
    }

    private func reload() throws {
        var fetchedPackages = try context.fetch(
            FetchDescriptor<InterviewPackage>(sortBy: [SortDescriptor(\.createdAt)])
        )
        var fetchedCapsules = try context.fetch(
            FetchDescriptor<InterviewCapsule>(sortBy: [SortDescriptor(\.createdAt)])
        )
        var fetchedItems = try context.fetch(
            FetchDescriptor<QuestionAnswer>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        )

        var changed = false
        if fetchedPackages.isEmpty {
            let package = InterviewPackage(name: "我的 Package")
            let capsule = InterviewCapsule(name: "默认 Capsule", package: package)
            context.insert(package)
            context.insert(capsule)
            fetchedItems.forEach { $0.capsule = capsule }
            changed = true
        } else if fetchedItems.contains(where: { $0.capsule == nil }) {
            let capsule: InterviewCapsule
            if let existing = fetchedCapsules.first {
                capsule = existing
            } else {
                capsule = InterviewCapsule(name: "默认 Capsule", package: fetchedPackages[0])
                context.insert(capsule)
            }
            fetchedItems.filter { $0.capsule == nil }.forEach { $0.capsule = capsule }
            changed = true
        }

        if changed {
            try context.save()
            fetchedPackages = try context.fetch(
                FetchDescriptor<InterviewPackage>(sortBy: [SortDescriptor(\.createdAt)])
            )
            fetchedCapsules = try context.fetch(
                FetchDescriptor<InterviewCapsule>(sortBy: [SortDescriptor(\.createdAt)])
            )
            fetchedItems = try context.fetch(
                FetchDescriptor<QuestionAnswer>(sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
            )
        }

        packages = fetchedPackages
        capsules = fetchedCapsules
        items = fetchedItems
        packagesByID = Dictionary(uniqueKeysWithValues: packages.map { ($0.id, $0) })
        capsulesByID = Dictionary(uniqueKeysWithValues: capsules.map { ($0.id, $0) })
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

    private func validatedName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LibraryError.emptyName }
        return name
    }

    private func makeCapsuleTransfer(_ capsule: InterviewCapsule) -> CapsuleTransfer {
        CapsuleTransfer(
            name: capsule.name,
            questions: items
                .filter { $0.capsule?.id == capsule.id }
                .map {
                    QuestionTransfer(
                        question: $0.question,
                        answer: $0.answer,
                        createdAt: $0.createdAt,
                        updatedAt: $0.updatedAt
                    )
                }
        )
    }

    private func validate(_ payload: CapsuleTransfer) throws {
        _ = try validatedName(payload.name)
        for question in payload.questions {
            _ = try validated(question: question.question, answer: question.answer)
        }
    }

    @discardableResult
    private func insert(_ payload: CapsuleTransfer, into package: InterviewPackage) throws -> InterviewCapsule {
        let capsule = InterviewCapsule(name: try validatedName(payload.name), package: package)
        context.insert(capsule)
        for question in payload.questions {
            let fields = try validated(question: question.question, answer: question.answer)
            context.insert(
                QuestionAnswer(
                    question: fields.question,
                    answer: fields.answer,
                    capsule: capsule,
                    createdAt: question.createdAt,
                    updatedAt: question.updatedAt
                )
            )
        }
        package.updatedAt = .now
        return capsule
    }

    private func encode(_ document: TransferDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }

    private func decode(_ data: Data) throws -> TransferDocument {
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(TransferDocument.self, from: data)
            guard document.version == 1 else { throw LibraryError.unsupportedTransferVersion }
            return document
        } catch let error as LibraryError {
            throw error
        } catch {
            throw LibraryError.invalidTransferFile
        }
    }
}

private enum TransferKind: String, Codable {
    case package
    case capsule
}

private struct TransferDocument: Codable {
    let version: Int
    let kind: TransferKind
    let package: PackageTransfer?
    let capsule: CapsuleTransfer?
}

private struct PackageTransfer: Codable {
    let name: String
    let capsules: [CapsuleTransfer]
}

private struct CapsuleTransfer: Codable {
    let name: String
    let questions: [QuestionTransfer]
}

private struct QuestionTransfer: Codable {
    let question: String
    let answer: String
    let createdAt: Date
    let updatedAt: Date
}
