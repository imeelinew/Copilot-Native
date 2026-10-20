import Foundation
import Observation

struct InterviewTurn: Identifiable {
    let id = UUID()
    let question: String
    var answer = ""
    var references = KnowledgeRetrieval.empty
    var state: AIAnswerState = .waiting
    var savedQuestionTitle: String?
    let createdAt = Date()
}

@MainActor
@Observable
final class LiveInterviewController {
    enum Status: Equatable {
        case idle, connecting, listening, stopping, reconnecting(Int), failed(String)
        var title: String {
            switch self {
            case .idle: "未监听"
            case .connecting: "正在连接…"
            case .listening: "正在监听"
            case .stopping: "正在结束识别…"
            case .reconnecting(let attempt): "正在重连（\(attempt)/4）…"
            case .failed(let message): message
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var transcript = ""
    private(set) var draft = ""
    private(set) var level: Float = 0
    private(set) var turns: [InterviewTurn] = []
    private(set) var notice: String?
    private(set) var questionAnalysisStatus = "等待面试问题"
    var availableApplications: [SpeechApplicationOption] = []
    var source = SpeechAudioSource.system
    var applicationID = ""
    var selectedTurnID: UUID?
    var questionEdit = ""
    var isEditing = false
    @ObservationIgnored var showFloatingAnswer: (() -> Void)?
    @ObservationIgnored private var sessionTask: Task<Void, Never>?
    @ObservationIgnored private var answerTask: Task<Void, Never>?
    @ObservationIgnored private var settlementID = UUID()
    @ObservationIgnored private var settlementTask: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Never>?
    @ObservationIgnored private var connection: DoubaoSpeechConnection?
    @ObservationIgnored private var capture: SpeechAudioCapture?
    @ObservationIgnored private var finishing = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var utterances: [Int: SpeechUtterance] = [:]
    @ObservationIgnored private var consumedStarts: Set<Int> = []
    @ObservationIgnored private var transcriptPrefix = ""
    @ObservationIgnored private var lastAnalyzedSegments: [InterviewTranscriptSegment] = []
    @ObservationIgnored private var analysisRetryTask: Task<Void, Never>?
    @ObservationIgnored private var analysisFailures = 0
    @ObservationIgnored private var failedAnalysisSegments: [InterviewTranscriptSegment] = []
    @ObservationIgnored private var library: QuestionLibrary?
    @ObservationIgnored private var libraryScope: LibraryScope?
    @ObservationIgnored private let extractQuestion: @Sendable ([InterviewTranscriptSegment], String, AIConfiguration) async throws -> InterviewQuestionDecision
    @ObservationIgnored private let analysisRetryDelay: Duration
    @ObservationIgnored private var speechSettings: SpeechSettings?
    @ObservationIgnored private var aiSettings: RemoteAISettings?
    @ObservationIgnored private var knowledge: InterviewKnowledgeBase?

    init(analysisRetryDelay: Duration = .seconds(1),
         extractQuestion: @escaping @Sendable ([InterviewTranscriptSegment], String, AIConfiguration) async throws -> InterviewQuestionDecision = {
             try await InterviewQuestionExtractor().extract(segments: $0, recentContext: $1, configuration: $2)
         }) {
        self.analysisRetryDelay = analysisRetryDelay
        self.extractQuestion = extractQuestion
    }

    func configureLibrary(_ library: QuestionLibrary, scope: LibraryScope? = nil) {
        self.library = library
        libraryScope = scope
    }

    private func cancelAnalysis() {
        settlementID = UUID()
        settlementTask?.cancel()
        settlementTask = nil
        analysisRetryTask?.cancel()
        analysisRetryTask = nil
        analysisFailures = 0
        failedAnalysisSegments = []
    }

    var isActive: Bool {
        switch status {
        case .connecting, .listening, .stopping, .reconnecting: true
        case .idle, .failed: false
        }
    }
    var selectedTurn: InterviewTurn? { turns.first { $0.id == selectedTurnID } ?? turns.last }
    var selectedIndex: Int? { selectedTurn.flatMap { selected in turns.firstIndex { $0.id == selected.id } } }
    var canSelectPrevious: Bool { (selectedIndex ?? 0) > 0 }
    var canSelectNext: Bool { selectedIndex.map { $0 + 1 < turns.count } ?? false }
    var hasPendingQuestion: Bool {
        !(isEditing ? questionEdit : draft).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func selectTurn(offset: Int) {
        guard let index = selectedIndex else { return }
        selectedTurnID = turns[min(turns.count - 1, max(0, index + offset))].id
    }

    func toggleListening() {
        if isActive { stop(); return }
        guard let speechSettings, let aiSettings, let knowledge else {
            notice = "请先在主窗口完成实时面试设置"
            return
        }
        start(source: source, applicationID: applicationID.isEmpty ? nil : applicationID,
              speech: speechSettings, ai: aiSettings, knowledge: knowledge)
    }

    func automaticAnswersChanged() {
        cancelAnalysis()
        if speechSettings?.automaticAnswers == true { scheduleSubmission() }
        else { questionAnalysisStatus = "自动回答已暂停，可按 ⌃⌥⌘A 手动提交" }
    }

    func configure(speech: SpeechSettings, ai: RemoteAISettings, knowledge: InterviewKnowledgeBase) {
        self.speechSettings = speech
        self.aiSettings = ai
        self.knowledge = knowledge
    }

    func start(source: SpeechAudioSource, applicationID: String?, speech: SpeechSettings, ai: RemoteAISettings, knowledge: InterviewKnowledgeBase) {
        guard !isActive, stopTask == nil else { return }
        guard !speech.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = .failed("请先填写语音 API Key")
            return
        }
        configure(speech: speech, ai: ai, knowledge: knowledge)
        cancelAnalysis()
        let token = UUID()
        generation = token
        finishing = false
        notice = nil
        status = .connecting
        sessionTask = Task {
            var failures = 0
            while !Task.isCancelled, generation == token, !finishing {
                let capture = SpeechAudioCapture()
                let connection = DoubaoSpeechConnection()
                self.capture = capture
                self.connection = connection
                utterances = [:]
                consumedStarts = []
                lastAnalyzedSegments = []
                questionAnalysisStatus = "等待面试问题"
                transcriptPrefix = transcript.isEmpty ? "" : transcript + "\n"
                if !draft.isEmpty {
                    notice = "连接已切换；未提交的文字保留在问题编辑框中，请核对后提交。"
                    questionEdit = draft
                    isEditing = true
                }
                draft = ""
                let connectedAt = Date()
                var acquisitionStarted = false
                do {
                    // Acquire audio permissions before starting a billable ASR session.
                    let frames = try await capture.start(source: source, applicationID: applicationID)
                    acquisitionStarted = true
                    try Task.checkCancellation()
                    guard !finishing else { throw CancellationError() }
                    let events = try await connection.open(key: speech.apiKey, hotwords: speech.words)
                    try Task.checkCancellation()
                    guard !finishing else { throw CancellationError() }
                    status = .listening
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { try await self.sendAudio(frames, connection: connection) }
                        group.addTask { try await self.receiveResults(events) }
                        // A final-response timeout is applied by stop(). Errors close both sides
                        // before task-group teardown so a blocked socket receive cannot hang it.
                        do { while try await group.next() != nil { } }
                        catch {
                            group.cancelAll()
                            connection.close()
                            await capture.stop()
                            throw error
                        }
                    }
                    connection.close()
                    await capture.stop()
                    break
                } catch {
                    connection.close()
                    await capture.stop()
                    cancelAnalysis()
                    guard !Task.isCancelled, generation == token, !finishing else { break }
                    // Startup/permission failures require a user action, not repeated OS prompts.
                    let retryable = acquisitionStarted && ((error as? SpeechError)?.canRetry ?? true)
                    if Date().timeIntervalSince(connectedAt) > 30 { failures = 0 }
                    failures += 1
                    guard retryable, failures <= 4 else {
                        status = .failed(error.localizedDescription)
                        notice = "监听已停止，已生成的回答仍保留。"
                        self.capture = nil
                        self.connection = nil
                        level = 0
                        return
                    }
                    status = .reconnecting(failures)
                    notice = "音频连接中断，正在恢复；重连期间的声音不会被识别，请重述遗漏内容。"
                    do { try await Task.sleep(for: .seconds(min(pow(2, Double(failures - 1)), 8))) }
                    catch { break }
                }
            }
            if generation == token {
                self.capture = nil
                self.connection = nil
                level = 0
                status = .idle
            }
        }
    }

    private func sendAudio(_ frames: AsyncThrowingStream<SpeechAudioFrame, Error>, connection: DoubaoSpeechConnection) async throws {
        for try await frame in frames {
            try Task.checkCancellation()
            level = min(1, frame.level * 8)
            try await connection.send(frame.pcm)
            scheduleSubmission()
        }
        if !Task.isCancelled { try await connection.send(Data(repeating: 0, count: 6_400), final: true) }
    }

    private func receiveResults(_ events: AsyncThrowingStream<SpeechRecognitionResult, Error>) async throws {
        for try await result in events {
            try Task.checkCancellation()
            receive(result)
        }
        if !finishing { throw SpeechError.message("语音会话已结束，请重新开始监听") }
    }

    func stop() {
        guard isActive, stopTask == nil else { return }
        if status != .listening { sessionTask?.cancel() }
        finishing = true
        status = .stopping
        cancelAnalysis()
        stopTask = Task { [self] in
            // Stop capture, drain queued packets, then wait for the corrected final transcript.
            let deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                guard !Task.isCancelled else { return }
                self?.connection?.close()
                self?.sessionTask?.cancel()
            }
            await capture?.stop()
            await sessionTask?.value
            deadline.cancel()
            sessionTask = nil
            status = .idle
            stopTask = nil
            if !Task.isCancelled { scheduleSubmission(allowStopped: true) }
        }
    }

