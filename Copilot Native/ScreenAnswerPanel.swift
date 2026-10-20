import AppKit
import Carbon
import Observation
import SwiftUI

/// The answer panel never accepts keyboard focus from the user's editor/browser.
final class ProtectedAnswerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AnswerScrollProxy {
    weak var view: NSScrollView?

    func scroll(_ direction: Int) {
        guard let view, let document = view.documentView else { return }
        let clip = view.contentView
        let delta = CGFloat(direction) * clip.bounds.height * 0.7 * (document.isFlipped ? 1 : -1)
        let maximum = max(0, document.bounds.height - clip.bounds.height)
        clip.scroll(to: CGPoint(x: clip.bounds.minX, y: min(maximum, max(0, clip.bounds.minY + delta))))
        view.reflectScrolledClipView(clip)
    }

    func reset() {
        guard let view, let document = view.documentView else { return }
        let y = document.isFlipped ? 0 : max(0, document.bounds.height - view.contentView.bounds.height)
        view.contentView.scroll(to: CGPoint(x: 0, y: y))
        view.reflectScrolledClipView(view.contentView)
    }
}

struct AnswerScrollBridge: NSViewRepresentable {
    let proxy: AnswerScrollProxy

    func makeNSView(context: Context) -> Probe {
        let view = Probe()
        view.proxy = proxy
        return view
    }

    func updateNSView(_ nsView: Probe, context: Context) { nsView.connect() }

    final class Probe: NSView {
        weak var proxy: AnswerScrollProxy?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); connect() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); connect() }
        override func layout() { super.layout(); connect() }
        func connect() { if let enclosingScrollView { proxy?.view = enclosingScrollView } }
    }
}

@MainActor
@Observable
final class ScreenAnswerPanelController {
    private(set) var isEnabled = false
    private(set) var shortcutError: String?
    @ObservationIgnored var hideMainWindow: (() -> Void)?
    @ObservationIgnored var routeScroll: ((Int) -> Bool)?
    @ObservationIgnored private let controller: ScreenQuestionController
    @ObservationIgnored let scroll = AnswerScrollProxy()
    @ObservationIgnored let explanationScroll = AnswerScrollProxy()
    var scrollingExplanation = false
    @ObservationIgnored private var panel: ProtectedAnswerPanel?
    @ObservationIgnored private var upHotKey: EventHotKeyRef?
    @ObservationIgnored private var downHotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?

    init(controller: ScreenQuestionController, registerShortcuts: Bool = true) {
        self.controller = controller
        guard registerShortcuts else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4350414E, [1, 2].contains(identifier.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let owner = Unmanaged<ScreenAnswerPanelController>.fromOpaque(context).takeUnretainedValue()
                owner.handleScroll(identifier.id == 1 ? -1 : 1)
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { shortcutError = "答案滚动快捷键监听失败（\(installed)）"; return }
        let modifiers = UInt32(controlKey | optionKey | cmdKey)
        let up = RegisterEventHotKey(UInt32(kVK_UpArrow), modifiers, EventHotKeyID(signature: 0x4350414E, id: 1), GetApplicationEventTarget(), 0, &upHotKey)
        let down = RegisterEventHotKey(UInt32(kVK_DownArrow), modifiers, EventHotKeyID(signature: 0x4350414E, id: 2), GetApplicationEventTarget(), 0, &downHotKey)
        if up != noErr || down != noErr { shortcutError = "答案滚动快捷键 ⌃⌥⌘↑／↓ 被占用或无法注册" }
    }

    func handleScroll(_ direction: Int) {
        if routeScroll?(direction) == true { return }
        if isEnabled, panel?.isVisible == true { (scrollingExplanation ? explanationScroll : scroll).scroll(direction) }
    }

    /// Construct without ordering on screen, so capture policy precedes first display.
    func preparePanel() -> ProtectedAnswerPanel {
        if let panel { return panel }
        let panel = ProtectedAnswerPanel(contentRect: NSRect(x: 0, y: 0, width: 430, height: 900),
                                         styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
                                         backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("screenshotAnswerPanel")
        panel.sharingType = .none
        panel.title = "截图答案"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 320, height: 480)
        panel.setFrameAutosaveName("ScreenshotAnswerPanelSplit")
        if !panel.setFrameUsingName("ScreenshotAnswerPanelSplit") {
            let pointer = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main {
                let area = screen.visibleFrame.insetBy(dx: 16, dy: 16)
                let size = NSSize(width: min(430, area.width), height: area.height)
                panel.setFrame(NSRect(x: area.maxX - size.width, y: area.maxY - size.height, width: size.width, height: size.height), display: false)
            }
        }
        panel.contentView = NSHostingView(rootView: FloatingScreenshotAnswer(controller: controller, owner: self))
        ScreenCapturePrivacy.apply(to: panel)
        self.panel = panel
        return panel
    }

    func enable() {
        isEnabled = true
        hideMainWindow?()
        show()
    }

    func toggle() {
        if panel?.isVisible == true { panel?.orderOut(nil) }
        else { show() }
    }

    private func show() {
        let panel = preparePanel()
        // A user preference for ordinary windows must never unprotect this panel.
        ScreenCapturePrivacy.apply(to: panel)
        NSApp.unhideWithoutActivation()
        hideMainWindow?()
        panel.orderFrontRegardless()
    }

    func disable() {
        panel?.orderOut(nil)
        isEnabled = false
    }

    func shutdown() {
        disable()
        if let upHotKey { UnregisterEventHotKey(upHotKey) }
        if let downHotKey { UnregisterEventHotKey(downHotKey) }
        if let handler { RemoveEventHandler(handler) }
        upHotKey = nil
        downHotKey = nil
        handler = nil
        panel?.contentView = nil
        panel?.close()
        panel = nil
    }
}

private struct FloatingScreenshotAnswer: View {
    let controller: ScreenQuestionController
    let owner: ScreenAnswerPanelController

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("待发送 \(controller.pendingCount) 张 · 排错 \(controller.repairCount) 次").foregroundStyle(.secondary)
                Spacer()
                Button { controller.captureRegionScreenshot() } label: { Image(systemName: "crop") }
                    .help("区域截图 · ⌃⌥⌘4").accessibilityLabel("区域截图")
                Button("排错") { controller.captureErrorScreenshot() }
                    .disabled(!controller.hasSession || controller.isWorking || controller.isCapturingRepair)
                    .help("⌃⌥⌘E：截图报错并沿本题对话修复")
                Button("主窗口") { controller.returnToMainWindow?() }
                Button { owner.toggle() } label: { Image(systemName: "minus") }
                    .help("收起答案 · ⌃⌥⌘Space")
            }
            .buttonStyle(.borderless)
            .padding(12)
            Divider()
            ScreenshotAnswerNavigation(controller: controller).padding(.horizontal, 12).padding(.vertical, 6)
            VStack(alignment: .leading, spacing: 4) {
                Text(controller.status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                if let error = controller.captureError { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = controller.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
                if let error = owner.shortcutError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            .padding(.horizontal, 12).padding(.bottom, 6)
            ScreenshotAnswerSections(markdown: controller.displayedAnswer, isWorking: controller.isWorking, owner: owner)
            Divider()
            Text("⌃⌥⌘Space 显隐 · ⌃⌥⌘↑／↓ 滚动\n⌃⌥⌘S 全屏 · ⌃⌥⌘4 区域 · ⌃⌥⌘Return 发送\n⌃⌥⌘⌫ 清空待发送截图 · ⌃⌥⌘E 截图排错")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: controller.isWorking) { _, working in if working { owner.scroll.reset(); owner.explanationScroll.reset() } }
        .onChange(of: controller.selectedAnswerIndex) { _, _ in owner.scroll.reset(); owner.explanationScroll.reset() }
    }
}

struct ScreenshotAnswerParts: Equatable {
    let solution: String
    let explanation: String

