import Foundation
import Observation
import Security

struct AIConfiguration: Equatable, Sendable {
    let endpoint: URL
    let model: String
    let apiKey: String
}

enum AISettingsError: LocalizedError {
    case incomplete
    case invalidURL
    case insecureURL
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .incomplete: "请填写接口地址、模型名称和 API Key"
        case .invalidURL: "接口地址不是有效的网址"
        case .insecureURL: "远程接口必须使用 HTTPS"
        case .keychain(let status): "无法访问钥匙串（错误码 \(status)）"
        }
    }
}

enum APIKeyStorage {
    private static let service = "com.eli.CopilotNative.remote-api-key"
    private static let account = "remote"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() throws -> String {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw AISettingsError.keychain(status)
        }
        return key
    }

    static func write(_ key: String) throws {
        let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw AISettingsError.keychain(status)
            }
            return
        }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard status == errSecSuccess else { throw AISettingsError.keychain(status) }
        } else {
            var request = query
            request.merge(attributes) { _, new in new }
            let status = SecItemAdd(request as CFDictionary, nil)
            guard status == errSecSuccess else { throw AISettingsError.keychain(status) }
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
