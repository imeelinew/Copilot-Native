import AppKit
import CoreGraphics
import SwiftUI

struct LiveInterviewView: View {
    @Bindable var controller: LiveInterviewController
    let speech: SpeechSettings
    let settings: RemoteAISettings
    let knowledge: InterviewKnowledgeBase
    let openSettings: () -> Void
    let saveAnswer: (String, String) -> Void
    private var source: SpeechAudioSource { controller.source }
    private var applicationID: String { controller.applicationID }
    private var applications: [SpeechApplicationOption] { controller.availableApplications }
    @State private var applicationError: String?
    @State private var loadingApplications = false
    @State private var showingSpeechSettings = false

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        captureControls
                        Divider()
                        transcriptPanel
                        questionComposer
                    }
                }
                Divider()
                turnList.frame(minHeight: 90, idealHeight: 150, maxHeight: 220)
            }
            .padding(18)
            .frame(minWidth: 300, idealWidth: 350, maxWidth: 430)
            LiveInterviewAnswerView(controller: controller, openSettings: openSettings, saveAnswer: saveAnswer)
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("实时面试")
        .onAppear { controller.configure(speech: speech, ai: settings, knowledge: knowledge) }
        .sheet(isPresented: $showingSpeechSettings) {
            SpeechSettingsView(settings: speech)
                .padding(24)
                .frame(width: 510, height: 400)
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时面试").font(.headline)
                Spacer()
                Button { controller.showFloatingAnswer?() } label: { Image(systemName: "rectangle.on.rectangle") }
                    .help("不抢焦点的悬浮答案 · ⌃⌥⌘I")
                    .accessibilityLabel("悬浮面试答案")
                Button { showingSpeechSettings = true } label: { Image(systemName: "gearshape") }
                    .help("语音识别设置")
                    .accessibilityLabel("语音识别设置")
            }
            Picker("音频来源", selection: $controller.source) {
                ForEach(SpeechAudioSource.allCases) { Text($0.title).tag($0) }
            }
            .disabled(controller.isActive)
            if source == .system {
                HStack {
                    Picker("应用", selection: $controller.applicationID) {
                        Text("全部系统声音").tag("")
                        ForEach(applications) { Text($0.name).tag($0.id) }
                    }
                    .disabled(controller.isActive)
                    Button { refreshApplications() } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(controller.isActive || loadingApplications)
                        .help("刷新正在运行的应用；需要系统音频录制权限")
                        .accessibilityLabel("刷新声音来源应用")
                }
                if let applicationError {
                    Text(applicationError).font(.caption).foregroundStyle(.red)
                    Button("系统权限") {
                        _ = CGRequestScreenCaptureAccess()
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    }
                }
                Text("所有识别语音均视为面试官发言；线上面试请选择会议应用声音。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("使用系统当前输入设备；切换麦克风后会自动恢复监听。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            InterviewKnowledgeControls(knowledge: knowledge)
            DisclosureGroup("全局快捷键（其他应用内也可用）") {
                Text(LiveInterviewPanelController.shortcutHelp)
                    .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button {
                    if controller.isActive { controller.stop() }
                    else {
                        controller.start(source: source, applicationID: applicationID.isEmpty ? nil : applicationID,
                                         speech: speech, ai: settings, knowledge: knowledge)
                    }
                } label: {
                    Label(controller.isActive ? "停止监听" : "开始监听", systemImage: controller.isActive ? "stop.fill" : "waveform")
                }
                .buttonStyle(.borderedProminent)
                .disabled(controller.status == .stopping)
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Spacer()
                ProgressView(value: Double(controller.level))
                    .frame(width: 64)
                    .accessibilityLabel("输入音量")
            }
            Text(controller.status.title)
                .font(.caption)
                .foregroundStyle(isFailed ? Color.red : Color.secondary)
                .textSelection(.enabled)
            if isFailed {
                HStack {
                    Button("语音设置") { showingSpeechSettings = true }
                    Button("系统权限") {
                        if source == .system { _ = CGRequestScreenCaptureAccess() }
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(source == .microphone ? "Privacy_Microphone" : "Privacy_ScreenCapture")")!)
                    }
                }
            }
            if let notice = controller.notice {
                Text(notice).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = controller.status { return true }
        return false
    }

    private var transcriptPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("实时转写").font(.subheadline.bold())
            ScrollViewReader { proxy in
                ScrollView {
                    Text(controller.transcript.isEmpty ? "开始监听后，识别文字会显示在这里。" : controller.transcript)
                        .font(.callout)
                        .foregroundStyle(controller.transcript.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id("transcript-bottom")
                }
                .frame(minHeight: 70, idealHeight: 110, maxHeight: 150)
                .onChange(of: controller.transcript) { _, _ in proxy.scrollTo("transcript-bottom", anchor: .bottom) }
            }
        }
    }

    private var questionComposer: some View {
        @Bindable var controller = controller
        @Bindable var speech = speech
        return VStack(alignment: .leading, spacing: 8) {
            Toggle("自动生成回答", isOn: $speech.automaticAnswers)
                .toggleStyle(.switch).controlSize(.small)
                .onChange(of: speech.automaticAnswers) { controller.automaticAnswersChanged() }
            if speech.automaticAnswers {
                Text(controller.questionAnalysisStatus).font(.caption).foregroundStyle(.secondary)
            }
            if controller.isEditing {
                TextEditor(text: $controller.questionEdit)
                    .font(.body)
                    .frame(height: 85)
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary) }
                HStack {
                    Button("提交问题") { controller.submit() }.buttonStyle(.borderedProminent)
                        .disabled(controller.questionEdit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("取消编辑") { controller.cancelEditing() }
                }
            } else {
                Text(controller.draft.isEmpty ? "等待下一个问题…" : controller.draft)
                    .font(.callout).foregroundStyle(controller.draft.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("立即回答") { controller.submit() }
                        .disabled(controller.draft.isEmpty)
                        .keyboardShortcut(.return, modifiers: [.command, .shift])
                    Button("编辑问题") { controller.beginEditing() }
                    Button("忽略") { controller.discardDraft() }.disabled(controller.draft.isEmpty)
                }
                .controlSize(.small)
            }
        }
    }

    private var turnList: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("问题记录").font(.subheadline.bold())
                Spacer()
                Button("清空会话") { controller.clearSession() }
                    .controlSize(.small)
                    .disabled(controller.isActive || controller.turns.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.turns.reversed()) { turn in
                        Button { controller.selectedTurnID = turn.id } label: {
                            Text(turn.question).lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(controller.selectedTurn?.id == turn.id ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 70, maxHeight: .infinity)
        }
    }

    private func refreshApplications() {
        loadingApplications = true
        applicationError = nil
        Task {
            do {
                let apps = try await SpeechAudioCapture().applications()
                var seen = Set<String>()
                controller.availableApplications = apps.compactMap { app in
                    guard !app.bundleIdentifier.isEmpty, seen.insert(app.bundleIdentifier).inserted else { return nil }
                    return SpeechApplicationOption(id: app.bundleIdentifier, name: app.applicationName)
                }
                if !applicationID.isEmpty, !applications.contains(where: { $0.id == applicationID }) { controller.applicationID = "" }
            } catch { applicationError = error.localizedDescription }
            loadingApplications = false
        }
    }
}

