import AppKit
import Carbon
import Observation
import ScreenCaptureKit
import SwiftUI

@MainActor
@Observable
final class ScreenQuestionController {
    static let shortcut = "⌃⌥⌘S"
    static let sendShortcut = "⌃⌥⌘Return"
    static let clearShortcut = "⌃⌥⌘⌫"
    static let debugShortcut = "⌃⌥⌘E"
    private(set) var sessionID: UUID?
    private(set) var repairCount = 0
    private(set) var isCapturingRepair = false
    var hasSession: Bool { sessionID != nil }
    @ObservationIgnored var showFloatingAnswer: (() -> Void)?
    @ObservationIgnored var returnToMainWindow: (() -> Void)?
    private(set) var answer = ""
    private(set) var status = "按 ⌃⌥⌘S 累积截图，按 ⌃⌥⌘Return 一起发送解题"
    private(set) var isWorking = false
    private(set) var shortcutError: String?
    private(set) var captureError: String?
    private(set) var pendingCaptureCount = 0
    private(set) var pendingShots: [[Data]] = []
    var pendingCount: Int { pendingShots.count + pendingCaptureCount }
    @ObservationIgnored private let settings: RemoteAISettings
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var captureTail: Task<Void, Never>?
    @ObservationIgnored private var captureGeneration = UUID()
    @ObservationIgnored private var inFlight: [[Data]] = []
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var sendHotKey: EventHotKeyRef?
    @ObservationIgnored private var clearHotKey: EventHotKeyRef?
    @ObservationIgnored private var debugHotKey: EventHotKeyRef?
    @ObservationIgnored private var history: [ScreenshotConversationMessage] = []
    @ObservationIgnored private var repairGeneration = UUID()
    @ObservationIgnored private var requestIsRepair = false
    @ObservationIgnored private var answerBeforeRequest = ""
    @ObservationIgnored private let conversationStream: @Sendable ([ScreenshotConversationMessage], AIConfiguration) -> AsyncThrowingStream<String, Error>
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let captureImages: @MainActor (CGDirectDisplayID) async throws -> [Data]
    @ObservationIgnored private let answerStream: @Sendable ([[Data]], AIConfiguration) -> AsyncThrowingStream<String, Error>

