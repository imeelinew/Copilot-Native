import Foundation
import Observation

@MainActor
@Observable
final class SpeechSettings {
    var apiKey: String { didSet { defaults.set(apiKey, forKey: "speechAPIKey") } }
    var hotwords: String { didSet { defaults.set(hotwords, forKey: "speechHotwords") } }
    var automaticAnswers: Bool { didSet { defaults.set(automaticAnswers, forKey: "speechAutomaticAnswers") } }
    var questionPause: Double { didSet { defaults.set(questionPause, forKey: "speechQuestionPause") } }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        apiKey = defaults.string(forKey: "speechAPIKey") ?? ""
        hotwords = defaults.string(forKey: "speechHotwords") ?? "Swift, SwiftUI, SwiftData, AppKit, Actor, Redis, MySQL, JVM, Spring Boot, Kubernetes"
        automaticAnswers = defaults.object(forKey: "speechAutomaticAnswers") as? Bool ?? true
        questionPause = defaults.object(forKey: "speechQuestionPause") as? Double ?? 1.2
    }

    var words: [String] {
        Array(hotwords.components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(100))
    }
}

enum SpeechError: LocalizedError {
    case message(String)
    case service(Int, String)
    case invalidPacket
    case audioBacklog
    case permissionRequired

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        case .service(let code, let message): "语音服务错误 \(code)：\(message)"
        case .invalidPacket: "语音服务返回了无法解析的数据"
        case .audioBacklog: "音频发送积压，正在重新连接；请重述未识别的内容"
        case .permissionRequired: "当前 App 尚未获得系统音频录制授权。请点击“系统权限”授权；如果开关已打开，请关闭后重新开启，并完全退出再打开 App。"
        }
    }

    var canRetry: Bool {
        switch self {
        case .service(let code, _): code >= 50_000_000
        case .message, .invalidPacket, .permissionRequired: false
        case .audioBacklog: true
        }
    }
}
