import AppKit
import Carbon
import Observation
import SwiftUI

@MainActor
@Observable
final class AppPresentation {
    var showingLiveInterview = false
    var showingScreenQuestions = false

    func showInterview() {
        showingScreenQuestions = false
        showingLiveInterview = true
    }
}

@MainActor
@Observable
final class LiveInterviewPanelController {
    enum Action: UInt32, CaseIterable {
        case toggle = 1, listen, answer, stopAnswer, retry, automatic, previous, next, mainWindow, ignore
        var keyCode: Int {
            switch self {
            case .toggle: kVK_ANSI_I
            case .listen: kVK_ANSI_L
            case .answer: kVK_ANSI_A
            case .stopAnswer: kVK_ANSI_X
            case .retry: kVK_ANSI_R
            case .automatic: kVK_ANSI_P
            case .previous: kVK_LeftArrow
            case .next: kVK_RightArrow
            case .mainWindow: kVK_ANSI_M
            case .ignore: kVK_ANSI_D
            }
        }
        var help: String {
            switch self {
            case .toggle: "⌃⌥⌘I　打开／收起面试浮窗"
            case .listen: "⌃⌥⌘L　开始／停止监听"
            case .answer: "⌃⌥⌘A　立即回答待提交问题"
            case .stopAnswer: "⌃⌥⌘X　停止本次回答生成（仍监听）"
            case .retry: "⌃⌥⌘R　重新生成当前题答案"
            case .automatic: "⌃⌥⌘P　暂停／恢复自动回答（仍监听）"
            case .previous: "⌃⌥⌘←　查看上一题"
            case .next: "⌃⌥⌘→　查看下一题"
            case .mainWindow: "⌃⌥⌘M　返回主窗口"
            case .ignore: "⌃⌥⌘D　忽略当前待提交问题"
            }
        }
    }
    static let shortcutHelp = "⌃=Control　⌥=Option　⌘=Command\n⌃⌥⌘Space　显示／收起当前窗口或浮窗\n⌃⌥⌘↑／↓　滚动当前浮窗答案\n" + Action.allCases.map(\.help).joined(separator: "\n")

    private(set) var isEnabled = false
    private(set) var shortcutError: String?
    @ObservationIgnored var beforeEnable: (() -> Void)?
    @ObservationIgnored var hideMainWindow: (() -> Void)?
    @ObservationIgnored var returnToMainWindow: (() -> Void)?
    @ObservationIgnored var routeHorizontal: ((Int) -> Bool)?
    @ObservationIgnored let scroll = AnswerScrollProxy()
    @ObservationIgnored private let controller: LiveInterviewController
    @ObservationIgnored private let speech: SpeechSettings
    @ObservationIgnored private var panel: ProtectedAnswerPanel?
    @ObservationIgnored private var hotKeys: [EventHotKeyRef] = []
    @ObservationIgnored private var handler: EventHandlerRef?

    init(controller: LiveInterviewController, speech: SpeechSettings, registerShortcuts: Bool = true) {
        self.controller = controller
        self.speech = speech
        guard registerShortcuts else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x43504C49,
                  let action = Action(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<LiveInterviewPanelController>.fromOpaque(context).takeUnretainedValue().perform(action)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard result == noErr else { shortcutError = "面试快捷键监听失败（\(result)）"; return }
        var errors: [String] = []
        for action in Action.allCases {
            var key: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(action.keyCode), UInt32(controlKey | optionKey | cmdKey),
                                             EventHotKeyID(signature: 0x43504C49, id: action.rawValue),
                                             GetApplicationEventTarget(), 0, &key)
            if status == noErr, let key { hotKeys.append(key) }
            else { errors.append("\(action.help) 被占用或无法注册（\(status)）") }
        }
        if !errors.isEmpty { shortcutError = errors.joined(separator: "\n") }
    }

    func perform(_ action: Action) {
        switch action {
        case .toggle:
            if isEnabled { toggle() } else { enable() }
        case .listen: controller.toggleListening()
        case .answer: controller.submit()
        case .stopAnswer: controller.cancelAnswer()
        case .retry: controller.retrySelectedAnswer()
        case .automatic: speech.automaticAnswers.toggle(); controller.automaticAnswersChanged()
        case .previous: if routeHorizontal?(-1) != true { controller.selectTurn(offset: -1) }
        case .next: if routeHorizontal?(1) != true { controller.selectTurn(offset: 1) }
        case .mainWindow: returnToMainWindow?()
        case .ignore: controller.discardDraft()
        }
    }

