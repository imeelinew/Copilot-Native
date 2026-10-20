// Compile with the production ChatCompletionClient.swift and RemoteAISettings.swift.
import AppKit
import Foundation

// This harness isolates transport from the local knowledge database and MLX.
struct KnowledgeRetrieval: Sendable {
    static let empty = KnowledgeRetrieval()
    var projectIDs: [String] { [] }
    var promptContext: String { "" }
}

private final class StubProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let status = path == "/unsupported" ? 400 : 200
        let content: String
        switch path {
        case "/malformed": content = "data: not-json\n\n"
        case "/truncated": content = "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n"
        case "/empty": content = "data: [DONE]\n\n"
        default: content = "data: {\"choices\":[{\"delta\":{\"content\":\"答案\"}}]}\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"42\"}}]}\n\ndata: [DONE]\n\n"
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                                            headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(content.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct ScreenQuestionClientTests {
    static func checkSeparateExplanation(_ answer: String) {
        guard let solution = answer.range(of: "## 解题答案"), let explanation = answer.range(of: "## 代码怎么讲") else {
            preconditionFailure("Code answers must have separate solution and explanation sections")
        }
        precondition(solution.lowerBound < explanation.lowerBound)
        let spoken = answer[explanation.upperBound...]
        precondition(spoken.count > 40 && !spoken.contains("```"), "Explanation must use words, not repeat a code block")
    }
    @MainActor
    final class BatchProbe {
        var sent: [[[Data]]] = []
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for batch state")
    }

    @MainActor
    static func testBatching() async throws {
        let suiteName = "screen-question-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = RemoteAISettings(defaults: defaults, loadKey: { "test" })
        settings.endpointText = "https://example.com/chat/completions"
        settings.modelText = "vision-test"
        try settings.save(defaults: defaults, saveKey: { _ in })
        let probe = BatchProbe()
        let controller = ScreenQuestionController(settings: settings, registerShortcuts: false, captureImages: { display in
            try await Task.sleep(for: .milliseconds(15))
            return [Data([UInt8(display)])]
        }, answerStream: { shots, _ in
            AsyncThrowingStream { continuation in
                Task { @MainActor in
                    probe.sent.append(shots)
                    continuation.yield("answer")
                    continuation.finish()
                }
            }
        })
        controller.enqueueCapture(displayID: 1)
        controller.enqueueCapture(displayID: 2)
        try await waitUntil { controller.pendingCaptureCount == 0 }
        precondition(probe.sent.isEmpty && controller.pendingCount == 2, "Capture must not send")
        controller.enqueueCapture(displayID: 3)
        controller.sendPending() // Must wait for page 3.
        controller.enqueueCapture(displayID: 4) // Must belong to the next batch.
        try await waitUntil { probe.sent.count == 1 && !controller.isWorking && controller.pendingCaptureCount == 0 }
        precondition(probe.sent[0].map { $0[0] } == [Data([1]), Data([2]), Data([3])])
        precondition(controller.pendingShots == [[Data([4])]])
        controller.sendPending()
        try await waitUntil { probe.sent.count == 2 && !controller.isWorking }
        precondition(controller.pendingCount == 0 && probe.sent[1] == [[Data([4])]])
        controller.enqueueCapture(displayID: 5)
        controller.clearPending()
        controller.enqueueCapture(displayID: 6)
        try await waitUntil { controller.pendingCaptureCount == 0 }
        precondition(controller.pendingShots == [[Data([6])]], "Clear must invalidate outstanding captures")
        controller.shutdown()

        let held = BatchProbe()
        let retry = ScreenQuestionController(settings: settings, registerShortcuts: false, captureImages: { _ in [Data([7])] }, answerStream: { shots, _ in
            AsyncThrowingStream { continuation in
                Task { @MainActor in held.sent.append(shots); held.continuation = continuation }
            }
        })
        retry.enqueueCapture(displayID: 7)
        retry.sendPending()
        try await waitUntil { held.continuation != nil }
        retry.cancel()
        precondition(retry.pendingShots == [[Data([7])]] && !retry.isWorking)
        held.continuation = nil
        retry.sendPending()
        try await waitUntil { held.sent.count == 2 && held.continuation != nil }
        held.continuation?.finish(throwing: AIClientError.serverStatus(400))
        try await waitUntil { !retry.isWorking }
        precondition(retry.pendingShots == [[Data([7])]], "Failed send must preserve screenshots once")
        retry.shutdown()
        print("PASS: capture without sending, ordered batching, send/capture boundary, clear, cancellation and failed-send retry")
    }

    static func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
        var answer = ""
        for try await chunk in stream { answer += chunk }
        return answer
    }

    @MainActor
    final class RepairProbe {
        var requests: [[ScreenshotConversationMessage]] = []
        var captures: [CGDirectDisplayID] = []
        var failNext = false
        var holdNext = false
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
    }

    @MainActor
    static func testRepairSession() async throws {
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = RemoteAISettings(defaults: defaults, loadKey: { "test" })
        settings.endpointText = "https://example.com/chat/completions"
        settings.modelText = "vision-test"
        try settings.save(defaults: defaults, saveKey: { _ in })
        let probe = RepairProbe()
        let controller = ScreenQuestionController(settings: settings, registerShortcuts: false, captureImages: { display in
            probe.captures.append(display)
            return [Data([UInt8(display)])]
        }, answerStream: { _, _ in
            AsyncThrowingStream { $0.yield("original code"); $0.finish() }
        }, conversationStream: { messages, _ in
            AsyncThrowingStream { continuation in
                Task { @MainActor in
                    probe.requests.append(messages)
                    if probe.failNext { probe.failNext = false; continuation.finish(throwing: AIClientError.serverStatus(400)) }
                    else if probe.holdNext { probe.holdNext = false; probe.continuation = continuation }
                    else { continuation.yield("fixed code \(probe.requests.count)"); continuation.finish() }
                }
            }
        })
        controller.enqueueRepair(displayID: 20)
        precondition(probe.captures.isEmpty && !controller.hasSession)
        controller.enqueueCapture(displayID: 1)
        controller.sendPending()
        try await waitUntil { controller.hasSession && !controller.isWorking }
        let session = controller.sessionID
        controller.clearPending()
        precondition(controller.sessionID == session && controller.answer == "original code")

        controller.enqueueCapture(displayID: 9)
        controller.enqueueRepair(displayID: 2)
        try await waitUntil { probe.requests.count == 1 && !controller.isWorking && !controller.isCapturingRepair }
        precondition(controller.sessionID == session && controller.repairCount == 1)
        precondition(controller.answerVersions == ["original code", "fixed code 1"])
        controller.selectAnswer(offset: -1)
        precondition(controller.displayedAnswer == "original code" && controller.displayedAnswerTitle == "原始解答")
        controller.selectAnswer(offset: -1)
        precondition(controller.viewingAnswerIndex == 0)
        precondition(controller.pendingShots == [[Data([9])]], "Repair must not consume queued question screenshots")
        precondition(probe.requests[0].map(\.role) == ["user", "assistant", "user"])
        precondition(probe.requests[0][0].imageJPEGs == [Data([1])])
        precondition(probe.requests[0][1].content == "original code" && probe.requests[0][2].imageJPEGs == [Data([2])])

        controller.enqueueRepair(displayID: 3)
        try await waitUntil { probe.requests.count == 2 && !controller.isWorking && !controller.isCapturingRepair }
        precondition(probe.requests[1].count == 5 && probe.requests[1][3].content == "fixed code 1")
        precondition(controller.repairCount == 2)
        precondition(controller.displayedAnswer == "fixed code 2" && controller.answerVersions.count == 3)
        controller.selectAnswer(offset: -2)
        precondition(controller.displayedAnswer == "original code")
        controller.selectAnswer(offset: 1)
        precondition(controller.displayedAnswer == "fixed code 1" && controller.displayedAnswerTitle == "第 1 次排错")
        probe.failNext = true
        controller.enqueueRepair(displayID: 4)
        try await waitUntil { probe.requests.count == 3 && !controller.isWorking && !controller.isCapturingRepair }
        precondition(controller.answer == "fixed code 2" && controller.repairCount == 2 && controller.sessionID == session)
        precondition(controller.answerVersions.count == 3 && controller.displayedAnswer == "fixed code 2")
        controller.enqueueRepair(displayID: 5)
        try await waitUntil { probe.requests.count == 4 && !controller.isWorking && !controller.isCapturingRepair }
        precondition(probe.requests[3].count == 7 && !probe.requests[3].flatMap(\.imageJPEGs).contains(Data([4])))

        probe.holdNext = true
        controller.enqueueRepair(displayID: 6)
        try await waitUntil { probe.continuation != nil }
        controller.selectAnswer(offset: -controller.viewingAnswerIndex)
        precondition(controller.displayedAnswer == "original code", "Original answer must remain readable while a repair is streaming")
        controller.clearPending()
        precondition(controller.isWorking && controller.sessionID == session)
        controller.cancel()
        precondition(controller.answer == "fixed code 4" && controller.repairCount == 3 && controller.pendingCount == 0)
        precondition(controller.answerVersions.count == 4 && controller.displayedAnswer == "original code")
        probe.continuation = nil
        controller.enqueueRepair(displayID: 7)
        try await waitUntil { probe.requests.count == 6 && !controller.isWorking && !controller.isCapturingRepair }
        precondition(probe.requests[5].count == 9 && !probe.requests[5].flatMap(\.imageJPEGs).contains(Data([6])))

        controller.enqueueCapture(displayID: 10)
        controller.sendPending()
        try await waitUntil { controller.sessionID != session && !controller.isWorking }
        precondition(controller.repairCount == 0)
        precondition(controller.answerVersions == ["original code"] && controller.selectedAnswerIndex == nil)
        controller.enqueueRepair(displayID: 11)
        try await waitUntil { probe.requests.count == 7 && !controller.isWorking && !controller.isCapturingRepair }
        precondition(probe.requests[6].count == 3 && probe.requests[6][0].imageJPEGs == [Data([10])])
        controller.shutdown()
        print("PASS: original images/code in repair session, repeated followups, queue isolation, clear, failure/cancel rollback, new-question reset")
    }

    @MainActor
    static func testProtectedPanel() async throws {
        _ = NSApplication.shared
        let parts = ScreenshotAnswerParts("## 解题答案\n```python\n## 代码怎么讲\nprint('keep this in code')\n```\n## 代码怎么讲\n先读取输入，再计算结果。")
        precondition(parts.solution.contains("## 代码怎么讲") && parts.solution.contains("print("))
        precondition(parts.explanation == "先读取输入，再计算结果。")
        precondition(ScreenshotAnswerParts("旧版没有分区标题的回答").solution == "旧版没有分区标题的回答")
        precondition(ScreenshotAnswerParts("## 解题答案\n正在写代码\n## 代码怎").explanation.isEmpty)
        let suiteName = UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = RemoteAISettings(defaults: defaults, loadKey: { "test" })
        settings.endpointText = "https://example.com/chat/completions"
        settings.modelText = "test"
        try settings.save(defaults: defaults, saveKey: { _ in })
        let controller = ScreenQuestionController(settings: settings, registerShortcuts: false, captureImages: { _ in [Data([1])] }, answerStream: { _, _ in
            AsyncThrowingStream { continuation in
                continuation.yield("## 解题答案\n\n保留最新请求的结果，并取消旧请求。\n\n```typescript\nconst controller = new AbortController();\nawait fetch('/api/search', { signal: controller.signal });\n```\n\n" + String(repeating: "填写说明：把这段代码放到请求处理函数中。\n\n", count: 30) + "## 代码怎么讲\n\n" + String(repeating: "我的思路是先取消上一次请求，再显示最新一次请求的结果，避免旧结果覆盖新结果。\n\n", count: 30))
                continuation.finish()
            }
        })
        controller.enqueueCapture(displayID: 1)
        controller.sendPending()
        try await waitUntil { controller.answer.count > 500 && !controller.isWorking }
        let owner = ScreenAnswerPanelController(controller: controller, registerShortcuts: false)
        let keyWindow = NSApp.keyWindow
        let panel = owner.preparePanel()
        precondition(!panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain)
        precondition(panel.styleMask.contains(.nonactivatingPanel) && panel.level == .floating)
        precondition(!panel.hidesOnDeactivate && panel.sharingType == .none)
        let original = UserDefaults.standard.object(forKey: ScreenCapturePrivacy.defaultsKey)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: ScreenCapturePrivacy.defaultsKey) }
            else { UserDefaults.standard.removeObject(forKey: ScreenCapturePrivacy.defaultsKey) }
            owner.shutdown()
        }
        UserDefaults.standard.set(false, forKey: ScreenCapturePrivacy.defaultsKey)
        panel.sharingType = .readOnly
        ScreenCapturePrivacy.applyToAllWindows()
        precondition(panel.sharingType == .none, "Ordinary window preference must not disable panel privacy")
        precondition(NSApp.keyWindow === keyWindow, "Preparing panel must not take focus")

        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        precondition(owner.scroll.view != nil, "Native scroll bridge must attach to the actual answer scroll view")
        precondition(owner.explanationScroll.view != nil && owner.explanationScroll.view !== owner.scroll.view,
                     "Solution and explanation must have separate native scroll views")
        owner.scroll.scroll(1)
        precondition(owner.scroll.view!.contentView.bounds.minY > 0, "Actual answer must scroll")
        precondition(owner.explanationScroll.view!.contentView.bounds.minY == 0)
        let answerOffset = owner.scroll.view!.contentView.bounds.minY
        owner.explanationScroll.scroll(1)
        precondition(owner.explanationScroll.view!.contentView.bounds.minY > 0 && owner.scroll.view!.contentView.bounds.minY == answerOffset,
                     "Scrolling the explanation must not move the solution")
        owner.scroll.reset()
        owner.explanationScroll.reset()
        if let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/copilot-answer-panel-preview.png"))
        }

        final class FlippedDocument: NSView { override var isFlipped: Bool { true } }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        scroll.documentView = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 400, height: 2000))
        owner.scroll.view = scroll
        owner.scroll.scroll(1)
        precondition(scroll.contentView.bounds.minY > 0)
        owner.scroll.scroll(-1)
        precondition(scroll.contentView.bounds.minY == 0)
        print("PASS: floating panel protected before display, exclusion cannot be disabled, no keyboard focus, page scrolling")
    }

    @MainActor
    final class RegionProbe {
        var selection: CheckedContinuation<ScreenCaptureRegion?, Never>?
        var sent: [[[Data]]] = []
        var captured: [CGDirectDisplayID] = []
    }

    @MainActor
    static func testRegionCapture() async throws {
        let suite = "region-capture-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = RemoteAISettings(defaults: defaults, loadKey: { "test" })
        settings.endpointText = "https://example.com/chat/completions"
        settings.modelText = "test"
        try settings.save(defaults: defaults, saveKey: { _ in })
        let probe = RegionProbe()
        let controller = ScreenQuestionController(settings: settings, registerShortcuts: false,
            captureImages: { [Data([UInt8($0)])] }, captureRegionImages: { region in
                probe.captured.append(region.displayID)
                if region.displayID == 99 { throw AIClientError.invalidResponse }
                return [Data([UInt8(region.displayID)])]
            }, answerStream: { shots, _ in AsyncThrowingStream { continuation in
                Task { @MainActor in probe.sent.append(shots); continuation.yield("answer"); continuation.finish() }
            } })
        defer { controller.shutdown() }
        let size = CGSize(width: 1440, height: 900)
        func region(_ id: CGDirectDisplayID) -> ScreenCaptureRegion {
            .init(displayID: id, displaySize: size, rect: CGRect(x: 100, y: 200, width: 300, height: 150))
        }
        controller.enqueueCapture(displayID: 1)
        controller.enqueueRegionCapture { await withCheckedContinuation { probe.selection = $0 } }
        controller.sendPending()
        controller.enqueueCapture(displayID: 3)
        try await waitUntil { probe.selection != nil }
        precondition(probe.sent.isEmpty && controller.pendingCount == 3)
        probe.selection?.resume(returning: region(2)); probe.selection = nil
        try await waitUntil { probe.sent.count == 1 && !controller.isWorking && controller.pendingShots.count == 1 }
        precondition(probe.sent[0] == [[Data([1])], [Data([2])]])
        precondition(controller.pendingShots == [[Data([3])]])
        controller.enqueueRegionCapture { nil }
        try await waitUntil { !controller.isSelectingRegion && controller.pendingCaptureCount == 0 }
        precondition(controller.pendingShots == [[Data([3])]])
        controller.enqueueRegionCapture { await withCheckedContinuation { probe.selection = $0 } }
        try await waitUntil { probe.selection != nil }
        controller.cancelRegionSelection()
        probe.selection?.resume(returning: region(4)); probe.selection = nil
        try await waitUntil { controller.pendingCaptureCount == 0 }
        precondition(!probe.captured.contains(4) && controller.pendingShots == [[Data([3])]])
        controller.enqueueRegionCapture { await withCheckedContinuation { probe.selection = $0 } }
        try await waitUntil { probe.selection != nil }
        controller.enqueueCapture(displayID: 5)
        controller.clearPending()
        probe.selection?.resume(returning: region(6)); probe.selection = nil
        try await waitUntil { controller.pendingCount == 0 }
        controller.enqueueRegionCapture { region(7) }
        try await waitUntil { controller.pendingShots.count == 1 }
        precondition(controller.pendingShots == [[Data([7])]] && !probe.captured.contains(6))
        controller.enqueueRegionCapture { region(99) }
        try await waitUntil { controller.captureError != nil && controller.pendingCaptureCount == 0 }
        precondition(controller.pendingShots == [[Data([7])]])
        controller.clearPending()
        for id in 10..<16 { controller.enqueueCapture(displayID: CGDirectDisplayID(id)) }
        var opened = false
        controller.enqueueRegionCapture { opened = true; return region(17) }
        try await waitUntil { controller.pendingCaptureCount == 0 }
        precondition(!opened && controller.pendingShots.count == 6 && !controller.isSelectingRegion)

        let config = try ScreenQuestionController.captureConfiguration(pixelSize: CGSize(width: 2880, height: 1800), displaySize: size, region: region(2))
        precondition(config.sourceRect == region(2).rect && config.width == 600 && config.height == 300 && !config.showsCursor)
        let full = try ScreenQuestionController.captureConfiguration(pixelSize: CGSize(width: 2880, height: 1800), displaySize: size, region: nil)
        precondition(full.width == 2880 && full.height == 1800)
        let clipped = ScreenCaptureRegion(displayID: 1, displaySize: size, rect: CGRect(x: -10, y: -20, width: 200, height: 100))
        let clipConfig = try ScreenQuestionController.captureConfiguration(pixelSize: CGSize(width: 2880, height: 1800), displaySize: size, region: clipped)
        precondition(clipConfig.sourceRect == CGRect(x: 0, y: 0, width: 190, height: 80))
        precondition(clipConfig.width == 380 && clipConfig.height == 160)
        let reverse = ScreenCaptureRegion.rectangle(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 100, y: 100), bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
        precondition(reverse == CGRect(x: 100, y: 100, width: 300, height: 200))
        let bigSize = CGSize(width: 3840, height: 2160)
        let bigRegion = ScreenCaptureRegion(displayID: 1, displaySize: bigSize, rect: CGRect(origin: .zero, size: bigSize))
        let bigConfig = try ScreenQuestionController.captureConfiguration(pixelSize: CGSize(width: 7680, height: 4320), displaySize: bigSize, region: bigRegion)
        precondition(bigConfig.width == 4096 && bigConfig.height == 2304)
        do {
            _ = try ScreenQuestionController.captureConfiguration(pixelSize: size, displaySize: CGSize(width: 1920, height: 1080), region: region(2))
            preconditionFailure("Changed display size must reject old selection")
        } catch { }
        do {
            let outside = ScreenCaptureRegion(displayID: 1, displaySize: size, rect: CGRect(x: 2000, y: 0, width: 100, height: 100))
            _ = try ScreenQuestionController.captureConfiguration(pixelSize: size, displaySize: size, region: outside)
            preconditionFailure("Outside selection must not capture full display")
        } catch { }
        _ = NSApplication.shared
        let keyWindow = NSApp.keyWindow
        let selector = RegionScreenshotSelector()
        let panel = selector.preparePanel(frame: CGRect(x: -1440, y: 900, width: 1440, height: 900))
        precondition(panel.sharingType == .none && !panel.isVisible && !panel.canBecomeKey && !panel.canBecomeMain)
        precondition(panel.styleMask.contains(.nonactivatingPanel) && !panel.hasShadow)
        precondition((panel.contentView as? RegionSelectionView)?.isFlipped == true)
        let original = UserDefaults.standard.object(forKey: ScreenCapturePrivacy.defaultsKey)
        UserDefaults.standard.set(false, forKey: ScreenCapturePrivacy.defaultsKey)
        panel.sharingType = .readOnly
        ScreenCapturePrivacy.applyToAllWindows()
        precondition(panel.sharingType == .none && NSApp.keyWindow === keyWindow)
        if let original { UserDefaults.standard.set(original, forKey: ScreenCapturePrivacy.defaultsKey) }
        else { UserDefaults.standard.removeObject(forKey: ScreenCapturePrivacy.defaultsKey) }
        selector.cancel()
        print("PASS: mixed region/fullscreen order, send boundary, cancel/clear/failure/capacity; Retina crop coordinates, bounds, output scale, changed display rejection; protected nonactivating selection overlay")
    }

    @MainActor
    static func main() async throws {
        let config = AIConfiguration(endpoint: URL(string: "https://api.deepseek.com/success")!, model: "deepseek-flash", apiKey: "test-key")
        let fixture = Data([0xff, 0xd8, 0xff, 0xd9])
        let data = try ChatCompletionClient.screenshotRequestBody(imageJPEGs: [fixture, fixture], configuration: config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let messages = json["messages"] as! [[String: Any]]
        let parts = messages[1]["content"] as! [[String: Any]]
        precondition(parts.count == 3 && parts[0]["type"] as? String == "text")
        let url = (parts[1]["image_url"] as! [String: Any])["url"] as! String
        precondition(Data(base64Encoded: String(url.split(separator: ",")[1])) == fixture)
        precondition(messages[0]["content"] is String && json["stream"] as? Bool == true)
        precondition((json["thinking"] as? [String: String])?["type"] == "disabled")
        let history: [ScreenshotConversationMessage] = [
            .init(role: "user", content: "original problem", imageJPEGs: [fixture]),
            .init(role: "assistant", content: "previous code"),
            .init(role: "user", content: "runtime error", imageJPEGs: [fixture])
        ]
        let repairBody = try ChatCompletionClient.screenshotConversationRequestBody(messages: history, configuration: config)
        let repairJSON = try JSONSerialization.jsonObject(with: repairBody) as! [String: Any]
        let repairMessages = repairJSON["messages"] as! [[String: Any]]
        precondition(repairMessages.map { $0["role"] as! String } == ["system", "user", "assistant", "user"])
        precondition(repairMessages[2]["content"] as? String == "previous code")
        precondition(repairMessages[1]["content"] is [[String: Any]] && repairMessages[3]["content"] is [[String: Any]])

        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [StubProtocol.self]
        let client = ChatCompletionClient(session: URLSession(configuration: sessionConfig))
        let imageAnswer = try await collect(client.streamScreenshotAnswer(imageJPEGs: [fixture], configuration: config))
        precondition(imageAnswer == "答案42")
        let textAnswer = try await collect(client.streamAnswer(for: "测试问题", configuration: config))
        precondition(textAnswer == "答案42")
        for path in ["unsupported", "malformed", "truncated", "empty"] {
            let broken = AIConfiguration(endpoint: URL(string: "https://example.com/" + path)!, model: "test", apiKey: "test")
            do {
                _ = try await collect(client.streamScreenshotAnswer(imageJPEGs: [fixture], configuration: broken))
                fatalError("Expected failure for " + path)
            } catch is AIClientError { }
        }
        print("PASS: image payload, multi-image, image/text streaming, HTTP failure, malformed/truncated/empty stream")
        try await testBatching()
        try await testRegionCapture()
        try await testRepairSession()
        try await testProtectedPanel()

        if CommandLine.arguments.contains("--live-repair") {
            let defaults = UserDefaults.standard.persistentDomain(forName: "com.eli.CopilotNative")!
            let live = AIConfiguration(endpoint: URL(string: defaults["remoteAIEndpoint"] as! String)!,
                                       model: defaults["remoteAIModel"] as! String, apiKey: defaults["remoteAIApiKey"] as! String)
            func screenshot(_ text: String) -> Data {
                let image = NSImage(size: NSSize(width: 1300, height: 800))
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 1300, height: 800).fill()
                (text as NSString).draw(in: NSRect(x: 40, y: 40, width: 1220, height: 720), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 26, weight: .regular), .foregroundColor: NSColor.black
                ])
                image.unlockFocus()
                return NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
            }
            let question = screenshot("React JSX playground\nFile: src/App.jsx\nTask: a counter initially at 0. Each click must increase it by TWO.\nImplement in the current file without extra dependencies.")
            let error = screenshot("Browser error overlay\nReferenceError: currentCount is not defined\nsrc/App.jsx:6:43\nThe page fails when clicking the button.")
            let previousCode = """
            修改 src/App.jsx，完整替换为：
            ```jsx
            import { useState } from 'react';
            export default function App() {
              const [count, setCount] = useState(0);
              return <button onClick={() => setCount(currentCount + 2)}>{count}</button>;
            }
            ```
            """
            let messages: [ScreenshotConversationMessage] = [
                ChatCompletionClient.screenshotQuestionMessage(imageJPEGs: [question], screenshotImageCounts: [1]),
                .init(role: "assistant", content: previousCode),
                .init(role: "user", content: "这是同一道题的排错截图。代码按你上一轮答案填写，点击按钮后报错。请结合原题和之前的代码明确指出改哪里，给最小修复，保留原题的计数要求。", imageJPEGs: [error])
            ]
            let answer = try await collect(ChatCompletionClient().streamScreenshotConversation(messages: messages, configuration: live))
            checkSeparateExplanation(answer)
            precondition(answer.contains("currentCount") && answer.contains("App.jsx") && answer.contains("2"))
            print("PASS: live repair retains original image requirement and previous code, locates error in a later screenshot\n" + answer)
        }

        if CommandLine.arguments.contains("--live-writing") || CommandLine.arguments.contains("--live-simple") {
            // Validate placement instructions against visible, synthetic editor contexts.
            let defaults = UserDefaults.standard.persistentDomain(forName: "com.eli.CopilotNative")!
            let live = AIConfiguration(endpoint: URL(string: defaults["remoteAIEndpoint"] as! String)!,
                                       model: defaults["remoteAIModel"] as! String, apiKey: defaults["remoteAIApiKey"] as! String)
            let simple = CommandLine.arguments.contains("--live-simple")
            let fixtures = simple ? [
                "React JavaScript playground\nVisible file: src/App.jsx\nStopwatch task (30 minutes):\nBuild a stopwatch with Start/Stop and Reset buttons.\nStart/Stop starts or pauses; restarting continues elapsed time.\nReset sets elapsed time to zero and stops.\nDisplay elapsed time as a clickable button (also toggles start/stop).\nThere are THREE buttons: timer display, separate Start/Stop control, separate Reset control.\nFormat hours, minutes, seconds and TWO-DIGIT HUNDREDTHS of a second.\nLeading zero hours/minutes may be omitted.\nComplete units must carry at exact boundaries, not overflow.\nStart/Stop label must match running state.\nUse React; focus on functionality.\n\nCurrent src/App.jsx:\nexport default function App() { return <div>Todo</div>; }"
            ] : [
                "Online Judge - Python 3\nTask: Given nums and target, return indices of the two numbers adding to target.\nComplete the method below. Keep the signature. No stdin required.\n\nCurrent editor:\nclass Solution:\n    def twoSum(self, nums: list[int], target: int) -> list[int]:\n        pass",
                "React + TypeScript project\nVisible files:\nsrc/App.tsx\nsrc/main.tsx\npackage.json\n\nTask: Implement useCounter(initial) with count, increment(), reset().\nDemonstrate it with two buttons in App. Use the existing project.\nCurrent src/App.tsx:\nexport default function App() { return <div>Todo</div>; }"
            ]
            for (index, fixture) in fixtures.enumerated() {
                let image = NSImage(size: NSSize(width: 1500, height: 1000))
                image.lockFocus()
                NSColor.white.setFill()
                NSRect(x: 0, y: 0, width: 1500, height: 1000).fill()
                (fixture as NSString).draw(in: NSRect(x: 40, y: 50, width: 1420, height: 900), withAttributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 25, weight: .regular), .foregroundColor: NSColor.black
                ])
                image.unlockFocus()
                let jpeg = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
                let answer = try await collect(ChatCompletionClient().streamScreenshotAnswer(imageJPEGs: [jpeg], configuration: live, screenshotImageCounts: [1]))
                checkSeparateExplanation(answer)
                guard let fence = answer.range(of: "```") else { preconditionFailure("Missing answer code") }
                let guidance = String(answer[..<fence.lowerBound])
                precondition(guidance.count > 30, "Writing guidance must precede code")
                if simple {
                    precondition(guidance.contains("src/App.jsx"))
                    precondition(answer.contains("setInterval") && answer.contains("clearInterval"))
                    precondition(answer.contains("Date.now") || answer.contains("performance.now"))
                    precondition(!answer.contains("requestAnimationFrame("))
                    precondition(answer.contains("Stop") && answer.contains("Start") && answer.components(separatedBy: "<button").count >= 4,
                                 "Simplification must preserve all three required buttons")
                    precondition(!answer.contains("eslint-disable"), "Simple answer must keep correct Effect dependencies")
                    let fences = answer.components(separatedBy: "\n").filter { $0.hasPrefix("```") }
                    precondition(fences.count == 2, "Single-file demo must contain one final version, not multiple revisions")
                }
                else if index == 0 { precondition(guidance.contains("代码框") || guidance.contains("编辑器")) }
                else { precondition(guidance.contains("src/App.tsx") && (guidance.contains("新建") || guidance.contains("修改"))) }
                print("PASS: live \(simple ? "simple stopwatch" : "writing guidance") fixture \(index + 1)\n" + answer + "\n")
            }
        }

        if CommandLine.arguments.contains("--live") {
            // Deliberately send only a generated fixture, never the user's desktop.
            let image = NSImage(size: NSSize(width: 1400, height: 900))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1400, height: 900).fill()
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 30), .foregroundColor: NSColor.black]
            ("Browser  |  Search  |  News  |  Calendar\n\nQuestion 17: Solve 3x + a = b.\nThe values of a and b are on the next page.\n\nSidebar: weather, settings, unrelated chat." as NSString)
                .draw(in: NSRect(x: 60, y: 100, width: 1280, height: 700), withAttributes: attributes)
            image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(x: 0, y: 0, width: 1400, height: 900).fill()
            ("Browser | Question 17 (continued)\n\na = 7, b = 22.\nOptions: A. 3   B. 4   C. 5   D. 6\n\nUnrelated sidebar: calendar, news." as NSString)
                .draw(in: NSRect(x: 60, y: 100, width: 1280, height: 700), withAttributes: attributes)
            image.unlockFocus()
            let secondJPEG = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .jpeg, properties: [.compressionFactor: 0.9])!
            let defaults = UserDefaults.standard.persistentDomain(forName: "com.eli.CopilotNative")!
            let live = AIConfiguration(endpoint: URL(string: defaults["remoteAIEndpoint"] as! String)!,
                                       model: defaults["remoteAIModel"] as! String, apiKey: defaults["remoteAIApiKey"] as! String)
            let answer = try await collect(ChatCompletionClient().streamScreenshotAnswer(imageJPEGs: [jpeg, secondJPEG], configuration: live, screenshotImageCounts: [1, 1]))
            precondition(answer.contains("5"), "Vision answer did not solve the fixture")
            print("PASS: live vision combined two incomplete synthetic screens and solved the question\n" + answer)
        }
    }
}
