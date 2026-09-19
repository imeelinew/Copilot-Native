import AppKit
import SwiftUI

struct QuestionEditorPresentation: Identifiable {
    let id = UUID()
    let editingID: UUID?
    let question: String
    let answer: String
    let capsuleID: UUID?

    static func adding(question: String = "", answer: String = "", capsuleID: UUID? = nil) -> Self {
        .init(editingID: nil, question: question, answer: answer, capsuleID: capsuleID)
    }
}

struct QuestionEditorView: View {
    let presentation: QuestionEditorPresentation
    let library: QuestionLibrary
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question: String
    @State private var answer: String
    @State private var capsuleID: UUID?
    @State private var errorMessage: String?

    init(presentation: QuestionEditorPresentation, library: QuestionLibrary, onSaved: @escaping (UUID) -> Void) {
        self.presentation = presentation
        self.library = library
        self.onSaved = onSaved
        _question = State(initialValue: presentation.question)
        _answer = State(initialValue: presentation.answer)
        _capsuleID = State(initialValue: presentation.capsuleID ?? library.capsules.first?.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(presentation.editingID == nil ? "添加问答" : "编辑问答")
                .font(.title2.bold())

            Picker("Capsule", selection: $capsuleID) {
                ForEach(library.packages, id: \.id) { package in
                    Section(package.name) {
                        ForEach(library.capsules(in: package.id), id: \.id) { capsule in
                            Text(capsule.name).tag(Optional(capsule.id))
                        }
                    }
                }
            }
            .pickerStyle(.menu)

            VStack(alignment: .leading, spacing: 8) {
                Text("问题").font(.headline)
                PaddedTextEditor(
                    text: $question,
                    placeholder: "输入面试问题",
                    font: .systemFont(ofSize: NSFont.systemFontSize),
                    accessibilityLabel: "问题"
                )
                .frame(minHeight: 80, maxHeight: 120)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("答案").font(.headline)
                PaddedTextEditor(
                    text: $answer,
                    placeholder: "输入答案，可使用 Markdown 列表和代码块",
                    font: .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular),
                    accessibilityLabel: "答案"
                )
                .frame(minHeight: 250)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)) }
            }

            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red).font(.callout)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || capsuleID == nil)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 36)
        .padding(.top, 32)
        .padding(.bottom, 32)
        .frame(minWidth: 650, minHeight: 560)
    }

    private func save() {
        do {
            guard let capsuleID else { throw LibraryError.missingCapsule }
            let id: UUID
            if let editingID = presentation.editingID {
                try library.update(id: editingID, question: question, answer: answer, capsuleID: capsuleID)
                id = editingID
            } else {
                id = try library.add(question: question, answer: answer, capsuleID: capsuleID).id
            }
            onSaved(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
