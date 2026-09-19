import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension Notification.Name {
    static let focusQuestionSearch = Notification.Name("focusQuestionSearch")
}

private struct SearchTrigger: Equatable {
    let query: String
    let scope: LibraryScope?
    let libraryRevision: Int
    let settingsRevision: Int
}

private struct HierarchyNameRequest: Identifiable {
    enum Action {
        case addPackage
        case addCapsule(packageID: UUID)
        case renamePackage(id: UUID)
        case renameCapsule(id: UUID)
    }

    let id = UUID()
    let action: Action
    let title: String
    let initialValue: String
}

private struct HierarchyDeleteRequest: Identifiable {
    enum Target {
        case package(UUID)
        case capsule(UUID)
    }

    let id = UUID()
    let target: Target
    let title: String
    let message: String
}

struct MainWindowView: View {
    let library: QuestionLibrary
    let settings: RemoteAISettings
    let openSettings: () -> Void

    @State private var query = ""
    @State private var selectedScope: LibraryScope?
    @State private var expandedPackageIDs: Set<UUID> = []
    @State private var selectedID: UUID?
    @State private var editor: QuestionEditorPresentation?
    @State private var nameRequest: HierarchyNameRequest?
    @State private var hierarchyDeleteRequest: HierarchyDeleteRequest?
    @State private var pendingDeleteID: UUID?
    @State private var errorMessage: String?
    @State private var ai = AIAnswerController()
    @FocusState private var searchFocused: Bool

    private var results: [QuestionAnswer] {
        library.search(query, in: selectedScope)
    }

    private var searchTrigger: SearchTrigger {
        SearchTrigger(
            query: query,
            scope: selectedScope,
            libraryRevision: library.revision,
            settingsRevision: settings.revision
        )
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(
                library: library,
                selection: $selectedScope,
                expandedPackageIDs: $expandedPackageIDs,
                onAddPackage: beginAddPackage,
                onAddCapsule: beginAddCapsule,
                onRenamePackage: beginRenamePackage,
                onRenameCapsule: beginRenameCapsule,
                onDeletePackage: beginDeletePackage,
                onDeleteCapsule: beginDeleteCapsule,
                onImportPackage: importPackage,
                onImportCapsule: importCapsule,
                onExportPackage: exportPackage,
                onExportCapsule: exportCapsule
            )
            .navigationTitle("Copilot Native")
            .navigationSplitViewColumnWidth(min: 185, ideal: 220, max: 280)
        } detail: {
            libraryPage
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editor = .adding(capsuleID: library.preferredCapsuleID(for: selectedScope))
                } label: {
                    Label("添加问答", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .sheet(item: $editor) { presentation in
            QuestionEditorView(presentation: presentation, library: library) { savedID in
                query = ""
                selectedID = savedID
                if let capsuleID = library.item(id: savedID)?.capsule?.id {
                    selectedScope = .capsule(capsuleID)
                    if let packageID = library.capsule(id: capsuleID)?.package?.id {
                        expandedPackageIDs.insert(packageID)
                    }
                }
                synchronizeSearch()
            }
        }
        .sheet(item: $nameRequest) { request in
            LibraryNameEditor(title: request.title, initialValue: request.initialValue) { name in
                applyNameRequest(request, name: name)
            }
        }
        .alert("删除问答", isPresented: Binding(
            get: { pendingDeleteID != nil },
            set: { if !$0 { pendingDeleteID = nil } }
        )) {
            Button("删除", role: .destructive) { deletePendingQuestion() }
            Button("取消", role: .cancel) { pendingDeleteID = nil }
        } message: {
            Text("将从当前 Capsule 中删除这条问题及其答案")
        }
        .alert(hierarchyDeleteRequest?.title ?? "删除", isPresented: Binding(
            get: { hierarchyDeleteRequest != nil },
            set: { if !$0 { hierarchyDeleteRequest = nil } }
        )) {
            Button("删除", role: .destructive) { deletePendingHierarchyItem() }
            Button("取消", role: .cancel) { hierarchyDeleteRequest = nil }
        } message: {
            Text(hierarchyDeleteRequest?.message ?? "")
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
            ensureHierarchySelection()
            synchronizeSearch()
            searchFocused = true
        }
        .onChange(of: searchTrigger) { _, _ in
            ensureHierarchySelection()
            synchronizeSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .focusQuestionSearch)) { _ in
            searchFocused = true
        }
        .onDisappear { ai.cancel() }
        .frame(minWidth: 900, minHeight: 580)
    }

