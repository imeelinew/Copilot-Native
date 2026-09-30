import Observation
import SwiftUI

@MainActor
@Observable
final class InterviewKnowledgeBase {
    var scope: InterviewProjectScope = .automatic
    private(set) var revision = 0
    private(set) var summary = "尚未载入资料"
    private(set) var phase = ""
    private(set) var busy = false
    private(set) var warning: String?
    @ObservationIgnored private var preparation: Task<Void, Never>?

    func prepare() async {
        guard !busy else { return }
        busy = true
        warning = nil
        do {
            let status = try await InterviewKnowledgeEngine.shared.load()
            apply(status)
            revision += 1
        } catch {
            warning = error.localizedDescription
            busy = false
            return
        }
        preparation = Task { [self] in
            defer { busy = false; preparation = nil }
            do {
                let status = try await InterviewKnowledgeEngine.shared.prepareVectors { [weak self] message in
                    Task { @MainActor [weak self] in
                        guard let self, self.busy else { return }
                        self.phase = message
                    }
                }
                apply(status)
                phase = "本地向量检索已就绪"
            } catch {
                phase = "当前使用关键词检索"
                warning = "向量检索准备失败，可刷新重试：" + error.localizedDescription
            }
        }
    }

    private func apply(_ status: KnowledgeIndexStatus) {
        summary = "\(status.projectCount) 条项目事实 · \(status.passageCount - status.projectCount) 条通用资料"
        if status.staleCount > 0 { warning = "\(status.staleCount) 条项目事实的源码已变化，暂不用于回答。需要重新核对项目事实。" }
    }
}

struct InterviewKnowledgeControls: View {
    @Bindable var knowledge: InterviewKnowledgeBase

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("回答背景", selection: $knowledge.scope) {
                ForEach(InterviewProjectScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.menu)
            HStack {
                Text(knowledge.summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await knowledge.prepare() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(knowledge.busy)
                .help("刷新本地资料")
                .accessibilityLabel("刷新本地资料")
            }
            if !knowledge.phase.isEmpty {
                Text(knowledge.phase).font(.caption).foregroundStyle(.secondary)
            }
            if let warning = knowledge.warning {
                Text(warning).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
        }
    }
}

struct InterviewAnswerSources: View {
    let retrieval: KnowledgeRetrieval

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = retrieval.warning {
                Text(warning).font(.callout).foregroundStyle(.orange)
            }
            if !retrieval.passages.isEmpty {
                DisclosureGroup("参考资料（\(retrieval.passages.count)）") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(retrieval.passages) { passage in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(passage.projectName + " · " + passage.title).font(.callout.weight(.medium))
                                Text(passage.boundary).font(.caption).foregroundStyle(.secondary)
                                ForEach(passage.sources, id: \.self) { source in
                                    Link(URL(filePath: source.path).lastPathComponent + ":\(source.line)", destination: URL(filePath: source.path))
                                        .font(.caption)
                                }
                            }
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
        }
    }
}
