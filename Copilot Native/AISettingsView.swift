import SwiftUI

struct AISettingsView: View {
    @Bindable var settings: RemoteAISettings
    @State private var feedback: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("远程模型") {
                TextField("接口地址", text: $settings.endpointText)
                    .textContentType(.URL)
                TextField("模型名称", text: $settings.modelText)
                SecureField("API Key", text: $settings.apiKey)
                Text("本地无匹配时，问题会自动发送到此 HTTPS 接口，请填写兼容 OpenAI Chat Completions 的完整地址")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 12) {
                    Button("保存设置") { save() }
                        .buttonStyle(.borderedProminent)
                    Button(isTesting ? "测试中…" : "测试连接") { testConnection() }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                }
                if let feedback {
                    Text(feedback).foregroundStyle(feedback == "连接成功" ? Color.secondary : Color.red)
                }
                if let errorMessage = settings.errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("模型设置")
        .frame(minWidth: 500, maxWidth: 720)
        .padding(20)
    }

    private func save() {
        do {
            try settings.save()
            feedback = "设置已保存"
        } catch {
            feedback = error.localizedDescription
        }
    }

    private func testConnection() {
        let configuration: AIConfiguration
        do {
            configuration = try settings.draftConfiguration()
        } catch {
            feedback = error.localizedDescription
            return
        }
        isTesting = true
        feedback = nil
        Task {
            do {
                var received = false
                for try await chunk in ChatCompletionClient().streamAnswer(
                    for: "请只回复 OK",
                    configuration: configuration
                ) {
                    if !chunk.isEmpty { received = true }
                }
                feedback = received ? "连接成功" : AIClientError.emptyAnswer.localizedDescription
            } catch {
                feedback = error.localizedDescription
            }
            isTesting = false
        }
    }
}
