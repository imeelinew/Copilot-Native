import Foundation
import SwiftData
import XCTest
@testable import CopilotNative

final class SearchAndStorageTests: XCTestCase {
    func testEnglishPinyinAndAnswerRanking() {
        let now = Date()
        let questionHit = QuestionSnapshot(
            id: UUID(), question: "Swift 并发是什么？", answer: "使用 actor 保护状态", updatedAt: now
        )
        let answerHit = QuestionSnapshot(
            id: UUID(), question: "如何准备面试？", answer: "复习 Swift concurrency", updatedAt: now.addingTimeInterval(10)
        )
        let index = QuestionSearchIndex([answerHit, questionHit])

        XCTAssertEqual(index.search("SWIFT"), [questionHit.id, answerHit.id])
        XCTAssertEqual(index.search("bingfa"), [questionHit.id])
        XCTAssertEqual(index.search("sbf"), [questionHit.id])
        XCTAssertEqual(index.search("ACTOR"), [questionHit.id])
        XCTAssertTrue(index.search("完全不相关的问题").isEmpty)
        XCTAssertTrue(index.search("!!!").isEmpty)
    }

    @MainActor
    func testQuestionAndAnswerPersistTogether() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("questions.store")
        let id: UUID

        do {
            let container = try ModelContainer(
                for: QuestionAnswer.self,
                configurations: ModelConfiguration(url: database)
            )
            let library = try QuestionLibrary(container: container)
            id = try library.add(question: "什么是 actor？", answer: "**隔离**可变状态").id
            try library.update(id: id, question: "Actor 是什么？", answer: "用于并发隔离")
            XCTAssertEqual(library.search("并发隔离").map(\.id), [id])
        }

        do {
            let container = try ModelContainer(
                for: QuestionAnswer.self,
                configurations: ModelConfiguration(url: database)
            )
            let library = try QuestionLibrary(container: container)
            XCTAssertEqual(library.items.count, 1)
            XCTAssertEqual(library.item(id: id)?.question, "Actor 是什么？")
            XCTAssertEqual(library.item(id: id)?.answer, "用于并发隔离")
            try library.delete(id: id)
            XCTAssertTrue(library.items.isEmpty)
        }
    }

    func testMarkdownBlocksKeepCodeAndLists() {
        let blocks = MarkdownBlocks.parse("# 标题\n\n- 一项\n- 二项\n\n```swift\nlet x = 1\n```")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "标题"),
            .bullet(["一项", "二项"]),
            .code(language: "swift", content: "let x = 1")
        ])
    }

    func testMarkdownTableParsesRowsAlignmentAndEscapedPipes() {
        let markdown = """
        5. 其他变化

        | 变化点 | Vue2 | Vue3 |
        |:---|:---:|---:|
        | 生命周期 | beforeDestroy / destroyed | beforeUnmount / unmounted |
        | filter | 支持 | 移除（用计算属性/方法替代） |
        | 事件总线 | $on\\|$off\\|$once | 移除，需用 mitt 等第三方库 |
        """
        let blocks = MarkdownBlocks.parse(markdown)
        XCTAssertEqual(blocks, [
            .numbered(["其他变化"]),
            .table(MarkdownTable(
                headers: ["变化点", "Vue2", "Vue3"],
                alignments: [.leading, .center, .trailing],
                rows: [
                    ["生命周期", "beforeDestroy / destroyed", "beforeUnmount / unmounted"],
                    ["filter", "支持", "移除（用计算属性/方法替代）"],
                    ["事件总线", "$on|$off|$once", "移除，需用 mitt 等第三方库"]
                ]
            ))
        ])
    }

    func testPlainPipesDoNotBecomeATable() {
        XCTAssertEqual(MarkdownBlocks.parse("Vue2 | Vue3\n普通说明"), [.paragraph("Vue2 | Vue3\n普通说明")])
    }
}
