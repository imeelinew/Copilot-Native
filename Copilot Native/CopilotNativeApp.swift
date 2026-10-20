import AppKit
import Carbon
import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class MainWindowShortcut {
    private(set) var error: String?
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored var answerPanel: ScreenAnswerPanelController?
    @ObservationIgnored var interviewPanel: LiveInterviewPanelController?
    @ObservationIgnored var openNewWindow: (() -> Void)?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var closeObserver: NSObjectProtocol?

    init() {
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] notification in
            guard let closing = notification.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                if closing === self?.window {
                    self?.window = nil
                }
            }
        }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x4350574E, identifier.id == 1 else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                Unmanaged<MainWindowShortcut>.fromOpaque(context).takeUnretainedValue().toggle()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            error = "唤起窗口快捷键监听失败（\(installed)）"
            return
        }
        let registered = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey | cmdKey),
                                            EventHotKeyID(signature: 0x4350574E, id: 1), GetApplicationEventTarget(), 0, &hotKey)
        if registered != noErr { error = "唤起窗口快捷键 ⌃⌥⌘Space 被占用（\(registered)）" }
    }

    func toggle() {
        if let interviewPanel, interviewPanel.isEnabled {
            interviewPanel.toggle()
            return
        }
        if let answerPanel, answerPanel.isEnabled {
            answerPanel.toggle()
            return
        }
        toggleMainWindow()
    }

    func toggleMainWindow() {
        if NSApp.isActive, !NSApp.isHidden,
           let window, window.isVisible, !window.isMiniaturized {
            NSApp.hide(nil)
            return
        }
        showMainWindow()
    }

    func showMainWindow() {
        if let window {
            ScreenCapturePrivacy.apply(to: window)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openNewWindow?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func shutdown() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        hotKey = nil
        handler = nil
        closeObserver = nil
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?
    var onReopen: (() -> Void)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        onReopen?()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) { onTerminate?() }

    func applicationWillUpdate(_ notification: Notification) {
        // Include newly created sheets, panels, and framework-owned windows.
        ScreenCapturePrivacy.applyToAllWindows()
    }
}

/// Set the policy as soon as SwiftUI attaches its content, before first display.
private struct CapturePrivacyWindowBridge: NSViewRepresentable {
    let shortcut: MainWindowShortcut
    @Environment(\.openWindow) private var openWindow

    func makeNSView(context: Context) -> PrivacyView {
        let view = PrivacyView()
        view.onAttach = { [weak shortcut] window in shortcut?.window = window }
        shortcut.openNewWindow = { openWindow(id: "main") }
        return view
    }

    func updateNSView(_ nsView: PrivacyView, context: Context) {
        if let window = nsView.window { ScreenCapturePrivacy.apply(to: window) }
    }

    final class PrivacyView: NSView {
        var onAttach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window {
                ScreenCapturePrivacy.apply(to: window)
                onAttach?(window)
            }
        }
    }
}

@MainActor
@Observable
final class AppBootstrap {
    let settings = RemoteAISettings()
    let speech = SpeechSettings()
    let knowledge = InterviewKnowledgeBase()
    let settingsWindow: AISettingsWindowController
    let answerPanel: ScreenAnswerPanelController
    let screenQuestions: ScreenQuestionController
    let live = LiveInterviewController()
    let presentation = AppPresentation()
    let interviewPanel: LiveInterviewPanelController
    let windowShortcut = MainWindowShortcut()
    let library: QuestionLibrary?
    let startupError: String?

