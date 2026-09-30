import Foundation
import Observation

enum AIAnswerState: Equatable {
    case idle
    case waiting
    case retrieving
    case streaming
    case complete
    case needsConfiguration
    case failed(String)
}

@MainActor
@Observable
final class AIAnswerController {
    private let client: any InterviewAnswering
    private let debounce: Duration
    @ObservationIgnored private var pendingTask: Task<Void, Never>?
    private var currentQuery = ""
    private var currentConfiguration: AIConfiguration?
    private var scope: InterviewProjectScope = .automatic
    private var previousProject: String?
    private var previousQuestion: String?
    private(set) var references = KnowledgeRetrieval.empty
    private(set) var answer = ""
    private(set) var state: AIAnswerState = .idle

    init(client: any InterviewAnswering = ChatCompletionClient(), debounce: Duration = .milliseconds(700)) {
        self.client = client
        self.debounce = debounce
    }

    func update(query: String, hasResults: Bool, configuration: AIConfiguration?, scope: InterviewProjectScope = .automatic) {
        pendingTask?.cancel()
        pendingTask = nil
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentConfiguration = configuration
        if self.scope != scope { previousProject = nil; previousQuestion = nil }
        self.scope = scope
        references = .empty
        answer = ""

        guard !hasResults, currentQuery.count >= 2 else {
            state = .idle
            return
        }
        guard let configuration else {
            state = .needsConfiguration
            return
        }
        start(query: currentQuery, configuration: configuration, shouldDebounce: true)
    }

    func retry() {
        guard let configuration = currentConfiguration, currentQuery.count >= 2 else { return }
        pendingTask?.cancel()
        answer = ""
        references = .empty
        start(query: currentQuery, configuration: configuration, shouldDebounce: false)
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        state = .idle
        answer = ""
        references = .empty
    }

    private func start(query: String, configuration: AIConfiguration, shouldDebounce: Bool) {
        state = .waiting
        pendingTask = Task {
            do {
                if shouldDebounce { try await Task.sleep(for: debounce) }
                try Task.checkCancellation()
                guard currentQuery == query else { return }
                state = .retrieving
                let retrieved: KnowledgeRetrieval
                do {
                    retrieved = try await InterviewKnowledgeEngine.shared.retrieve(question: query, scope: scope, previousProject: previousProject, previousQuestion: previousQuestion)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    retrieved = .init(passages: [], projectIDs: [], usedVectors: false, warning: "本地资料读取失败：" + error.localizedDescription)
                }
                try Task.checkCancellation()
                guard currentQuery == query else { return }
                references = retrieved
                state = .streaming
                for try await chunk in client.streamAnswer(for: query, configuration: configuration, context: retrieved) {
                    try Task.checkCancellation()
                    guard currentQuery == query else { return }
                    answer += chunk
                }
                try Task.checkCancellation()
                guard currentQuery == query else { return }
                state = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .failed(AIClientError.emptyAnswer.localizedDescription) : .complete
                if state == .complete {
                    previousProject = retrieved.projectIDs.count == 1 ? retrieved.projectIDs.first : nil
                    previousQuestion = retrieved.previousQuestion ?? query
                }
            } catch is CancellationError {
                // A newer query owns the visible state.
            } catch {
                guard !Task.isCancelled, currentQuery == query else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}