    func shutdown() {
        generation = UUID()
        finishing = true
        sessionTask?.cancel()
        stopTask?.cancel()
        cancelAnalysis()
        cancelAnswer()
        connection?.close()
        let oldCapture = capture
        Task { await oldCapture?.stop() }
        capture = nil
        connection = nil
        level = 0
        status = .idle
    }

    func receive(_ result: SpeechRecognitionResult, allowStopped: Bool = false) {
        if let text = result.text { transcript = transcriptPrefix + text }
        if let snapshot = result.utterances {
            // ASR omits a zero start_time on the first utterance; keep it as segment 0.
            for utterance in snapshot {
                let id = utterance.start_time ?? 0
                // Retain earlier confirmed segments if an update only includes a tail.
                if utterances[id]?.definite != true || utterance.definite == true { utterances[id] = utterance }
            }
        }
        let pending = utterances.sorted { $0.key < $1.key }.filter { !consumedStarts.contains($0.key) }
        draft = pending.map(\.value.text).joined()
        scheduleSubmission(allowStopped: allowStopped)
    }

    private func scheduleSubmission(allowStopped: Bool = false) {
        guard speechSettings?.automaticAnswers == true, !isEditing,
              (!finishing || allowStopped), (status == .listening || (allowStopped && status == .idle)),
              settlementTask == nil else { return }
        let segments = utterances.sorted { $0.key < $1.key }
            .filter { !consumedStarts.contains($0.key) && $0.value.definite == true }
            .prefix(8)
            .map { InterviewTranscriptSegment(id: $0.key, text: $0.value.text) }
        guard !segments.isEmpty, segments != lastAnalyzedSegments else { return }
        if segments != failedAnalysisSegments {
            analysisRetryTask?.cancel()
            analysisRetryTask = nil
            analysisFailures = 0
        }
        guard analysisRetryTask == nil, analysisFailures < 3 else { return }
        if let local = InterviewQuestionExtractor.localDecision(segments: segments) {
            lastAnalyzedSegments = segments
            consumedStarts.formUnion(local.consumed_ids)
            rebuildDraft()
            questionAnalysisStatus = "已识别自我介绍请求，优先使用已保存题库"
            appendQuestion(local.question)
            scheduleSubmission(allowStopped: allowStopped)
            return
        }
        guard let configuration = aiSettings?.activeConfiguration else {
            questionAnalysisStatus = "请配置 AI 模型后自动分析，或点击立即回答"
            return
        }
        let context = utterances.sorted { $0.key < $1.key }
            .filter { consumedStarts.contains($0.key) }.suffix(4).map(\.value.text).joined()
        let settlementToken = UUID()
        settlementID = settlementToken
        questionAnalysisStatus = "正在分析面试问题…"
        settlementTask = Task {
            defer { if settlementID == settlementToken { settlementTask = nil } }
            do {
                // The ASR final is already endpointed. Do not wait for a second silent interval.
                try await Task.sleep(for: .milliseconds(150))
                let decision = try await extractQuestion(segments, String(context.suffix(2_000)), configuration)
                try Task.checkCancellation()
                guard settlementID == settlementToken, !isEditing,
                      speechSettings?.automaticAnswers == true else { return }
                lastAnalyzedSegments = segments
                analysisFailures = 0
                failedAnalysisSegments = []
                consumedStarts.formUnion(decision.consumed_ids)
                rebuildDraft()
                switch decision.action {
                case .answer:
                    questionAnalysisStatus = "已提取面试问题"
                    appendQuestion(decision.question)
                case .ignore:
                    questionAnalysisStatus = "已略过寒暄，等待面试问题"
                case .wait:
                    questionAnalysisStatus = "等待提问补充完整…"
                }
                // A newer confirmed sentence may have arrived during the request.
                settlementTask = nil
                scheduleSubmission(allowStopped: allowStopped)
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, settlementID == settlementToken else { return }
                analysisFailures += 1
                failedAnalysisSegments = segments
                settlementTask = nil
                if analysisFailures < 3 {
                    questionAnalysisStatus = "问题分析失败，正在重试（\(analysisFailures)/2）：" + error.localizedDescription
                    analysisRetryTask = Task {
                        do { try await Task.sleep(for: analysisRetryDelay) } catch { return }
                        guard !Task.isCancelled, settlementID == settlementToken else { return }
                        analysisRetryTask = nil
                        scheduleSubmission(allowStopped: allowStopped)
                    }
                } else {
                    questionAnalysisStatus = "自动分析连续失败，文字已保留，按 ⌃⌥⌘A 立即回答：" + error.localizedDescription
                }
            }
        }
    }

