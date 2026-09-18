import Observation
import SwiftData
import SwiftUI

@MainActor
@Observable
final class AppBootstrap {
    let settings = RemoteAISettings()
    let settingsWindow: AISettingsWindowController
    let library: QuestionLibrary?
    let startupError: String?

    init() {
        settingsWindow = AISettingsWindowController(settings: settings)
        do {
            let container: ModelContainer
            if CommandLine.arguments.contains("-uiTesting") {
                container = try ModelContainer(
                    for: QuestionAnswer.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
            } else {
                container = try ModelContainer(for: QuestionAnswer.self)
            }
            library = try QuestionLibrary(container: container)
            startupError = nil
        } catch {
            library = nil
            startupError = error.localizedDescription
        }
    }
}

@main
struct CopilotNativeApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup("Copilot Native") {
            if let library = bootstrap.library {
                MainWindowView(
                    library: library,
                    settings: bootstrap.settings,
                    openSettings: { bootstrap.settingsWindow.show() }
                )
            } else {
                ContentUnavailableView(
                    "无法打开题库",
                    systemImage: "externaldrive.badge.exclamationmark",
                    description: Text(bootstrap.startupError ?? "本地数据不可用")
                )
                .frame(minWidth: 600, minHeight: 400)
            }
        }
        .defaultSize(width: 1120, height: 720)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    bootstrap.settingsWindow.show()
                }
                .keyboardShortcut(",")
            }
        }
    }
}