    func preparePanel() -> ProtectedAnswerPanel {
        if let panel { return panel }
        let panel = ProtectedAnswerPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 700),
                                         styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                                         backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("liveInterviewAnswerPanel")
        panel.sharingType = .none
        panel.title = "实时面试答案"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 360, height: 420)
        panel.setFrameAutosaveName("LiveInterviewAnswerPanel")
        if !panel.setFrameUsingName("LiveInterviewAnswerPanel"),
           let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            let area = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            let size = NSSize(width: min(450, area.width), height: min(700, area.height))
            panel.setFrame(NSRect(x: area.maxX - size.width, y: area.maxY - size.height,
                                  width: size.width, height: size.height), display: false)
        }
        panel.contentView = NSHostingView(rootView: FloatingInterviewAnswer(controller: controller, speech: speech, owner: self))
        ScreenCapturePrivacy.apply(to: panel)
        self.panel = panel
        return panel
    }

    func enable() {
        beforeEnable?()
        isEnabled = true
        show()
    }

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
        else { show() }
    }

    private func show() {
        let panel = preparePanel()
        ScreenCapturePrivacy.apply(to: panel)
        NSApp.unhideWithoutActivation()
        hideMainWindow?()
        panel.orderFrontRegardless()
    }

    /// Return true even when hidden: scrolling must not leak into the other answer mode.
    func routeScroll(_ direction: Int) -> Bool {
        guard isEnabled else { return false }
        if panel?.isVisible == true { scroll.scroll(direction) }
        return true
    }

    func disable() { panel?.orderOut(nil); isEnabled = false }

    func shutdown() {
        disable()
        for key in hotKeys { UnregisterEventHotKey(key) }
        hotKeys = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }
}

private struct FloatingInterviewAnswer: View {
    let controller: LiveInterviewController
    let speech: SpeechSettings
    let owner: LiveInterviewPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            controls.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let turn = controller.selectedTurn {
                        Text(turn.question).font(.headline).textSelection(.enabled)
                        if let title = turn.savedQuestionTitle { Text("来自已保存题库 · " + title).font(.caption).foregroundStyle(.secondary) }
                        if [.waiting, .retrieving, .streaming].contains(turn.state) {
                            Text(turn.state == .streaming ? "正在生成回答…" : "正在检索本地资料…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if case .failed(let message) = turn.state { Text(message).font(.caption).foregroundStyle(.red) }
                        if turn.state == .needsConfiguration { Text("请在主窗口的设置中配置回答模型").foregroundStyle(.orange) }
                        if !turn.answer.isEmpty { MarkdownDocumentView(markdown: turn.answer) }
                    } else {
                        Text("等待面试问题").font(.headline)
                        Text("先在主窗口选择音源、会议应用和项目背景，再按 ⌃⌥⌘L 开始监听。隐藏浮窗不会停止监听或清空问答。")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(AnswerScrollBridge(proxy: owner.scroll))
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("⌃⌥⌘Space 显隐 · ⌃⌥⌘↑／↓ 滚动 · ⌃⌥⌘←／→ 切题\n⌃⌥⌘L 监听开关 · ⌃⌥⌘A 立即回答 · ⌃⌥⌘M 主窗口")
                DisclosureGroup("全部快捷键") { Text(LiveInterviewPanelController.shortcutHelp).frame(maxWidth: .infinity, alignment: .leading) }
                if let error = owner.shortcutError { Text(error).foregroundStyle(.red) }
            }
            .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.selectedTurnID) { owner.scroll.reset() }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(controller.status.title).font(.caption).foregroundStyle(controller.isActive ? .green : .secondary)
                Spacer()
                Button(controller.isActive ? "停止监听" : "开始监听") { owner.perform(.listen) }
                    .disabled(controller.status == .stopping).help("⌃⌥⌘L")
                Button("主窗口") { owner.perform(.mainWindow) }.help("⌃⌥⌘M")
                Button { owner.toggle() } label: { Image(systemName: "minus") }.help("收起浮窗，继续监听 · ⌃⌥⌘Space")
            }
            HStack {
                Button { owner.perform(.previous) } label: { Image(systemName: "chevron.left") }
                    .disabled(!controller.canSelectPrevious).help("上一题 · ⌃⌥⌘←")
                Text(controller.selectedIndex.map { "\($0 + 1) / \(controller.turns.count)" } ?? "0 / 0").monospacedDigit()
                Button { owner.perform(.next) } label: { Image(systemName: "chevron.right") }
                    .disabled(!controller.canSelectNext).help("下一题 · ⌃⌥⌘→")
                Spacer()
                Button("立即回答") { owner.perform(.answer) }.disabled(!controller.hasPendingQuestion).help("⌃⌥⌘A")
                Button("重答") { owner.perform(.retry) }.disabled(controller.selectedTurn == nil).help("⌃⌥⌘R")
                Button("停止生成") { owner.perform(.stopAnswer) }.help("仍继续监听 · ⌃⌥⌘X")
            }
            Text(speech.automaticAnswers ? "自动回答开启 · ⌃⌥⌘P 暂停" : "自动回答暂停 · ⌃⌥⌘P 恢复")
                .foregroundStyle(.secondary)
            if speech.automaticAnswers { Text(controller.questionAnalysisStatus).foregroundStyle(.secondary) }
            if !controller.draft.isEmpty { Text("待提交：" + controller.draft).lineLimit(3).foregroundStyle(.secondary) }
            if let notice = controller.notice { Text(notice).foregroundStyle(.orange) }
            if case .failed(let message) = controller.status { Text(message).foregroundStyle(.red) }
        }
        .font(.caption).buttonStyle(.borderless)
    }
}
