import SwiftUI

struct QuestionEditorPresentation: Identifiable {
    let id = UUID()
    let editingID: UUID?
    let question: String
    let answer: String

    static func adding(question: String = "", answer: String = "") -> Self {
        .init(editingID: nil, question: question, answer: answer)
    }
}

struct QuestionEditorView: View {
    let presentation: QuestionEditorPresentation
    let library: QuestionLibrary
    let onSaved: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var question: String
    @State private var answer: String
    @State private var errorMessage: String?

    init(presentation: QuestionEditorPresentation, library: QuestionLibrary, onSaved: @escaping (UUID) -> Void) {
        self.presentation = presentation
        self.library = library
        self.onSaved = onSaved
        _question = State(initialValue: presentation.question)
        _answer = State(initialValue: presentation.answer)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(presentation.editingID == nil ? "添加问答" : "编辑问答")
                .font(.title2.bold())

            VStack(alignment: .leading, spacing: 8) {
                Text("问题").font(.headline)
                ZStack(alignment: .topLeading) {
                    if question.isEmpty {
                        Text("输入面试问题")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $question)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("问题")
                }
                .frame(minHeight: 80, maxHeight: 120)
                .padding(8)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)) }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("答案").font(.headline)
                ZStack(alignment: .topLeading) {
                    if answer.isEmpty {
                        Text("输入答案，可使用 Markdown 列表和代码块")
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $answer)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .accessibilityLabel("答案")
                }
                .frame(minHeight: 250)
                .padding(8)
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
                        || answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(minWidth: 650, minHeight: 560)
    }

    private func save() {
        do {
            let id: UUID
            if let editingID = presentation.editingID {
                try library.update(id: editingID, question: question, answer: answer)
                id = editingID
            } else {
                id = try library.add(question: question, answer: answer).id
            }
            onSaved(id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
