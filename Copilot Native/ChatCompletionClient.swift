import Foundation

protocol InterviewAnswering: Sendable {
    func streamAnswer(for question: String, configuration: AIConfiguration) -> AsyncThrowingStream<String, Error>
}

enum AIClientError: LocalizedError {
    case serverStatus(Int)
    case invalidResponse
    case emptyAnswer

    var errorDescription: String? {
        switch self {
        case .serverStatus(let code): "模型服务返回 HTTP \(code)"
        case .invalidResponse: "模型服务返回了无法解析的内容"
        case .emptyAnswer: "模型没有返回答案"
        }
    }
}

struct ChatCompletionClient: InterviewAnswering {
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let stream = true
    }

    private struct Chunk: Decodable {
        struct Choice: Decodable {
            struct Delta: Decodable { let content: String? }
            let delta: Delta
        }
        let choices: [Choice]
    }

    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func streamAnswer(for question: String, configuration: AIConfiguration) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var request = URLRequest(url: configuration.endpoint)
                    request.httpMethod = "POST"
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
                    request.timeoutInterval = 60
                    request.httpBody = try JSONEncoder().encode(RequestBody(
                        model: configuration.model,
                        messages: [
                            .init(role: "system", content: "你是模拟面试助手。针对用户的问题，直接给出准确、简洁、适合口头面试表达的答案。技术问题先概括要点，再说明关键原理；需要时使用 Markdown 列表或简短代码。使用提问所用语言回答，不编造不确定的事实。"),
                            .init(role: "user", content: question)
                        ]
                    ))
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else { throw AIClientError.invalidResponse }
                    guard (200..<300).contains(http.statusCode) else { throw AIClientError.serverStatus(http.statusCode) }

                    var producedContent = false
                    var didFinish = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" {
                            didFinish = true
                            break
                        }
                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else {
                            throw AIClientError.invalidResponse
                        }
                        if let content = chunk.choices.first?.delta.content, !content.isEmpty {
                            producedContent = true
                            continuation.yield(content)
                        }
                    }
                    try Task.checkCancellation()
                    guard didFinish else { throw AIClientError.invalidResponse }
                    guard producedContent else { throw AIClientError.emptyAnswer }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
