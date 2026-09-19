import Foundation
import Observation

struct AIConfiguration: Equatable, Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
}

enum AISettingsError: LocalizedError {
    case incomplete
    case invalidURL
    case insecureURL

    var errorDescription: String? {
        switch self {
        case .incomplete: "请填写接口地址、模型名称和 API Key"
        case .invalidURL: "接口地址不是有效的网址"
        case .insecureURL: "远程接口必须使用 HTTPS"
        }
    }
}

enum APIKeyStorage {
    private static let key = "remoteAIApiKey"

    static func read() throws -> String {
        UserDefaults.standard.string(forKey: key) ?? ""
    }

    static func write(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set(value, forKey: Self.key)
        }
    }
}

@MainActor
@Observable
final class RemoteAISettings {
    private static let endpointKey = "remoteAIEndpoint"
    private static let modelKey = "remoteAIModel"
    static let defaultEndpoint = "https://api.openai.com/v1/chat/completions"

    var endpointText: String
    var modelText: String
    var apiKey: String
    private(set) var activeConfiguration: AIConfiguration?
    private(set) var revision = 0
    var errorMessage: String?

    init(defaults: UserDefaults = .standard, loadKey: () throws -> String = APIKeyStorage.read) {
        endpointText = defaults.string(forKey: Self.endpointKey) ?? Self.defaultEndpoint
        modelText = defaults.string(forKey: Self.modelKey) ?? ""
        do {
            apiKey = try loadKey()
            activeConfiguration = try? Self.validate(endpointText, modelText, apiKey)
        } catch {
            apiKey = ""
            errorMessage = error.localizedDescription
        }
    }

    var isConfigured: Bool { activeConfiguration != nil }

    func draftConfiguration() throws -> AIConfiguration {
        try Self.validate(endpointText, modelText, apiKey)
    }

    func save(defaults: UserDefaults = .standard, saveKey: (String) throws -> Void = APIKeyStorage.write) throws {
        let config = try draftConfiguration()
        try saveKey(config.apiKey)
        defaults.set(config.endpoint.absoluteString, forKey: Self.endpointKey)
        defaults.set(config.model, forKey: Self.modelKey)
        activeConfiguration = config
        revision &+= 1
        errorMessage = nil
    }

    private static func validate(_ endpoint: String, _ model: String, _ key: String) throws -> AIConfiguration {
        let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !endpoint.isEmpty, !model.isEmpty, !key.isEmpty else { throw AISettingsError.incomplete }
        guard let url = URL(string: endpoint), url.host != nil else { throw AISettingsError.invalidURL }
        guard url.scheme?.lowercased() == "https" else { throw AISettingsError.insecureURL }
        return AIConfiguration(endpoint: url, model: model, apiKey: key)
    }
}