    init(settings: RemoteAISettings, registerShortcuts: Bool = true,
         captureImages: (@MainActor (CGDirectDisplayID) async throws -> [Data])? = nil,
         answerStream: @escaping @Sendable ([[Data]], AIConfiguration) -> AsyncThrowingStream<String, Error> = {
             ChatCompletionClient().streamScreenshotAnswer(imageJPEGs: $0.flatMap { $0 }, configuration: $1, screenshotImageCounts: $0.map { $0.count })
         },
         conversationStream: @escaping @Sendable ([ScreenshotConversationMessage], AIConfiguration) -> AsyncThrowingStream<String, Error> = {
             ChatCompletionClient().streamScreenshotConversation(messages: $0, configuration: $1)
         }) {
        self.conversationStream = conversationStream
        self.settings = settings
        self.captureImages = captureImages ?? Self.capture
        self.answerStream = answerStream
        guard registerShortcuts else { return }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  identifier.signature == 0x43505351, [1, 2, 3, 4].contains(identifier.id) else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated {
                let controller = Unmanaged<ScreenQuestionController>.fromOpaque(context).takeUnretainedValue()
                if identifier.id == 1 { controller.captureScreenshot() }
                else if identifier.id == 2 { controller.sendPending() }
                else if identifier.id == 3 { controller.clearPending() }
                else { controller.captureErrorScreenshot() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else {
            shortcutError = "全局快捷键监听失败（\(installed)）"
            return
        }
        let registered = RegisterEventHotKey(
            UInt32(kVK_ANSI_S), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x43505351, id: 1), GetApplicationEventTarget(), 0, &hotKey
        )
        if registered != noErr { shortcutError = "截图快捷键 ⌃⌥⌘S 注册失败（\(registered)）" }
        let sendRegistered = RegisterEventHotKey(
            UInt32(kVK_Return), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x43505351, id: 2), GetApplicationEventTarget(), 0, &sendHotKey
        )
        if sendRegistered != noErr {
            shortcutError = [shortcutError, "发送快捷键 ⌃⌥⌘Return 注册失败（\(sendRegistered)）"].compactMap { $0 }.joined(separator: "；")
        }
        let clearRegistered = RegisterEventHotKey(
            UInt32(kVK_Delete), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x43505351, id: 3), GetApplicationEventTarget(), 0, &clearHotKey
        )
        if clearRegistered != noErr {
            shortcutError = [shortcutError, "清空快捷键 ⌃⌥⌘⌫ 注册失败（\(clearRegistered)）"].compactMap { $0 }.joined(separator: "；")
        }
        let debugRegistered = RegisterEventHotKey(
            UInt32(kVK_ANSI_E), UInt32(controlKey | optionKey | cmdKey),
            EventHotKeyID(signature: 0x43505351, id: 4), GetApplicationEventTarget(), 0, &debugHotKey
        )
        if debugRegistered != noErr {
            shortcutError = [shortcutError, "排错快捷键 ⌃⌥⌘E 注册失败（\(debugRegistered)）"].compactMap { $0 }.joined(separator: "；")
        }
    }

    func shutdown() {
        cancel()
        clearPending()
        captureTail?.cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let sendHotKey { UnregisterEventHotKey(sendHotKey) }
        if let clearHotKey { UnregisterEventHotKey(clearHotKey) }
        if let debugHotKey { UnregisterEventHotKey(debugHotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        sendHotKey = nil
        clearHotKey = nil
        debugHotKey = nil
        handler = nil
        history = []
        sessionID = nil
    }

    func cancel() {
        generation = UUID()
        repairGeneration = UUID()
        let wasCapturing = isCapturingRepair
        isCapturingRepair = false
        task?.cancel()
        task = nil
        if isWorking {
            if !requestIsRepair { pendingShots.insert(contentsOf: inFlight, at: 0) }
            inFlight = []
            answer = answerBeforeRequest
            status = requestIsRepair ? "排错已停止，原答案与本题对话已保留" : "已停止，本批截图已保留，可重新发送"
        } else if wasCapturing {
            status = "排错截图已停止，本题对话已保留"
        }
        isWorking = false
    }

    func clearPending() {
        captureGeneration = UUID()
        pendingShots = []
        pendingCaptureCount = 0
        captureError = nil
        if !isWorking { status = "已清空待发送截图" }
    }

    func captureScreenshot() {
        if let displayID = currentDisplayID() { enqueueCapture(displayID: displayID) }
    }

    func captureErrorScreenshot() {
        guard hasSession else { status = "请先截图发送一道题并取得答案，再按 ⌃⌥⌘E 排错"; return }
        guard !isWorking, !isCapturingRepair else { return }
        if let displayID = currentDisplayID() { enqueueRepair(displayID: displayID) }
    }

    private func currentDisplayID() -> CGDirectDisplayID? {
        guard CGPreflightScreenCaptureAccess() else {
            captureError = "尚未获得屏幕录制权限，请在本页提前授权后再使用快捷键"
            return nil
        }
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main,
              let displayNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            captureError = "没有可截取的显示器"
            return nil
        }
        return CGDirectDisplayID(displayNumber.uint32Value)
    }

    func enqueueRepair(displayID: CGDirectDisplayID) {
        guard let expectedSession = sessionID else { status = "请先截图发送一道题并取得答案，再按 ⌃⌥⌘E 排错"; return }
        guard !isWorking, !isCapturingRepair else { return }
        isCapturingRepair = true
        repairGeneration = UUID()
        let token = repairGeneration
        let previous = captureTail
        status = "正在截取报错画面…"
        captureTail = Task {
            await previous?.value
            defer { if repairGeneration == token { isCapturingRepair = false } }
            guard repairGeneration == token, !Task.isCancelled else { return }
            guard sessionID == expectedSession, !isWorking else { status = "题目正在切换或生成，请完成后再排错"; return }
            do {
                let images = try await captureImages(displayID)
                guard repairGeneration == token, !Task.isCancelled, sessionID == expectedSession, !isWorking else { return }
                let message = ScreenshotConversationMessage(role: "user", content: "这是同一道题运行、编译或提交后的报错/未通过反馈，请作为本题的排错跟进处理。第一张是完整屏幕，其余如有是同屏局部放大图。结合原题、你之前给的代码和历次修复，指出本次报错原因，明确在哪个文件或代码框修改哪段、怎样替换，并给最小必要修复和验证步骤。保留题目接口和简单写法，不要从零重写无关内容。", imageJPEGs: images)
                let context = history + [message]
                let bytes = context.flatMap(\.imageJPEGs).reduce(0) { $0 + $1.count }
                guard bytes < 24 * 1024 * 1024, context.reduce(0, { $0 + $1.content.utf8.count }) < 256 * 1024 else {
                    throw CaptureError.message("本题对话已过大，请重新累计题目截图并发送新题")
                }
                guard let configuration = settings.activeConfiguration else { throw AISettingsError.incomplete }
                captureError = nil
                startRequest(context: context, configuration: configuration, isRepair: true, shots: [])
            } catch {
                guard repairGeneration == token, !Task.isCancelled else { return }
                captureError = "排错截图失败：" + error.localizedDescription
                status = "本题对话和原答案已保留，可再按 ⌃⌥⌘E"
            }
        }
    }

    func enqueueCapture(displayID: CGDirectDisplayID) {
        // Reserve a slot now; rapid presses must not replace or reorder earlier shots.
        guard pendingCount + inFlight.count < 6 else {
            captureError = "最多保留 6 张截图，请先发送或清空待发送截图"
            return
        }
        pendingCaptureCount += 1
        let token = captureGeneration
        let previous = captureTail
        captureTail = Task {
            await previous?.value
            guard captureGeneration == token, !Task.isCancelled else { return }
            defer { if captureGeneration == token { pendingCaptureCount -= 1 } }
            do {
                let images = try await captureImages(displayID)
                guard captureGeneration == token, !Task.isCancelled else { return }
                let byteCount = (pendingShots + inFlight + [images]).flatMap { $0 }.reduce(0) { $0 + $1.count }
                guard byteCount < 24 * 1024 * 1024 else { throw CaptureError.message("截图总量过大，请先发送或清空") }
                pendingShots.append(images)
                captureError = nil
                if !isWorking { status = "已累积 \(pendingShots.count) 张截图，按 ⌃⌥⌘Return 一起发送" }
            } catch {
                guard captureGeneration == token, !Task.isCancelled else { return }
                captureError = "截图失败：" + error.localizedDescription
            }
        }
    }

    func sendPending() {
        guard !isWorking, !isCapturingRepair else { return }
        let previous = captureTail
        let token = captureGeneration
        // Wait for screenshots requested before this keypress. Later shots form the next batch.
        captureTail = Task {
            await previous?.value
            guard captureGeneration == token, !Task.isCancelled else { return }
            startSending()
        }
    }

    private func startSending() {
        guard !isWorking else { return }
        guard !pendingShots.isEmpty else { status = "还没有待发送截图，请先按 ⌃⌥⌘S"; return }
        guard let configuration = settings.activeConfiguration else {
            status = "请先在设置中配置支持图片输入的 AI 模型；截图已保留"
            return
        }
        inFlight = pendingShots
        pendingShots = []
        let shots = inFlight
        let question = ChatCompletionClient.screenshotQuestionMessage(imageJPEGs: shots.flatMap { $0 }, screenshotImageCounts: shots.map { $0.count })
        startRequest(context: [question], configuration: configuration, isRepair: false, shots: shots)
    }

    private func startRequest(context: [ScreenshotConversationMessage], configuration: AIConfiguration, isRepair: Bool, shots: [[Data]]) {
        let token = UUID()
        generation = token
        requestIsRepair = isRepair
        answerBeforeRequest = answer
        answer = ""
        isWorking = true
        status = isRepair ? "正在沿本题对话排错（第 \(repairCount + 1) 次）…" : "正在合并 \(shots.count) 张截图并解答…"
        task = Task {
            defer { if generation == token { isWorking = false; task = nil } }
            do {
                let stream = isRepair ? conversationStream(context, configuration) : answerStream(shots, configuration)
                for try await chunk in stream {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    answer += chunk
                }
                try Task.checkCancellation()
                guard generation == token else { return }
                guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AIClientError.emptyAnswer }
                history = context + [ScreenshotConversationMessage(role: "assistant", content: answer)]
                if isRepair { repairCount += 1 }
                else { sessionID = UUID(); repairCount = 0 }
                inFlight = []
                status = isRepair ? "第 \(repairCount) 次排错完成，可继续按 ⌃⌥⌘E 跟进" : "解答完成，可按 ⌃⌥⌘E 截图排错"
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                answer = answerBeforeRequest
                if !isRepair { pendingShots.insert(contentsOf: inFlight, at: 0) }
                inFlight = []
                status = isRepair ? "排错失败，原答案与本题对话已保留：" + error.localizedDescription : "解题失败，截图已保留：" + error.localizedDescription
            }
        }
    }

    private static func capture(displayID: CGDirectDisplayID) async throws -> [Data] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.message("目标显示器已断开")
        }
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = min(1, 4096.0 / Double(max(CGDisplayPixelsWide(displayID), CGDisplayPixelsHigh(displayID))))
        config.width = max(1, Int(Double(CGDisplayPixelsWide(displayID)) * scale))
        config.height = max(1, Int(Double(CGDisplayPixelsHigh(displayID)) * scale))
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        var images = [image]
        // Preserve small question text when the provider downscales a full desktop.
        if max(image.width, image.height) > 2048 {
            let width = Int(ceil(Double(image.width) * 0.55))
            let height = Int(ceil(Double(image.height) * 0.55))
            for y in [0, image.height - height] {
                for x in [0, image.width - width] {
                    guard let tile = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
                        throw CaptureError.message("截图局部编码失败")
                    }
                    images.append(tile)
                }
            }
        }
        let encoded = try images.map { image in
            guard let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else {
                throw CaptureError.message("截图编码失败")
            }
            return jpeg
        }
        guard encoded.reduce(0, { $0 + $1.count }) < 24 * 1024 * 1024 else {
            throw CaptureError.message("截图过大")
        }
        return encoded
    }

    private enum CaptureError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
    }
}

