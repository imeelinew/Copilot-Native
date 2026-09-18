import AppKit
import MacAppSettingsUI
import SwiftUI

/// Owns the MacAppSettingsUI preferences window and bridges the AI settings pane into it.
@MainActor
final class AISettingsWindowController {
    private let settings: RemoteAISettings
    private var controller: SettingsWindowController?

    init(settings: RemoteAISettings) {
        self.settings = settings
    }

    func show() {
        if controller == nil {
            controller = makeController()
        }
        guard let controller else { return }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        Task { @MainActor in
            controller.window?.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Private

    private func makeController() -> SettingsWindowController {
        let controller = SettingsWindowController(
            with: [AISettingsPaneController(settings: settings)],
            centersWindowPositionAlways: false,
            closesWindowWithEscapeKey: true
        )
        controller.settingsWindow.defaultWindowTitle = "Copilot Native 设置"
        return controller
    }
}

/// Hosts the SwiftUI settings pane inside `MacAppSettingsUI`'s `SettingsPaneViewController`.
private final class AISettingsPaneController: SettingsPaneViewController {
    private static let paneWidth: CGFloat = 480
    private static let paneHeight: CGFloat = 340

    private let rootView: AnyView

    init(settings: RemoteAISettings) {
        rootView = AnyView(AISettingsView(settings: settings))
        super.init(nibName: nil, bundle: nil)
        tabName = "AI 模型"
        tabImage = Self.makeTabImage(systemSymbolName: "cpu")
        tabIdentifier = "ai"
        isResizableView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        view = hosting
        preferredPaneSize = NSSize(width: Self.paneWidth, height: Self.paneHeight)
        view.setFrameSize(preferredPaneSize ?? .zero)
    }

    /// Mirrors Paste's tab artwork: a 21pt glyph centered in a 32pt canvas slot that the
    /// settings toolbar scales as a unit.
    private static func makeTabImage(systemSymbolName: String) -> NSImage? {
        let canvasSize: CGFloat = 32
        let artworkSize: CGFloat = 21
        let configuration = NSImage.SymbolConfiguration(pointSize: artworkSize, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: systemSymbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return nil }

        let image = NSImage(size: NSSize(width: canvasSize, height: canvasSize), flipped: true) { _ in
            let frame = CGRect(
                x: (canvasSize - symbol.size.width) / 2,
                y: (canvasSize - symbol.size.height) / 2,
                width: symbol.size.width,
                height: symbol.size.height
            )
            symbol.draw(in: frame)
            return true
        }
        image.isTemplate = true
        return image
    }
}
