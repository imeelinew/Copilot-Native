import SwiftUI

private enum MainPage: String, Hashable {
    case library
    case settings
}

private struct SearchTrigger: Equatable {
    let query: String
    let libraryRevision: Int
    let settingsRevision: Int
}

struct MainWindowView: View {
    let library: QuestionLibrary
    let settings: RemoteAISettings

    @State private var page: MainPage? = .library
    @State private var query = ""
    @State private var selectedID: UUID?
    @State private var editor: QuestionEditorPresentation?
    @State private var pendingDeleteID: UUID?
    @State private var errorMessage: String?
    @State private var ai = AIAnswerController()
    @FocusState private var searchFocused: Bool

    private var results: [QuestionAnswer] { library.search(query) }
    private var searchTrigger: SearchTrigger {
        SearchTrigger(query: query, libraryRevision: library.revision, settingsRevision: settings.revision)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section {
                    Label("题库", systemImage: "rectangle.stack.fill")
                        .tag(MainPage.library)
                }
                Section("偏好") {
                    Label("模型设置", systemImage: "sparkles")
                        .tag(MainPage.settings)
                }
            }
            .navigationTitle("Copilot Native")
            .navigationSplitViewColumnWidth(min: 185, ideal: 210, max: 250)
        } detail: {
            if page == .settings {
                AISettingsView(settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                libraryPage
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .adding()
                } label: {
                    Label("添加问答", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    page = .library
                    searchFocused = true
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .keyboardShortcut("f", modifiers: .command)
            }
        }
        .sheet(item: $editor) { presentation in
            QuestionEditorView(presentation: presentation, library: library) { savedID in
                query = ""
                selectedID = savedID
                page = .library
                synchronizeSearch()
            }
        }
        .alert("删除问答", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("删除", role: .destructive) { deletePending() }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("将从本机题库中删除这条问题及其答案")
        }
        .alert("操作失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear {
            synchronizeSearch()
            searchFocused = true
        }
        .onChange(of: searchTrigger) { _, _ in synchronizeSearch() }
        .onDisappear { ai.cancel() }
        .frame(minWidth: 850, minHeight: 560)
    }

    private var libraryPage: some View {
        HStack(spacing: 0) {
            questionColumn
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 390)
            Divider()
            answerColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("题库")
    }

    private var questionColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索问题、答案或拼音", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { selectedID = results.first?.id }
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清除搜索")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
            .padding(.horizontal, 16)
            .padding(.top, 16)

            HStack {
                Text(query.isEmpty ? "全部问题" : "搜索结果")
                    .font(.headline)
                Spacer()
                Text("\(results.count)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(spacing: 9) {
                    ForEach(results, id: \.id) { item in
                        Button {
                            selectedID = item.id
                        } label: {
                            QuestionResultCard(item: item, isSelected: selectedID == item.id)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(item.question)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 20)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var answerColumn: some View {
        if let selectedID, let selected = results.first(where: { $0.id == selectedID }) {
            savedAnswer(selected)
        } else if results.isEmpty, !query.isEmpty {
            aiAnswer
        } else {
            ContentUnavailableView(
                library.items.isEmpty ? "题库还是空的" : "选择一道问题",
                systemImage: library.items.isEmpty ? "rectangle.stack.badge.plus" : "text.book.closed",
                description: Text(library.items.isEmpty ? "点击工具栏的 + 添加第一条问答" : "从左侧选择问题，查看对应答案")
            )
        }
    }

    private func savedAnswer(_ item: QuestionAnswer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(item.question)
                            .font(.title2.bold())
                            .textSelection(.enabled)
                        Text("题库答案")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Button {
                        editor = .init(editingID: item.id, question: item.question, answer: item.answer)
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        pendingDeleteID = item.id
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                Divider()
                MarkdownDocumentView(markdown: item.answer)
            }
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(30)
        }
    }

    private var aiAnswer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(query).font(.title2.bold()).textSelection(.enabled)
                        Label("AI 临时回答", systemImage: "sparkles")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ai.state == .complete {
                        Button {
                            editor = .adding(question: query.trimmingCharacters(in: .whitespacesAndNewlines), answer: ai.answer)
                        } label: {
                            Label("保存到题库", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Divider()

                switch ai.state {
                case .idle:
                    Text("继续输入问题以获取 AI 回答")
                        .foregroundStyle(.secondary)
                case .waiting, .streaming:
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(ai.state == .waiting ? "等待输入结束…" : "正在生成回答…")
                            .foregroundStyle(.secondary)
                    }
                case .complete:
                    EmptyView()
                case .needsConfiguration:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("请先配置远程模型").foregroundStyle(.secondary)
                        Button("打开模型设置") { page = .settings }
                    }
                case .failed(let message):
                    VStack(alignment: .leading, spacing: 10) {
                        Text(message).foregroundStyle(.red)
                        Button("重试") { ai.retry() }
                    }
                }

                if !ai.answer.isEmpty {
                    MarkdownDocumentView(markdown: ai.answer)
                }
            }
            .frame(maxWidth: 850, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(30)
        }
    }

    private func synchronizeSearch() {
        let matches = results
        if !matches.contains(where: { $0.id == selectedID }) {
            selectedID = matches.first?.id
        }
        ai.update(query: query, hasResults: !matches.isEmpty, configuration: settings.activeConfiguration)
    }

    private func deletePending() {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        do {
            try library.delete(id: id)
            synchronizeSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct QuestionResultCard: View {
    let item: QuestionAnswer
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.question)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(preview)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    private var preview: String {
        let phrases = MarkdownBlocks.parse(item.answer).flatMap { block -> [String] in
            switch block {
            case .heading(_, let text), .paragraph(let text): [text]
            case .bullet(let values), .numbered(let values): values
            case .code: []
            case .table(let table): table.headers
            }
        }
        let result = phrases.prefix(3).joined(separator: " · ")
        return result.isEmpty ? "代码示例" : result
    }
}