struct ScreenQuestionView: View {
    let controller: ScreenQuestionController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("截图解题").font(.title2.bold())
                Spacer()
                Button("悬浮答案") { controller.showFloatingAnswer?() }
                    .help("置顶显示答案，不抢输入焦点；⌃⌥⌘Space 显示或收起")
                Button("截图排错") { controller.captureErrorScreenshot() }
                    .disabled(!controller.hasSession || controller.isWorking || controller.isCapturingRepair)
                    .help("⌃⌥⌘E：截取当前报错并沿本题对话修复")
                if controller.isWorking || controller.isCapturingRepair { Button("停止") { controller.cancel() } }
            }
            HStack {
                Text("待发送：\(controller.pendingCount) 张")
                Spacer()
                Button("清空截图") { controller.clearPending() }.disabled(controller.pendingCount == 0)
                Button("一起发送") { controller.sendPending() }
                    .disabled(controller.pendingCount == 0 || controller.isWorking)
            }
            Text(controller.hasSession ? "本题会话 · 已排错 \(controller.repairCount) 次 · ⌃⌥⌘E 截图跟进" : "普通累计发送开始新题，取得答案后可截图排错")
                .font(.caption).foregroundStyle(.secondary)
            Text(controller.status).foregroundStyle(.secondary).textSelection(.enabled)
            if let error = controller.shortcutError {
                Text(error).foregroundStyle(.red)
            }
            if let error = controller.captureError {
                Text(error).foregroundStyle(.red)
            }
            ScrollView {
                MarkdownDocumentView(markdown: controller.answer)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Text("截图 \(ScreenQuestionController.shortcut) · 发送 \(ScreenQuestionController.sendShortcut) · 清空 \(ScreenQuestionController.clearShortcut)")
                Spacer()
                Button("授权屏幕录制") {
                    if !CGRequestScreenCaptureAccess(),
                       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            .font(.callout)
            Text("截图仅暂存在内存中，发送时才提交至模型服务。可滚动页面后继续截图，再统一发送。快捷键不切页、不弹窗。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .navigationTitle("截图解题")
    }
}