struct SpeechSettingsView: View {
    @Bindable var settings: SpeechSettings
    var showsDoneButton = true
    @Environment(\.dismiss) private var dismiss
    @State private var checking = false
    @State private var feedback: String?

    var body: some View {
        Form {
            Section("豆包实时语音识别 2.0") {
                SecureField("API Key", text: $settings.apiKey)
                Text("双向流式优化模式 · 句末二遍识别 · 小时版")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("技术热词，用逗号分隔", text: $settings.hotwords, axis: .vertical)
                    .lineLimit(2...4)
                Text("已配置 \(settings.words.count) 个热词。核心前端词排在前面；实时识别的热词预算较小，完整词库用于句末二遍精校。修改后重新开始监听生效。")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("自动生成回答", isOn: $settings.automaticAnswers)
                Text("使用当前 AI 模型从已确认分句中提取完整面试问题、略过寒暄。完整问题确认后即分析，不受背景音和后续转写阻塞。设置自动保存到本机。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button(checking ? "检查中…" : "检查连接") { checkConnection() }
                    .disabled(checking || settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                if showsDoneButton {
                    Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            if let feedback { Text(feedback).font(.caption).textSelection(.enabled) }
        }
        .formStyle(.grouped)
    }

    private func checkConnection() {
        checking = true
        feedback = nil
        Task {
            let connection = DoubaoSpeechConnection()
            defer { connection.close(); checking = false }
            do {
                _ = try await connection.open(key: settings.apiKey, hotwords: settings.words)
                feedback = "连接成功，语音识别 2.0 服务可用"
            } catch { feedback = error.localizedDescription }
        }
    }
}

private struct LiveInterviewAnswerView: View {
    let controller: LiveInterviewController
    let openSettings: () -> Void
    let saveAnswer: (String, String) -> Void

    @ViewBuilder var body: some View {
        if let turn = controller.selectedTurn {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top) {
                        Text(turn.question).font(.title2.bold()).textSelection(.enabled)
                        Spacer()
                        if turn.state == .complete {
                            Button { saveAnswer(turn.question, turn.answer) } label: { Label("保存到题库", systemImage: "square.and.arrow.down") }
                        }
                        if !turn.answer.isEmpty {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(turn.answer, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .accessibilityLabel("复制回答")
                        }
                    }
                    Divider()
                    if let title = turn.savedQuestionTitle {
                        Text("来自已保存题库 · " + title).font(.caption).foregroundStyle(.secondary)
                    }
                    switch turn.state {
                    case .waiting, .retrieving, .streaming:
                        HStack {
                            ProgressView().controlSize(.small)
                            Text(turn.state == .streaming ? "正在生成回答…" : "正在检索本地资料…")
                            Spacer()
                            Button("停止生成") { controller.cancelAnswer() }
                        }
                    case .needsConfiguration:
                        Text("请先配置回答模型，语音识别可以继续使用。")
                        Button("打开模型设置") { openSettings() }
                        Button("重新生成") { controller.retrySelectedAnswer() }
                    case .failed(let message):
                        Text(message).foregroundStyle(.red)
                        Button("重新生成") { controller.retrySelectedAnswer() }
                    case .complete:
                        Button("重新生成") { controller.retrySelectedAnswer() }.controlSize(.small)
                    case .idle: EmptyView()
                    }
                    if !turn.answer.isEmpty { MarkdownDocumentView(markdown: turn.answer) }
                    InterviewAnswerSources(retrieval: turn.references)
                }
                .padding(28)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        } else {
            ContentUnavailableView("等待面试问题", systemImage: "waveform", description: Text("开始监听后会实时转写，在问题结束后自动结合本地资料生成回答。"))
        }
    }

}
