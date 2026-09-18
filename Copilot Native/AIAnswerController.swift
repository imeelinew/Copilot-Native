import Foundation
import Observation

enum AIAnswerState: Equatable {
    case idle
    case waiting
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
    private(set) var answer = ""
    private(set) var state: AIAnswerState = .idle

    init(client: any InterviewAnswering = ChatCompletionClient(), debounce: Duration = .milliseconds(700)) {
        self.client = client
        self.debounce = debounce
    }

    func update(query: String, hasResults: Bool, configuration: AIConfiguration?) {
        pendingTask?.cancel()
        pendingTask = nil
        currentQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        currentConfiguration = configuration
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
        start(query: currentQuery, configuration: configuration, shouldDebounce: false)
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        state = .idle
        answer = ""
    }

    private func start(query: String, configuration: AIConfiguration, shouldDebounce: Bool) {
        state = .waiting
        pendingTask = Task {
            do {
                if shouldDebounce { try await Task.sleep(for: debounce) }
                try Task.checkCancellation()
                guard currentQuery == query else { return }
                state = .streaming
                for try await chunk in client.streamAnswer(for: query, configuration: configuration) {
                    try Task.checkCancellation()
                    guard currentQuery == query else { return }
                    answer += chunk
                }
                try Task.checkCancellation()
                guard currentQuery == query else { return }
                state = answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? .failed(AIClientError.emptyAnswer.localizedDescription) : .complete
            } catch is CancellationError {
                // A newer query owns the visible state.
            } catch {
                guard !Task.isCancelled, currentQuery == query else { return }
                state = .failed(error.localizedDescription)
            }
        }
    }
}
