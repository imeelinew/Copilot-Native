import Foundation
import XCTest
@testable import CopilotNative

private final class MockChatURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "mock.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status = request.url?.path == "/error" ? 429 : 200
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = status == 200
            ? "data: {\"choices\":[{\"delta\":{\"content\":\"第一段\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"第二段\"}}]}\n\ndata: [DONE]\n\n"
            : "error"
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ChatCompletionClientTests: XCTestCase {
    func testStreamingChunksAreCombined() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockChatURLProtocol.self]
        let client = ChatCompletionClient(session: URLSession(configuration: configuration))
        let settings = AIConfiguration(
            endpoint: URL(string: "https://mock.invalid/answer")!, model: "test-model", apiKey: "test-key"
        )
        var chunks: [String] = []
        for try await chunk in client.streamAnswer(for: "测试", configuration: settings) {
            chunks.append(chunk)
        }
        XCTAssertEqual(chunks, ["第一段", "第二段"])
    }

    func testHTTPErrorIsReported() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockChatURLProtocol.self]
        let client = ChatCompletionClient(session: URLSession(configuration: configuration))
        let settings = AIConfiguration(
            endpoint: URL(string: "https://mock.invalid/error")!, model: "test-model", apiKey: "test-key"
        )
        do {
            for try await _ in client.streamAnswer(for: "测试", configuration: settings) {}
            XCTFail("Expected a server error")
        } catch AIClientError.serverStatus(let code) {
            XCTAssertEqual(code, 429)
        }
    }
}