    init(_ markdown: String) {
        var solutionLines: [String] = []
        var explanationLines: [String] = []
        var inExplanation = false
        var fence: String?
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let marker = String(trimmed.prefix(3))
                if fence == nil { fence = marker }
                else if fence == marker { fence = nil }
            } else if fence == nil {
                if !inExplanation && trimmed == "## 代码怎么讲" { inExplanation = true; continue }
                if !inExplanation && trimmed == "## 解题答案" { continue }
            }
            if inExplanation { explanationLines.append(line) }
            else { solutionLines.append(line) }
        }
        solution = solutionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        explanation = explanationLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ScreenshotAnswerSections: View {
    let markdown: String
    let isWorking: Bool
    var owner: ScreenAnswerPanelController? = nil

    var body: some View {
        let parts = ScreenshotAnswerParts(markdown)
        VSplitView {
            section(title: "解题答案", text: parts.solution, explanation: false,
                    placeholder: "解题代码和填写步骤会显示在这里。")
            section(title: "代码怎么讲", text: parts.explanation, explanation: true,
                    placeholder: isWorking ? "讲解生成后会显示在这里。" : "本轮暂无代码讲解。")
        }
    }

    private func section(title: String, text: String, explanation: Bool, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let owner {
                    Button(owner.scrollingExplanation == explanation ? "⌃⌥⌘↑／↓" : "快捷键滚动此区") {
                        owner.scrollingExplanation = explanation
                    }
                    .font(.caption).buttonStyle(.borderless)
                    .help("让上下滚动快捷键控制“\(title)”区域，不切换输入焦点")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                VStack(alignment: .leading) {
                    if text.isEmpty { Text(placeholder).foregroundStyle(.secondary) }
                    else { MarkdownDocumentView(markdown: text) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                .background {
                    if let owner { AnswerScrollBridge(proxy: explanation ? owner.explanationScroll : owner.scroll) }
                }
            }
        }
        .frame(minHeight: 100, maxHeight: .infinity)
    }
}

/// Capture exclusion is a request to the capture client, not a security guarantee.
@MainActor
enum ScreenCapturePrivacy {
    static let defaultsKey = "excludeWindowsFromScreenSharing"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }

    static func apply(to window: NSWindow) {
        let panelIDs = ["screenshotAnswerPanel", "liveInterviewAnswerPanel", "regionScreenshotSelector"]
        let protectedPanel = panelIDs.contains(window.identifier?.rawValue ?? "")
            || panelIDs.contains(window.parent?.identifier?.rawValue ?? "")
        let sharingType: NSWindow.SharingType = (isEnabled || protectedPanel) ? .none : .readOnly
        if window.sharingType != sharingType {
            window.sharingType = sharingType
        }
        for child in window.childWindows ?? [] {
            apply(to: child)
        }
    }

    static func applyToAllWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }
}