    private func rebuildDraft() {
        draft = utterances.sorted { $0.key < $1.key }.filter { !consumedStarts.contains($0.key) }.map(\.value.text).joined()
    }

    func beginEditing() {
        cancelAnalysis()
        questionEdit = draft
        isEditing = true
    }

    func cancelEditing() {
        isEditing = false
        questionEdit = ""
        scheduleSubmission()
    }

    func discardDraft() {
        cancelAnalysis()
        consumedStarts.formUnion(utterances.keys)
        draft = ""
        isEditing = false
        questionEdit = ""
        questionAnalysisStatus = "等待面试问题"
    }

    func submit() {
        let text = (isEditing ? questionEdit : draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        discardDraft()
        let normalized = text.filter { !$0.isWhitespace && !$0.isPunctuation }
        if ["嗯", "好的", "好", "谢谢", "对", "是的", "没错", "明白", "OK", "ok"].contains(normalized) { return }
        appendQuestion(text)
    }

    private func appendQuestion(_ question: String) {
        let turn = InterviewTurn(question: question.trimmingCharacters(in: .whitespacesAndNewlines))
        turns.append(turn)
        selectedTurnID = turn.id
        generateAnswer(for: turn.id)
    }

    func retrySelectedAnswer() {
        if let id = selectedTurn?.id { generateAnswer(for: id) }
    }

    func cancelAnswer() {
        answerTask?.cancel()
        for index in turns.indices where [.waiting, .retrieving, .streaming].contains(turns[index].state) {
            turns[index].state = .failed("回答已停止，可重新生成")
        }
    }

    func clearSession() {
        guard !isActive else { return }
        cancelAnswer()
        turns = []
        selectedTurnID = nil
        transcript = ""
        transcriptPrefix = ""
        discardDraft()
        notice = nil
    }

    private func generateAnswer(for id: UUID) {
        cancelAnswer()
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].answer = ""
        turns[index].references = .empty
        turns[index].savedQuestionTitle = nil
        let question = turns[index].question
        if let saved = library?.interviewMatch(question, preferredScope: libraryScope) {
            turns[index].answer = saved.answer
            turns[index].savedQuestionTitle = saved.question
            turns[index].state = .complete
            return
        }
        if QuestionSearchIndex.isIntroductionRequest(question) {
            turns[index].state = .failed("题库中未找到唯一匹配的自我介绍，请先保存或选择对应题库版本；不会自动编造个人信息")
            return
        }
        guard let configuration = aiSettings?.activeConfiguration else {
            turns[index].state = .needsConfiguration
            return
        }
        let history = Array(turns[..<index].filter { $0.state == .complete }.suffix(4))
        let previousProject = history.last?.references.projectIDs.count == 1 ? history.last?.references.projectIDs.first : nil
        let scope = knowledge?.scope ?? .automatic
        turns[index].state = .retrieving
        answerTask = Task {
            do {
                let retrieval: KnowledgeRetrieval
                do {
                    retrieval = try await InterviewKnowledgeEngine.shared.retrieve(question: question, scope: scope, previousProject: previousProject, previousQuestion: history.last?.question,
                        previousPassageIDs: history.last?.references.passages.map(\.id) ?? [])
                } catch is CancellationError { throw CancellationError() }
                catch { retrieval = .init(passages: [], projectIDs: [], usedVectors: false, warning: "本地资料读取失败：" + error.localizedDescription) }
                try Task.checkCancellation()
                guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
                turns[index].references = retrieval
                turns[index].state = .streaming
                let conversation = history.flatMap { [AIConversationMessage(role: "user", content: $0.question), AIConversationMessage(role: "assistant", content: $0.answer)] }
                for try await text in ChatCompletionClient().streamAnswer(for: question, configuration: configuration, context: retrieval, conversation: conversation) {
                    try Task.checkCancellation()
                    turns[index].answer += text
                }
                try Task.checkCancellation()
                turns[index].state = turns[index].answer.isEmpty ? .failed(AIClientError.emptyAnswer.localizedDescription) : .complete
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, let index = turns.firstIndex(where: { $0.id == id }) else { return }
                turns[index].state = .failed(error.localizedDescription)
            }
        }
    }
}
