import AppKit
import Foundation

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
        print("PASS: accessory activation policy; protected nonactivating panel and child; shared interview history, navigation, retry, offline listening guard, automatic-answer toggle, ignore, scroll routing and hide/reopen lifecycle")
    }
}
