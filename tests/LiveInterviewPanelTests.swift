import AppKit
import Foundation
import SwiftData

actor ExtractionProbe {
    var attempts = 0
    let failures: Int
    init(failures: Int) { self.failures = failures }
    func extract(_ segments: [InterviewTranscriptSegment]) throws -> InterviewQuestionDecision {
        attempts += 1
        if attempts <= failures { throw SpeechError.message("synthetic transient failure") }
        return .init(action: .answer, question: "React是什么", consumed_ids: segments.map(\.id))
    }
}

// Keep these lifecycle tests offline; production source validation and retrieval
// are exercised by test-interview-knowledge.sh.
actor LocalKnowledgeEmbedding {
    static let modelID = "test-unavailable"
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws { throw AIClientError.invalidResponse }
    func embed(_ texts: [String], isQuery: Bool = false) async throws -> [[Float]] { throw AIClientError.invalidResponse }
}

@main
struct LiveInterviewPanelTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        precondition(NSApp.activationPolicy() == .accessory)
        let suite = "live-panel-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechSettings(defaults: defaults)
        speech.apiKey = ""
        let settings = RemoteAISettings(defaults: defaults, loadKey: { "" })
        let knowledge = InterviewKnowledgeBase()
        let live = LiveInterviewController()
        live.configure(speech: speech, ai: settings, knowledge: knowledge)
        let owner = LiveInterviewPanelController(controller: live, speech: speech, registerShortcuts: false)
        let screen = ScreenQuestionController(settings: settings, registerShortcuts: false)
        let screenOwner = ScreenAnswerPanelController(controller: screen, registerShortcuts: false)
        defer { owner.shutdown(); screenOwner.shutdown(); screen.shutdown(); live.shutdown() }
        let keyWindow = NSApp.keyWindow
        let panel = owner.preparePanel()
        precondition(!panel.isVisible && panel.sharingType == .none)
        precondition(!panel.canBecomeKey && !panel.canBecomeMain && panel.styleMask.contains(.nonactivatingPanel))
        precondition(panel.level == .floating && !panel.hidesOnDeactivate && !panel.isReleasedWhenClosed)
        precondition(NSApp.keyWindow === keyWindow)
        UserDefaults.standard.set(false, forKey: ScreenCapturePrivacy.defaultsKey)
        defer { UserDefaults.standard.removeObject(forKey: ScreenCapturePrivacy.defaultsKey) }
        panel.sharingType = .readOnly
        let child = NSPanel(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        panel.addChildWindow(child, ordered: .above)
        child.sharingType = .readOnly
        ScreenCapturePrivacy.applyToAllWindows()
        precondition(panel.sharingType == .none && child.sharingType == .none)
        panel.removeChildWindow(child)
        child.close()
        live.questionEdit = "第一题：介绍项目"
        live.isEditing = true
        owner.perform(.answer)
        precondition(live.turns.count == 1 && live.selectedTurn?.state == .needsConfiguration)
        live.questionEdit = String(repeating: "第二题：请解释项目的状态和组件之间如何共享数据。", count: 100)
        live.isEditing = true
        owner.perform(.answer)
        precondition(live.turns.count == 2 && live.selectedIndex == 1)
        owner.perform(.previous)
        precondition(live.selectedIndex == 0 && !live.canSelectPrevious && live.canSelectNext)
        owner.perform(.previous)
        precondition(live.selectedIndex == 0)
        owner.perform(.next)
        owner.perform(.next)
        precondition(live.selectedIndex == 1 && !live.canSelectNext)
        owner.perform(.retry)
        precondition(live.turns.count == 2 && live.selectedTurn?.state == .needsConfiguration)
        let wasAutomatic = speech.automaticAnswers
        owner.perform(.automatic)
        precondition(speech.automaticAnswers != wasAutomatic)
        owner.perform(.automatic)
        precondition(speech.automaticAnswers == wasAutomatic)
        owner.perform(.listen)
        precondition(live.status == .failed("请先填写语音 API Key"), "Unconfigured shortcut must not start recording")
        live.questionEdit = "待忽略文字"
        live.isEditing = true
        owner.perform(.ignore)
        precondition(!live.hasPendingQuestion && !live.isEditing && live.turns.count == 2)

        // Exercise real window visibility and scroll routing outside the visible desktop.
        panel.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        owner.beforeEnable = { screenOwner.disable() }
        screenOwner.routeScroll = { direction in owner.routeScroll(direction) }
        owner.enable()
        precondition(owner.isEnabled && panel.isVisible && panel.sharingType == .none)
        precondition(NSApp.keyWindow === keyWindow)
        panel.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        panel.contentView?.layoutSubtreeIfNeeded()
        precondition(owner.scroll.view != nil)
        screenOwner.handleScroll(1)
        precondition(owner.scroll.view!.contentView.bounds.minY > 0)
        owner.toggle()
        precondition(owner.isEnabled && !panel.isVisible && live.turns.count == 2)
        precondition(owner.routeScroll(1), "Hidden interview mode must consume arrows instead of scrolling screenshot panel")
        owner.toggle()
        precondition(panel.isVisible && live.turns.count == 2)
        var returned = false
        owner.returnToMainWindow = { owner.disable(); returned = true }
        owner.perform(.mainWindow)
        precondition(returned && !owner.isEnabled && !panel.isVisible && live.turns.count == 2)
        precondition(!owner.routeScroll(1))
        // Closing the panel must not release the shared interview controller or history.
        panel.close()
        owner.enable()
        precondition(panel.isVisible && live.turns.count == 2)
        precondition(NSApp.keyWindow === keyWindow)
        precondition(Set(LiveInterviewPanelController.Action.allCases.map(\.keyCode)).count == LiveInterviewPanelController.Action.allCases.count)
        try await testReliability()
        print("PASS: accessory activation policy; protected nonactivating panel and child; shared interview history, navigation, retry, offline listening guard, automatic-answer toggle, ignore, scroll routing and hide/reopen lifecycle")
    }

    @MainActor static func testReliability() async throws {
        let followUp = [InterviewTranscriptSegment(id: 18740, text: "嗯，那你这几个页面里哪个是开发难度相对高一点的？")]
        for ids in ["[18740]", "[\"18740\"]"] {
            let decision = try InterviewQuestionExtractor.decodeDecision("```json\n{\"action\":\"answer\",\"question\":\"哪个页面开发难度高？\",\"consumed_ids\":\(ids)}\n```", segments: followUp)
            precondition(decision.action == .answer && decision.consumed_ids == [18740])
        }
        for ids in ["[\"unknown\"]", "[\"18740.5\"]", "[18740.5]", "[true]", "[null]", "[\"99999\"]", "[]"] {
            do {
                _ = try InterviewQuestionExtractor.decodeDecision("{\"action\":\"answer\",\"question\":\"哪个页面开发难度高？\",\"consumed_ids\":\(ids)}", segments: followUp)
                preconditionFailure("Invalid or unknown IDs must not consume transcript: " + ids)
            } catch {
                precondition(error.localizedDescription.contains("问题分析"))
            }
        }
        let mixed = try InterviewQuestionExtractor.decodeDecision("{\"action\":\"ignore\",\"question\":\"\",\"consumed_ids\":[0,\"18740\"]}", segments: [.init(id: 0, text: "你好"), followUp[0]])
        precondition(mixed.consumed_ids == [0, 18740])
        let container = try ModelContainer(for: InterviewPackage.self, InterviewCapsule.self, QuestionAnswer.self,
                                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let library = try QuestionLibrary(container: container)
        let capsule = library.capsules.first!
        let introduction = "我是测试同学，以下为自己保存的介绍原文。"
        try library.add(question: "自我介绍", answer: introduction, capsuleID: capsule.id)
        try library.add(question: "React是什么", answer: "测试题库中的 React 答案", capsuleID: capsule.id)
        for query in ["自我介绍", "你先来一个自我介绍吧。", "你好，能听见吗？请做一下自我介绍。", "介绍一下你自己"] {
            precondition(library.interviewMatch(query, preferredScope: nil)?.answer == introduction)
        }
        for query in ["你刚才自我介绍里提到什么", "请用英语自我介绍", "请做一分钟自我介绍", "我简单介绍一下自己", "请自我介绍然后解释闭包"] {
            precondition(!QuestionSearchIndex.isIntroductionRequest(query), query)
            precondition(library.interviewMatch(query, preferredScope: nil) == nil)
        }
        precondition(InterviewQuestionExtractor.localDecision(segments: [.init(id: 0, text: "闭包是什么？"), .init(id: 1, text: "你先自我介绍")]) == nil)
        let alternative = try library.addPackage(name: "其他版本")
        let alternativeCapsule = library.capsules(in: alternative.id).first!
        try library.add(question: "自我介绍", answer: "另一个版本", capsuleID: alternativeCapsule.id)
        precondition(library.interviewMatch("请自我介绍", preferredScope: nil) == nil)
        precondition(library.interviewMatch("请自我介绍", preferredScope: .capsule(capsule.id))?.answer == introduction)

        let suite = "live-reliability-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let speech = SpeechSettings(defaults: defaults)
        speech.automaticAnswers = true
        let settings = RemoteAISettings(defaults: defaults, loadKey: { "" })
        let knowledge = InterviewKnowledgeBase()
        func makeLive(_ probe: ExtractionProbe? = nil) -> LiveInterviewController {
            let live: LiveInterviewController
            if let probe {
                live = LiveInterviewController(analysisRetryDelay: .milliseconds(20), extractQuestion: { segments, _, _ in
                    try await probe.extract(segments)
                })
            } else { live = LiveInterviewController() }
            live.configure(speech: speech, ai: settings, knowledge: knowledge)
            live.configureLibrary(library, scope: .capsule(capsule.id))
            return live
        }
        func result(_ text: String, _ start: Int, definite: Bool = true) -> SpeechRecognitionResult {
            .init(text: nil, utterances: [.init(text: text, start_time: start, end_time: start + 100, definite: definite)])
        }
        let local = makeLive()
        defer { local.shutdown() }
        local.receive(result("你先来一个自我介绍吧。", 0, definite: false), allowStopped: true)
        precondition(local.turns.isEmpty)
        local.receive(result("你先来一个自我介绍吧。", 0), allowStopped: true)
        precondition(local.selectedTurn?.answer == introduction && local.selectedTurn?.state == .complete)
        precondition(local.selectedTurn?.savedQuestionTitle == "自我介绍" && local.draft.isEmpty)
        // A later partial cannot revert a confirmed segment and submit it twice.
        local.receive(result("你先来一个", 0, definite: false), allowStopped: true)
        precondition(local.turns.count == 1)

        let tail = makeLive()
        defer { tail.shutdown() }
        tail.receive(result("前半句", 0), allowStopped: true)
        tail.receive(result("后半句", 100), allowStopped: true)
        precondition(tail.draft == "前半句后半句")

        // Configuration is fake: all extraction is injected and all answers are local.
        settings.endpointText = "https://example.invalid/v1/chat/completions"
        settings.modelText = "offline-test"
        settings.apiKey = "synthetic-key"
        try settings.save(defaults: defaults, saveKey: { _ in })
        let quotedID = LiveInterviewController(extractQuestion: { segments, _, _ in
            try InterviewQuestionExtractor.decodeDecision("{\"action\":\"answer\",\"question\":\"React是什么\",\"consumed_ids\":[\"18740\"]}", segments: segments)
        })
        quotedID.configure(speech: speech, ai: settings, knowledge: knowledge)
        quotedID.configureLibrary(library, scope: .capsule(capsule.id))
        defer { quotedID.shutdown() }
        quotedID.receive(result(followUp[0].text, 18740), allowStopped: true)
        for _ in 0..<50 {
            if quotedID.selectedTurn?.state == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        precondition(quotedID.selectedTurn?.state == .complete && quotedID.draft.isEmpty, "Quoted timestamp ID must submit and consume the follow-up")
        let retryProbe = ExtractionProbe(failures: 2)
        let retry = makeLive(retryProbe)
        defer { retry.shutdown() }
        retry.receive(result("React是什么", 0), allowStopped: true)
        for _ in 0..<100 {
            if retry.selectedTurn?.state == .complete { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let attempts = await retryProbe.attempts
        precondition(attempts == 3 && retry.selectedTurn?.answer == "测试题库中的 React 答案", "Retry must work without new audio callbacks")

        let failureProbe = ExtractionProbe(failures: 99)
        let failed = makeLive(failureProbe)
        defer { failed.shutdown() }
        failed.receive(result("React是什么", 0), allowStopped: true)
        for _ in 0..<100 {
            if failed.questionAnalysisStatus.contains("连续失败") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let failures = await failureProbe.attempts
        precondition(failures == 3 && failed.turns.isEmpty && failed.draft == "React是什么")
        precondition(failed.questionAnalysisStatus.contains("⌃⌥⌘A"))
        failed.submit()
        precondition(failed.selectedTurn?.state == .complete && failed.draft.isEmpty)

        let cancelProbe = ExtractionProbe(failures: 99)
        let cancelled = makeLive(cancelProbe)
        defer { cancelled.shutdown() }
        cancelled.receive(result("React是什么", 0), allowStopped: true)
        cancelled.discardDraft()
        try await Task.sleep(for: .milliseconds(250))
        let cancelledAttempts = await cancelProbe.attempts
        precondition(cancelledAttempts == 0 && cancelled.turns.isEmpty && cancelled.draft.isEmpty)
        let backoffProbe = ExtractionProbe(failures: 99)
        let backoff = LiveInterviewController(analysisRetryDelay: .seconds(1), extractQuestion: { segments, _, _ in
            try await backoffProbe.extract(segments)
        })
        backoff.configure(speech: speech, ai: settings, knowledge: knowledge)
        backoff.configureLibrary(library, scope: .capsule(capsule.id))
        defer { backoff.shutdown() }
        backoff.receive(result("React是什么", 0), allowStopped: true)
        for _ in 0..<50 {
            if backoff.questionAnalysisStatus.contains("正在重试") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        backoff.submit()
        try await Task.sleep(for: .milliseconds(1_100))
        let backoffAttempts = await backoffProbe.attempts
        precondition(backoffAttempts == 1 && backoff.turns.count == 1 && backoff.selectedTurn?.state == .complete)
        print("PASS: verbatim saved introduction without API; scoped versions; constrained questions excluded; partial/final and tail snapshots; autonomous bounded retries; manual fallback; cancellation; no microphone/network")
    }
}