    private var libraryPage: some View {
        HStack(spacing: 0) {
            questionColumn
                .frame(minWidth: 280, idealWidth: 330, maxWidth: 390)
            Divider()
            answerColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(library.title(for: selectedScope))
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

            Text(query.isEmpty ? library.title(for: selectedScope) : "搜索结果")
                .font(.headline)
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
                        .contextMenu {
                            Button {
                                editor = .init(
                                    editingID: item.id,
                                    question: item.question,
                                    answer: item.answer,
                                    capsuleID: item.capsule?.id
                                )
                            } label: {
                                Label("编辑", systemImage: "pencil")
                            }

                            Button(role: .destructive) {
                                pendingDeleteID = item.id
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
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
                results.isEmpty ? "这个范围还没有问答" : "选择一道问题",
                systemImage: results.isEmpty ? "rectangle.stack.badge.plus" : "text.book.closed"
            )
        }
    }

    private func savedAnswer(_ item: QuestionAnswer) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(item.question)
                    .font(.title2.bold())
                    .textSelection(.enabled)
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
                    Text(query).font(.title2.bold()).textSelection(.enabled)
                    Spacer()
                    if ai.state == .complete {
                        Button {
                            editor = .adding(
                                question: query.trimmingCharacters(in: .whitespacesAndNewlines),
                                answer: ai.answer,
                                capsuleID: library.preferredCapsuleID(for: selectedScope)
                            )
                        } label: {
                            Label("保存到题库", systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                Divider()

                switch ai.state {
                case .idle:
                    EmptyView()
                case .waiting, .streaming:
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(ai.state == .waiting ? "等待输入结束…" : "正在生成回答…")
                    }
                case .complete:
                    EmptyView()
                case .needsConfiguration:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("请先配置远程模型")
                        Button("打开模型设置") { openSettings() }
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

    private func ensureHierarchySelection() {
        if let selectedScope, library.contains(selectedScope) { return }
        if let capsule = library.capsules.first {
            selectedScope = .capsule(capsule.id)
            if let packageID = capsule.package?.id { expandedPackageIDs.insert(packageID) }
        } else if let package = library.packages.first {
            selectedScope = .package(package.id)
            expandedPackageIDs.insert(package.id)
        }
    }

    private func synchronizeSearch() {
        let matches = results
        if !matches.contains(where: { $0.id == selectedID }) {
            selectedID = matches.first?.id
        }
        ai.update(query: query, hasResults: !matches.isEmpty, configuration: settings.activeConfiguration)
    }

    private func beginAddPackage() {
        nameRequest = .init(action: .addPackage, title: "新建 Package", initialValue: "")
    }

    private func beginAddCapsule(_ packageID: UUID) {
        nameRequest = .init(action: .addCapsule(packageID: packageID), title: "新建 Capsule", initialValue: "")
    }

    private func beginRenamePackage(_ id: UUID) {
        guard let package = library.package(id: id) else { return }
        nameRequest = .init(action: .renamePackage(id: id), title: "重命名 Package", initialValue: package.name)
    }

    private func beginRenameCapsule(_ id: UUID) {
        guard let capsule = library.capsule(id: id) else { return }
        nameRequest = .init(action: .renameCapsule(id: id), title: "重命名 Capsule", initialValue: capsule.name)
    }

    private func applyNameRequest(_ request: HierarchyNameRequest, name: String) {
        do {
            switch request.action {
            case .addPackage:
                let package = try library.addPackage(name: name)
                expandedPackageIDs.insert(package.id)
                selectedScope = .package(package.id)
            case .addCapsule(let packageID):
                let capsule = try library.addCapsule(name: name, to: packageID)
                expandedPackageIDs.insert(packageID)
                selectedScope = .capsule(capsule.id)
            case .renamePackage(let id):
                try library.renamePackage(id: id, name: name)
            case .renameCapsule(let id):
                try library.renameCapsule(id: id, name: name)
            }
            synchronizeSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func beginDeletePackage(_ id: UUID) {
        guard let package = library.package(id: id) else { return }
        hierarchyDeleteRequest = .init(
            target: .package(id),
            title: "删除 Package“\(package.name)”？",
            message: "其中的全部 Capsule 和问答也会从本机删除"
        )
    }

    private func beginDeleteCapsule(_ id: UUID) {
        guard let capsule = library.capsule(id: id) else { return }
        hierarchyDeleteRequest = .init(
            target: .capsule(id),
            title: "删除 Capsule“\(capsule.name)”？",
            message: "其中的全部问答也会从本机删除"
        )
    }

    private func deletePendingHierarchyItem() {
        guard let request = hierarchyDeleteRequest else { return }
        hierarchyDeleteRequest = nil
        do {
            switch request.target {
            case .package(let id):
                try library.deletePackage(id: id)
                expandedPackageIDs.remove(id)
            case .capsule(let id):
                try library.deleteCapsule(id: id)
            }
            ensureHierarchySelection()
            synchronizeSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deletePendingQuestion() {
        guard let id = pendingDeleteID else { return }
        pendingDeleteID = nil
        do {
            try library.delete(id: id)
            synchronizeSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importPackage() {
        guard let data = readTransferFile() else { return }
        do {
            let package = try library.importPackage(from: data)
            expandedPackageIDs.insert(package.id)
            selectedScope = .package(package.id)
            synchronizeSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importCapsule(into packageID: UUID) {
        guard let data = readTransferFile() else { return }
        do {
            let capsule = try library.importCapsule(from: data, into: packageID)
            expandedPackageIDs.insert(packageID)
            selectedScope = .capsule(capsule.id)
            synchronizeSearch()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportPackage(_ id: UUID) {
        do {
            guard let package = library.package(id: id) else { throw LibraryError.missingPackage }
            try writeTransferFile(
                library.exportPackage(id: id),
                suggestedName: "\(safeFilename(package.name)).copilot-package.json"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func exportCapsule(_ id: UUID) {
        do {
            guard let capsule = library.capsule(id: id) else { throw LibraryError.missingCapsule }
            try writeTransferFile(
                library.exportCapsule(id: id),
                suggestedName: "\(safeFilename(capsule.name)).copilot-capsule.json"
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func readTransferFile() -> Data? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    private func writeTransferFile(_ data: Data, suggestedName: String) throws {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = suggestedName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }

    private func safeFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

private struct LibrarySidebar: View {
    let library: QuestionLibrary
    @Binding var selection: LibraryScope?
    @Binding var expandedPackageIDs: Set<UUID>
    let onAddPackage: () -> Void
    let onAddCapsule: (UUID) -> Void
    let onRenamePackage: (UUID) -> Void
    let onRenameCapsule: (UUID) -> Void
    let onDeletePackage: (UUID) -> Void
    let onDeleteCapsule: (UUID) -> Void
    let onImportPackage: () -> Void
    let onImportCapsule: (UUID) -> Void
    let onExportPackage: (UUID) -> Void
    let onExportCapsule: (UUID) -> Void

    private var selectedPackageID: UUID? {
        library.packageID(for: selection)
    }

    var body: some View {
        VStack(spacing: 0) {
            AppKitLibrarySidebar(
                library: library,
                libraryRevision: library.revision,
                selection: $selection,
                expandedPackageIDs: $expandedPackageIDs,
                onAddCapsule: onAddCapsule,
                onRenamePackage: onRenamePackage,
                onRenameCapsule: onRenameCapsule,
                onDeletePackage: onDeletePackage,
                onDeleteCapsule: onDeleteCapsule,
                onImportCapsule: onImportCapsule,
                onExportPackage: onExportPackage,
                onExportCapsule: onExportCapsule
            )

            Divider()
            HStack(spacing: 8) {
                Menu {
                    Button("新建 Package", systemImage: "shippingbox") { onAddPackage() }
                    if let packageID = selectedPackageID {
                        Button("新建 Capsule", systemImage: "capsule") { onAddCapsule(packageID) }
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("新建 Package 或 Capsule")

                Menu {
                    Button("导入 Package…", systemImage: "square.and.arrow.down") { onImportPackage() }
                    if let packageID = selectedPackageID {
                        Button("导入 Capsule…", systemImage: "square.and.arrow.down") {
                            onImportCapsule(packageID)
                        }
                    }
                    Divider()
                    if case .package(let id) = selection {
                        Button("导出当前 Package…", systemImage: "square.and.arrow.up") {
                            onExportPackage(id)
                        }
                    }
                    if case .capsule(let id) = selection {
                        Button("导出当前 Capsule…", systemImage: "square.and.arrow.up") {
                            onExportCapsule(id)
                        }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("导入或导出")

                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
        }
        .background(Color(nsColor: .underPageBackgroundColor).opacity(0.55))
    }
}

private struct AppKitLibrarySidebar: NSViewRepresentable {
    let library: QuestionLibrary
    let libraryRevision: Int
    @Binding var selection: LibraryScope?
    @Binding var expandedPackageIDs: Set<UUID>
    let onAddCapsule: (UUID) -> Void
    let onRenamePackage: (UUID) -> Void
    let onRenameCapsule: (UUID) -> Void
    let onDeletePackage: (UUID) -> Void
    let onDeleteCapsule: (UUID) -> Void
    let onImportCapsule: (UUID) -> Void
    let onExportPackage: (UUID) -> Void
    let onExportCapsule: (UUID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        _ = libraryRevision
        context.coordinator.parent = self
        context.coordinator.reloadIfNeeded()
    }

    fileprivate var items: [AppKitLibrarySidebarItem] {
        library.packages.flatMap { package in
            let expanded = expandedPackageIDs.contains(package.id)
            var result: [AppKitLibrarySidebarItem] = [.package(package.id, expanded: expanded)]
            if expanded {
                result.append(contentsOf: library.capsules(in: package.id).map { .capsule($0.id) })
            }
            return result
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: AppKitLibrarySidebar
        private weak var tableView: NSTableView?
        private var items: [AppKitLibrarySidebarItem]
        private var isSyncingSelection = false
        private var keepsDisclosureSelection = false
        private var disclosureContentScope: LibraryScope?
        private var pendingDisclosureID: UUID?
        private var menuController: AppKitLibrarySidebarMenuController?

        init(parent: AppKitLibrarySidebar) {
            self.parent = parent
            self.items = parent.items
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true
            scrollView.horizontalScrollElasticity = .none
            scrollView.automaticallyAdjustsContentInsets = false
            scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

            let tableView = AppKitLibrarySidebarTableView()
            tableView.frame = scrollView.contentView.bounds
            tableView.autoresizingMask = [.width]
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.backgroundColor = .clear
            tableView.style = .sourceList
            tableView.selectionHighlightStyle = .regular
            tableView.rowSizeStyle = .custom
            tableView.intercellSpacing = NSSize(width: 0, height: 2)
            tableView.allowsMultipleSelection = false
            tableView.allowsEmptySelection = true
            tableView.floatsGroupRows = false
            tableView.sidebarMenuProvider = { [weak self] row in
                self?.contextMenu(for: row)
            }
            tableView.sidebarDisclosureHandler = { [weak self] tableView, row in
                self?.activatePackageDisclosure(at: row, in: tableView) ?? false
            }
            tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

            let column = NSTableColumn(identifier: .appKitLibrarySidebarColumn)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            scrollView.documentView = tableView
            self.tableView = tableView
            syncSelection(in: tableView)
            return scrollView
        }

        func reloadIfNeeded() {
            let nextItems = parent.items
            let rowsChanged = nextItems != items

            guard let tableView else { return }
            if rowsChanged {
                let previousItems = items
                if let disclosureID = pendingDisclosureID,
                   let oldDisclosureRow = previousItems.firstIndex(where: { $0.packageID == disclosureID }),
                   let newDisclosureRow = nextItems.firstIndex(where: { $0.packageID == disclosureID }),
                   oldDisclosureRow == newDisclosureRow,
                   case .package(_, let wasExpanded) = previousItems[oldDisclosureRow],
                   case .package(_, let isExpanded) = nextItems[newDisclosureRow],
                   wasExpanded != isExpanded {
                    let changedCount = parent.library.capsules(in: disclosureID).count
                    let changedRows = IndexSet(
                        integersIn: (oldDisclosureRow + 1)..<(oldDisclosureRow + 1 + changedCount)
                    )
                    tableView.beginUpdates()
                    items = nextItems
                    if isExpanded {
                        tableView.insertRows(at: changedRows, withAnimation: [.effectFade, .slideDown])
                    } else {
                        tableView.removeRows(at: changedRows, withAnimation: [.effectFade, .slideUp])
                    }
                    tableView.endUpdates()
                    reloadVisibleRows(in: tableView)
                } else {
                    items = nextItems
                    tableView.reloadData()
                }
                pendingDisclosureID = nil
            } else {
                items = nextItems
                reloadVisibleRows(in: tableView)
            }
            syncSelection(in: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            items.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            items.indices.contains(row)
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            30
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            AppKitLibrarySidebarRowView()
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard items.indices.contains(row) else { return nil }
            let cell = tableView.makeView(
                withIdentifier: AppKitLibrarySidebarCell.reuseIdentifier,
                owner: self
            ) as? AppKitLibrarySidebarCell ?? AppKitLibrarySidebarCell()
            configure(cell, for: items[row], selected: tableView.selectedRow == row)
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView,
                  items.indices.contains(tableView.selectedRow) else {
                return
            }

            switch items[tableView.selectedRow] {
            case .package:
                _ = activatePackageDisclosure(at: tableView.selectedRow, in: tableView)
            case .capsule(let id):
                keepsDisclosureSelection = false
                parent.selection = .capsule(id)
                applySelectionStyleToVisibleRows(in: tableView)
            }
        }

        private func activatePackageDisclosure(at row: Int, in tableView: NSTableView) -> Bool {
            guard items.indices.contains(row), case .package(let id, _) = items[row] else { return false }
            keepsDisclosureSelection = true
            disclosureContentScope = parent.selection
            if tableView.selectedRow != row {
                isSyncingSelection = true
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                isSyncingSelection = false
            }

            var expanded = parent.expandedPackageIDs
            if expanded.contains(id) {
                expanded.remove(id)
            } else {
                expanded.insert(id)
            }
            pendingDisclosureID = id
            parent.expandedPackageIDs = expanded
            applySelectionStyleToVisibleRows(in: tableView)
            // Match Obelisk: apply every click immediately so another click
            // reverses an in-flight insertion/removal animation.
            reloadIfNeeded()
            return true
        }

        private func syncSelection(in tableView: NSTableView) {
            if keepsDisclosureSelection,
               disclosureContentScope == parent.selection,
               items.indices.contains(tableView.selectedRow),
               case .package = items[tableView.selectedRow] {
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }
            keepsDisclosureSelection = false

            guard let selection = parent.selection else {
                isSyncingSelection = true
                tableView.deselectAll(nil)
                isSyncingSelection = false
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }

            let row = items.firstIndex { item in
                switch (selection, item) {
                case (.package(let selectedID), .package(let id, _)): selectedID == id
                case (.capsule(let selectedID), .capsule(let id)): selectedID == id
                default: false
                }
            }
            guard let row else {
                isSyncingSelection = true
                tableView.deselectAll(nil)
                isSyncingSelection = false
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }
            guard tableView.selectedRow != row else {
                applySelectionStyleToVisibleRows(in: tableView)
                return
            }
            isSyncingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            isSyncingSelection = false
            applySelectionStyleToVisibleRows(in: tableView)
        }

        private func reloadVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }
            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard items.indices.contains(row),
                      let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? AppKitLibrarySidebarCell else {
                    continue
                }
                configure(cell, for: items[row], selected: tableView.selectedRow == row)
            }
        }

        private func applySelectionStyleToVisibleRows(in tableView: NSTableView) {
            let visibleRows = tableView.rows(in: tableView.visibleRect)
            guard visibleRows.location != NSNotFound else { return }
            for row in visibleRows.location ..< NSMaxRange(visibleRows) {
                guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false)
                        as? AppKitLibrarySidebarCell else {
                    continue
                }
                cell.applySelectionStyle(isSelected: tableView.selectedRowIndexes.contains(row))
            }
        }

        private func configure(
            _ cell: AppKitLibrarySidebarCell,
            for item: AppKitLibrarySidebarItem,
            selected: Bool
        ) {
            switch item {
            case .package(let id, let expanded):
                guard let package = parent.library.package(id: id) else { return }
                cell.configure(
                    title: package.name,
                    badgeCount: parent.library.questionCount(in: .package(id)),
                    indentation: 0,
                    systemImage: "shippingbox.fill",
                    disclosureExpanded: expanded,
                    isSelected: selected
                )
            case .capsule(let id):
                guard let capsule = parent.library.capsule(id: id) else { return }
                cell.configure(
                    title: capsule.name,
                    badgeCount: parent.library.questionCount(in: .capsule(id)),
                    indentation: 14,
                    systemImage: "capsule.fill",
                    disclosureExpanded: nil,
                    isSelected: selected
                )
            }
        }

        private func contextMenu(for row: Int) -> NSMenu? {
            guard items.indices.contains(row) else { return nil }
            let controller = AppKitLibrarySidebarMenuController()
            let menu = NSMenu()
            var nextAction = 0

            func addItem(_ title: String, symbol: String, action: @escaping @MainActor () -> Void) {
                let key = nextAction
                nextAction += 1
                controller.actions[key] = action
                let item = NSMenuItem(
                    title: title,
                    action: #selector(AppKitLibrarySidebarMenuController.invoke(_:)),
                    keyEquivalent: ""
                )
                item.target = controller
                item.representedObject = key
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                menu.addItem(item)
            }

            switch items[row] {
            case .package(let id, _):
                addItem("新建 Capsule", symbol: "plus") { [weak self] in self?.parent.onAddCapsule(id) }
                addItem("重命名", symbol: "pencil") { [weak self] in self?.parent.onRenamePackage(id) }
                menu.addItem(.separator())
                addItem("导入 Capsule…", symbol: "square.and.arrow.down") { [weak self] in
                    self?.parent.onImportCapsule(id)
                }
                addItem("导出 Package…", symbol: "square.and.arrow.up") { [weak self] in
                    self?.parent.onExportPackage(id)
                }
                menu.addItem(.separator())
                addItem("删除 Package", symbol: "trash") { [weak self] in self?.parent.onDeletePackage(id) }
            case .capsule(let id):
                addItem("重命名", symbol: "pencil") { [weak self] in self?.parent.onRenameCapsule(id) }
                addItem("导出 Capsule…", symbol: "square.and.arrow.up") { [weak self] in
                    self?.parent.onExportCapsule(id)
                }
                menu.addItem(.separator())
                addItem("删除 Capsule", symbol: "trash") { [weak self] in self?.parent.onDeleteCapsule(id) }
            }
            menuController = controller
            return menu
        }
    }
}

private enum AppKitLibrarySidebarItem: Equatable {
    case package(UUID, expanded: Bool)
    case capsule(UUID)

    var packageID: UUID? {
        guard case .package(let id, _) = self else { return nil }
        return id
    }
}

@MainActor
private final class AppKitLibrarySidebarMenuController: NSObject {
    var actions: [Int: @MainActor () -> Void] = [:]

    @objc func invoke(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Int else { return }
        actions[key]?()
    }
}

private final class AppKitLibrarySidebarTableView: NSTableView {
    var sidebarMenuProvider: ((Int) -> NSMenu?)?
    var sidebarDisclosureHandler: ((NSTableView, Int) -> Bool)?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        if row >= 0, sidebarDisclosureHandler?(self, row) == true { return }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return sidebarMenuProvider?(row)
    }
}

private final class AppKitLibrarySidebarRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet { applySelectionStyleToCell() }
    }

    override var isEmphasized: Bool {
        get { false }
        set { super.isEmphasized = false }
    }

    private func applySelectionStyleToCell() {
        for subview in subviews {
            (subview as? AppKitLibrarySidebarCell)?.applySelectionStyle(isSelected: isSelected)
        }
    }
}

private final class AppKitLibrarySidebarCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("AppKitLibrarySidebarCell")
    private static let leadingInset: CGFloat = 3
    private static let trailingInset: CGFloat = 14

    private let disclosureImageView = NSImageView()
    private let iconImageView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let badgeField = NSTextField(labelWithString: "")
    private var iconLeading: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier

        disclosureImageView.imageScaling = .scaleProportionallyDown
        disclosureImageView.contentTintColor = .secondaryLabelColor
        disclosureImageView.translatesAutoresizingMaskIntoConstraints = false

        iconImageView.imageScaling = .scaleProportionallyDown
        iconImageView.contentTintColor = .secondaryLabelColor
        iconImageView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: NSFont.systemFontSize)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.translatesAutoresizingMaskIntoConstraints = false

        badgeField.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        badgeField.textColor = .secondaryLabelColor
        badgeField.alignment = .right
        badgeField.lineBreakMode = .byTruncatingTail
        badgeField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(disclosureImageView)
        addSubview(iconImageView)
        addSubview(titleField)
        addSubview(badgeField)

        iconLeading = iconImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.leadingInset)
        NSLayoutConstraint.activate([
            disclosureImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            disclosureImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosureImageView.widthAnchor.constraint(equalToConstant: 18),
            disclosureImageView.heightAnchor.constraint(equalToConstant: 18),

            iconLeading,
            iconImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconImageView.widthAnchor.constraint(equalToConstant: 18),
            iconImageView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: iconImageView.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: badgeField.leadingAnchor, constant: -8),

            badgeField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.trailingInset),
            badgeField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        badgeCount: Int,
        indentation: CGFloat,
        systemImage: String,
        disclosureExpanded: Bool?,
        isSelected: Bool
    ) {
        titleField.stringValue = title
        badgeField.stringValue = "\(badgeCount)"
        iconImageView.image = NSImage(
            systemSymbolName: systemImage,
            accessibilityDescription: title
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))
        let disclosureOffset: CGFloat = disclosureExpanded == nil ? 0 : 20
        iconLeading.constant = Self.leadingInset + indentation + disclosureOffset
        configureDisclosure(expanded: disclosureExpanded)
        applySelectionStyle(isSelected: isSelected)
    }

    private func configureDisclosure(expanded: Bool?) {
        guard let expanded else {
            disclosureImageView.isHidden = true
            return
        }
        disclosureImageView.isHidden = false
        disclosureImageView.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "收起" : "展开"
        )?.withSymbolConfiguration(.init(pointSize: 14, weight: .bold))
    }

    func applySelectionStyle(isSelected: Bool) {
        let weight: NSFont.Weight = isSelected ? .semibold : .regular
        titleField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: weight)
        badgeField.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: weight
        )
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let appKitLibrarySidebarColumn = NSUserInterfaceItemIdentifier("AppKitLibrarySidebarColumn")
}

private struct LibraryNameEditor: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialValue: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title).font(.title2.bold())
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    onSave(value)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 400)
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
