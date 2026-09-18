import Foundation
import XCTest
@testable import CopilotNative

private struct DelayedAnswerClient: InterviewAnswering {
    func streamAnswer(for question: String, configuration: AIConfiguration) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                try? await Task.sleep(for: .milliseconds(question == "旧问题" ? 100 : 20))
                continuation.yield(question)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class AIAnswerControllerTests: XCTestCase {
    @MainActor
    func testNewQueryDiscardsOldAnswer() async throws {
        let config = AIConfiguration(
            endpoint: URL(string: "https://example.com/v1/chat/completions")!, model: "test", apiKey: "test"
        )
        let controller = AIAnswerController(client: DelayedAnswerClient(), debounce: .milliseconds(1))
        controller.update(query: "旧问题", hasResults: false, configuration: config)
        try await Task.sleep(for: .milliseconds(20))
        controller.update(query: "新问题", hasResults: false, configuration: config)
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(controller.answer, "新问题")
        XCTAssertEqual(controller.state, .complete)
    }

    @MainActor
    func testLocalResultAndShortQueryDoNotStartAI() async throws {
        let config = AIConfiguration(
            endpoint: URL(string: "https://example.com/v1/chat/completions")!, model: "test", apiKey: "test"
        )
        let controller = AIAnswerController(client: DelayedAnswerClient(), debounce: .milliseconds(1))
        controller.update(query: "已有答案", hasResults: true, configuration: config)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.answer.isEmpty)

        controller.update(query: "问", hasResults: false, configuration: config)
        XCTAssertEqual(controller.state, .idle)
        controller.update(query: "未命中", hasResults: false, configuration: nil)
        XCTAssertEqual(controller.state, .needsConfiguration)
    }
}