    init() {
        settingsWindow = AISettingsWindowController(settings: settings, speech: speech)
        screenQuestions = ScreenQuestionController(settings: settings)
        answerPanel = ScreenAnswerPanelController(controller: screenQuestions)
        interviewPanel = LiveInterviewPanelController(controller: live, speech: speech)
        live.configure(speech: speech, ai: settings, knowledge: knowledge)
        windowShortcut.answerPanel = answerPanel
        windowShortcut.interviewPanel = interviewPanel
        answerPanel.hideMainWindow = { [weak windowShortcut] in windowShortcut?.window?.orderOut(nil) }
        interviewPanel.hideMainWindow = { [weak windowShortcut] in windowShortcut?.window?.orderOut(nil) }
        interviewPanel.beforeEnable = { [weak answerPanel] in answerPanel?.disable() }
        answerPanel.routeScroll = { [weak interviewPanel] direction in interviewPanel?.routeScroll(direction) ?? false }
        live.showFloatingAnswer = { [weak interviewPanel] in interviewPanel?.enable() }
        screenQuestions.showFloatingAnswer = { [weak answerPanel, weak interviewPanel] in
            interviewPanel?.disable()
            answerPanel?.enable()
        }
        interviewPanel.returnToMainWindow = { [weak interviewPanel, weak answerPanel, weak windowShortcut, weak presentation] in
            interviewPanel?.disable()
            answerPanel?.disable()
            presentation?.showInterview()
            windowShortcut?.showMainWindow()
        }
        screenQuestions.returnToMainWindow = { [weak answerPanel, weak interviewPanel, weak windowShortcut, weak presentation] in
            answerPanel?.disable()
            interviewPanel?.disable()
            presentation?.showingScreenQuestions = true
            windowShortcut?.showMainWindow()
        }
        do {
            let container: ModelContainer
            if CommandLine.arguments.contains("-uiTesting") {
                container = try ModelContainer(
                    for: QuestionAnswer.self, InterviewPackage.self, InterviewCapsule.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } else {
                container = try ModelContainer(
                    for: QuestionAnswer.self,
                    InterviewPackage.self,
                    InterviewCapsule.self
                )
            }
            let loadedLibrary = try QuestionLibrary(container: container)
            library = loadedLibrary
            live.configureLibrary(loadedLibrary)
            startupError = nil
        } catch {
            library = nil
            startupError = error.localizedDescription
        }
    }
}

@main
struct CopilotNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(ScreenCapturePrivacy.defaultsKey) private var excludeFromScreenSharing = true
    @State private var bootstrap = AppBootstrap()
    @State private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup("Copilot Native", id: "main") {
            Group {
                if let library = bootstrap.library {
                    MainWindowView(
                        library: library,
                        settings: bootstrap.settings,
                        speech: bootstrap.speech,
                        knowledge: bootstrap.knowledge,
                        screenQuestions: bootstrap.screenQuestions,
                        openSettings: { bootstrap.settingsWindow.show() },
                        live: bootstrap.live,
                        presentation: bootstrap.presentation
                    )
                } else {
                    ContentUnavailableView(
                        "无法打开题库",
                        systemImage: "externaldrive.badge.exclamationmark",
                        description: Text(bootstrap.startupError ?? "本地数据不可用")
                    )
                    .frame(minWidth: 600, minHeight: 400)
                }
            }
            .background(CapturePrivacyWindowBridge(shortcut: bootstrap.windowShortcut))
            .task {
                appDelegate.onTerminate = {
                    bootstrap.screenQuestions.shutdown()
                    bootstrap.windowShortcut.shutdown()
                    bootstrap.answerPanel.shutdown()
                    bootstrap.interviewPanel.shutdown()
                    bootstrap.live.shutdown()
                }
                appDelegate.onReopen = {
                    bootstrap.answerPanel.disable()
                    bootstrap.interviewPanel.disable()
                    bootstrap.windowShortcut.showMainWindow()
                }
            }
            .onChange(of: excludeFromScreenSharing) {
                ScreenCapturePrivacy.applyToAllWindows()
            }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("搜索题库") {
                    NotificationCenter.default.post(name: .focusQuestionSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    bootstrap.settingsWindow.show()
                }
                .keyboardShortcut(",")
            }
            CommandGroup(after: .appSettings) {
                CheckForUpdatesView(updater: updater)
                Divider()
                Toggle("屏幕共享隐藏（实验性）", isOn: $excludeFromScreenSharing)
                    .help("请求录屏和共享软件排除本应用窗口；须在腾讯会议接收端验证是否生效。")
                Button("显示／收起窗口（⌃⌥⌘Space）") { bootstrap.windowShortcut.toggle() }
                Button("显示主窗口") {
                    bootstrap.answerPanel.disable()
                    bootstrap.interviewPanel.disable()
                    bootstrap.windowShortcut.showMainWindow()
                }
                Button("实时面试浮窗（⌃⌥⌘I）") { bootstrap.interviewPanel.perform(.toggle) }
                if let error = bootstrap.interviewPanel.shortcutError { Text(error) }
                if let error = bootstrap.windowShortcut.error {
                    Text(error)
                }
            }
        }
    }
}
